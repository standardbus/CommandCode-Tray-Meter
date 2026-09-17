using System;
using System.Collections.Generic;
using System.Globalization;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace CommandCodeMonitor
{
    /// <summary>
    /// Talks to Command Code.
    ///
    /// The two rolling windows come from a single fast call, so the caller is
    /// given them as soon as they exist; the USD credit line needs two slow calls
    /// (subscriptions, then the period spend) and is hydrated afterwards. That
    /// split is what keeps opening the bubble instant.
    /// </summary>
    internal sealed class LimitsClient : IDisposable
    {
        private readonly MonitorConfig _config;
        private readonly HttpClient _http;

        /// <summary>
        /// Test hook: when set, every GET is answered from this table instead of
        /// the network. It exists because the development sandbox denies Schannel
        /// credentials, so the request layer cannot reach the real API there; the
        /// parsing and derivation above it can still be exercised against real
        /// captured responses.
        /// </summary>
        internal Func<string, object> DebugTransport;

        public LimitsClient(MonitorConfig config)
        {
            _config = config;
            // .NET Framework negotiates TLS 1.0 by default, which api.commandcode.ai
            // refuses. Enable the modern protocols explicitly.
            try
            {
                var modern = (System.Net.SecurityProtocolType)3072 |   // Tls12
                             (System.Net.SecurityProtocolType)12288;  // Tls13
                System.Net.ServicePointManager.SecurityProtocol |= modern;
            }
            catch
            {
                try
                {
                    System.Net.ServicePointManager.SecurityProtocol |=
                        System.Net.SecurityProtocolType.Tls12;
                }
                catch { /* leave the framework default */ }
            }
            _http = new HttpClient { Timeout = TimeSpan.FromMilliseconds(config.RequestTimeoutMs) };
        }

        /// <summary>Fetch a body for a URL, from the test hook when one is installed.</summary>
        private Task<object> FetchBodyAsync(string url, string token, CancellationToken cancel)
        {
            if (DebugTransport != null)
                return Task.FromResult(DebugTransport(url));
            return GetJsonAsync(url, token, cancel);
        }

        public void Dispose()
        {
            _http.Dispose();
        }

        /// <summary>
        /// Never throws for an API or network problem: it always resolves to a
        /// result carrying either live data or a status the tray can render.
        /// </summary>
        public async Task<LimitsResult> FetchAsync(Action<LimitsResult> onPartial, CancellationToken cancel)
        {
            var credential = Credentials.Resolve(_config);
            if (!credential.Ok)
            {
                return new LimitsResult
                {
                    Status = credential.Error,
                    Source = credential.Source,
                    Message = credential.Message,
                    FetchedAt = DateTime.UtcNow,
                }.BuildDisplay(DateTime.UtcNow);
            }

            var plainCreditsUrl = _config.BaseUrl + _config.CreditsPath;

            // whoami only scopes team accounts, and credits is the critical path:
            // racing them costs the slower of the two, not their sum.
            var whoamiTask = ReadOrgQueryAsync(credential.Token, cancel);
            object creditsBody;
            try
            {
                creditsBody = await FetchBodyAsync(plainCreditsUrl, credential.Token, cancel).ConfigureAwait(false);
            }
            catch (HttpStatusException error)
            {
                if (error.Status == 401 || error.Status == 403)
                {
                    return new LimitsResult
                    {
                        Status = "auth_needed",
                        Source = credential.Source,
                        HttpStatus = error.Status,
                        FetchedAt = DateTime.UtcNow,
                        Message = Lang.T("error.rejected", error.Status),
                    }.BuildDisplay(DateTime.UtcNow);
                }
                return new LimitsResult
                {
                    Status = "http_error",
                    Source = credential.Source,
                    HttpStatus = error.Status,
                    FetchedAt = DateTime.UtcNow,
                    Message = Lang.T("error.http", error.Status),
                }.BuildDisplay(DateTime.UtcNow);
            }
            catch (Exception error)
            {
                return new LimitsResult
                {
                    Status = "network_error",
                    Source = credential.Source,
                    FetchedAt = DateTime.UtcNow,
                    // The transport detail is appended rather than dropped: it is
                    // what turns "network unreachable" into a fixable report.
                    Message = Lang.T("error.network") + " (" + Describe(error) + ")",
                }.BuildDisplay(DateTime.UtcNow);
            }

            var body = Json.UnwrapData(creditsBody);
            var credits = Json.Get(body, "credits");
            var limits = Json.Get(body, "windowLimits");
            var fiveHour = LimitWindow.ParseMilliseconds(Json.Get(limits, "fiveHour"));
            var weekly = LimitWindow.ParseMilliseconds(Json.Get(limits, "weekly"));
            if (fiveHour == null && weekly == null && credits == null)
            {
                return new LimitsResult
                {
                    Status = "http_error",
                    Source = credential.Source,
                    FetchedAt = DateTime.UtcNow,
                    Message = Lang.T("error.schema"),
                }.BuildDisplay(DateTime.UtcNow);
            }

            var orgQuery = await whoamiTask.ConfigureAwait(false);

            var result = new LimitsResult
            {
                Source = credential.Source,
                FetchedAt = DateTime.UtcNow,
                FiveHour = fiveHour,
                Weekly = weekly,
                CreditsPending = credits != null,
            }.BuildDisplay(DateTime.UtcNow);

            // The windows are ready: let the caller paint before the slow tail.
            if (credits != null && onPartial != null)
            {
                try { onPartial(Clone(result)); } catch { /* a failing consumer must not break the fetch */ }
            }

            if (credits == null) return result;

            // Optional tail. A team account needs the org-scoped read; that
            // re-read happens here, after the fast path was already delivered.
            var scopedCredits = credits;
            if (!string.IsNullOrEmpty(orgQuery))
            {
                try
                {
                    var scopedBody = Json.UnwrapData(
                        await FetchBodyAsync(plainCreditsUrl + orgQuery, credential.Token, cancel).ConfigureAwait(false));
                    var scopedLimits = Json.Get(scopedBody, "windowLimits");
                    var scopedFive = LimitWindow.ParseMilliseconds(Json.Get(scopedLimits, "fiveHour"));
                    var scopedWeekly = LimitWindow.ParseMilliseconds(Json.Get(scopedLimits, "weekly"));
                    if (scopedFive != null || scopedWeekly != null)
                    {
                        result.FiveHour = scopedFive;
                        result.Weekly = scopedWeekly;
                    }
                    if (Json.Get(scopedBody, "credits") != null) scopedCredits = Json.Get(scopedBody, "credits");
                }
                catch { /* keep the unscoped read rather than lose the windows */ }
            }

            var period = await ReadPeriodAsync(orgQuery, credential.Token, cancel).ConfigureAwait(false);
            var spend = period != null && period.PeriodStart.HasValue
                ? await ReadSpendAsync(period.PeriodStart.Value, orgQuery, credential.Token, cancel).ConfigureAwait(false)
                : null;

            result.Plan = period == null
                ? null
                : new PlanInfo { Id = period.Id, PeriodStart = period.PeriodStart, PeriodEnd = period.PeriodEnd };
            result.Monthly = ComputeMonthlyWindow(scopedCredits, period, spend == null ? (double?)null : spend.Cost);
            result.Credits = spend == null ? null : ComputeCredits(scopedCredits, period, spend.Cost);
            if (spend != null)
            {
                if (spend.TotalTokens.HasValue)
                {
                    result.Tokens = new TokensInfo
                    {
                        Total = spend.TotalTokens.Value,
                        Input = spend.TokensIn,
                        Output = spend.TokensOut,
                    };
                }
                if (spend.Runs.HasValue)
                {
                    result.Runs = new RunsInfo
                    {
                        Total = spend.Runs.Value,
                        Completed = spend.CompletedRuns,
                        Failed = spend.FailedRuns,
                        SuccessRate = spend.SuccessRate,
                    };
                }
            }
            result.CreditsPending = false;
            result.FetchedAt = DateTime.UtcNow;
            return result.BuildDisplay(DateTime.UtcNow);
        }

        private sealed class PeriodInfo
        {
            public string Id;
            public DateTime? PeriodStart;
            public DateTime? PeriodEnd;
        }

        private sealed class SpendInfo
        {
            public double Cost;
            public double? Runs;
            public double? CompletedRuns;
            public double? FailedRuns;
            public double? SuccessRate;
            public double? TotalTokens;
            public double? TokensIn;
            public double? TokensOut;
        }

        private async Task<string> ReadOrgQueryAsync(string token, CancellationToken cancel)
        {
            try
            {
                var body = Json.UnwrapData(
                    await FetchBodyAsync(_config.BaseUrl + _config.WhoamiPath, token, cancel).ConfigureAwait(false));
                var org = Json.Get(body, "org");
                var id = Json.Text(Json.Get(org, "id"));
                return string.IsNullOrEmpty(id) ? "" : "?orgId=" + Uri.EscapeDataString(id);
            }
            catch
            {
                // Soft probe: a failed whoami just means an unscoped read.
                return "";
            }
        }

        private async Task<PeriodInfo> ReadPeriodAsync(string orgQuery, string token, CancellationToken cancel)
        {
            try
            {
                var body = Json.UnwrapData(await FetchBodyAsync(
                    _config.BaseUrl + _config.SubscriptionsPath + orgQuery, token, cancel).ConfigureAwait(false));
                if (body == null) return null;
                var period = new PeriodInfo
                {
                    Id = Json.Text(Json.Get(body, "planId")),
                    PeriodStart = LimitWindow.ParseTimestamp(Json.Get(body, "currentPeriodStart")),
                    PeriodEnd = LimitWindow.ParseTimestamp(Json.Get(body, "currentPeriodEnd")),
                };
                if (period.Id == null && !period.PeriodStart.HasValue && !period.PeriodEnd.HasValue) return null;
                return period;
            }
            catch
            {
                return null;
            }
        }

        private async Task<SpendInfo> ReadSpendAsync(DateTime since, string orgQuery, string token, CancellationToken cancel)
        {
            var separator = string.IsNullOrEmpty(orgQuery) ? "?" : "&";
            var url = _config.BaseUrl + _config.UsageSummaryPath + orgQuery + separator +
                      "since=" + Uri.EscapeDataString(since.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture));
            try
            {
                var body = Json.UnwrapData(await FetchBodyAsync(url, token, cancel).ConfigureAwait(false));
                if (body == null) return null;
                var cost = Json.Number(Json.Get(body, "totalCost")) ?? Json.Number(Json.Get(body, "totalMonthlyCredits"));
                if (!cost.HasValue || cost.Value < 0) return null;
                return new SpendInfo
                {
                    Cost = cost.Value,
                    Runs = NonNegative(Json.Number(Json.Get(body, "totalCount"))),
                    CompletedRuns = NonNegative(Json.Number(Json.Get(body, "completedCount"))),
                    FailedRuns = NonNegative(Json.Number(Json.Get(body, "failedCount"))),
                    SuccessRate = NonNegative(Json.Number(Json.Get(body, "successRate"))),
                    TotalTokens = NonNegative(Json.Number(Json.Get(body, "totalTokens"))),
                    TokensIn = NonNegative(Json.Number(Json.Get(body, "totalTokensIn"))),
                    TokensOut = NonNegative(Json.Number(Json.Get(body, "totalTokensOut"))),
                };
            }
            catch
            {
                return null;
            }
        }

        private static double? NonNegative(double? value)
        {
            if (!value.HasValue) return null;
            return value.Value < 0 ? (double?)null : value;
        }

        /// <summary>
        /// The monthly window, derived rather than read: `windowLimits` has no
        /// monthly entry, but the monthly cap is the subscription's credit
        /// allowance, and the period spend plus what remains in each pool sums to
        /// it. Verified against what Studio reports for the same account.
        /// </summary>
        private static LimitWindow ComputeMonthlyWindow(object credits, PeriodInfo period, double? spend)
        {
            if (credits == null || period == null || !period.PeriodStart.HasValue) return null;
            if (!spend.HasValue || spend.Value < 0) return null;
            var remaining = Json.Number(Json.Get(credits, "monthlyCredits"));
            if (!remaining.HasValue) return null;
            var purchased = Json.Number(Json.Get(credits, "purchasedCredits")) ?? 0;
            var free = Json.Number(Json.Get(credits, "freeCredits")) ?? 0;
            var cap = spend.Value + Math.Max(0, remaining.Value) + Math.Max(0, purchased) + Math.Max(0, free);
            if (cap <= 0) return null;
            return new LimitWindow
            {
                Used = spend.Value,
                Cap = LimitWindow.Round2(cap),
                Percent = LimitWindow.Round2(LimitWindow.ClampPercent(spend.Value / cap * 100)),
                ResetAt = period.PeriodEnd,
            };
        }

        /// <summary>
        /// The USD line needs a billing period: unscoped spend is lifetime, not
        /// current-cycle, and mixing the two would produce a wrong percentage.
        /// Purchased credits roll over past the period end, so an expiry is only
        /// truthful when there is no purchased pool at all.
        /// </summary>
        private static CreditsInfo ComputeCredits(object credits, PeriodInfo period, double? spend)
        {
            if (credits == null || period == null || !period.PeriodStart.HasValue) return null;
            if (!spend.HasValue || spend.Value < 0) return null;

            var keys = new[] { "monthlyCredits", "purchasedCredits", "freeCredits" };
            var pools = new List<double>();
            var hasPurchasedPool = false;
            foreach (var key in keys)
            {
                var value = Json.Number(Json.Get(credits, key));
                if (!value.HasValue) continue;
                pools.Add(value.Value);
                if (key == "purchasedCredits") hasPurchasedPool = true;
            }
            if (pools.Count == 0) return null;

            var remaining = 0.0;
            foreach (var pool in pools) remaining += Math.Max(0, pool);
            var limit = spend.Value + remaining;
            return new CreditsInfo
            {
                Used = spend.Value,
                Limit = limit,
                Remaining = remaining,
                Percent = LimitWindow.Round2(limit > 0 ? LimitWindow.ClampPercent(spend.Value / limit * 100) : 0),
                ExpiresAt = hasPurchasedPool ? (DateTime?)null : period.PeriodEnd,
            };
        }

        private async Task<object> GetJsonAsync(string url, string token, CancellationToken cancel)
        {
            using (var request = new HttpRequestMessage(HttpMethod.Get, url))
            {
                request.Headers.TryAddWithoutValidation("Accept", "application/json");
                request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + token);
                using (var response = await _http.SendAsync(request, HttpCompletionOption.ResponseContentRead, cancel)
                           .ConfigureAwait(false))
                {
                    if (!response.IsSuccessStatusCode)
                        throw new HttpStatusException((int)response.StatusCode);
                    var text = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
                    if (string.IsNullOrEmpty(text)) return null;
                    return Json.Parse(text);
                }
            }
        }

        private static string Describe(Exception error)
        {
            var aggregate = error as AggregateException;
            if (aggregate != null && aggregate.InnerExceptions.Count > 0) error = aggregate.InnerExceptions[0];
            var inner = error.InnerException;
            while (inner != null) { error = inner; inner = error.InnerException; }
            return error.GetType().Name + ": " + error.Message;
        }

        /// <summary>Deep-enough copy for handing the fast path to a consumer.</summary>
        private static LimitsResult Clone(LimitsResult source)
        {
            return new LimitsResult
            {
                Status = source.Status,
                Message = source.Message,
                HttpStatus = source.HttpStatus,
                Source = source.Source,
                FetchedAt = source.FetchedAt,
                Stale = source.Stale,
                StaleReason = source.StaleReason,
                Revision = source.Revision,
                Plan = source.Plan,
                FiveHour = source.FiveHour,
                Weekly = source.Weekly,
                Monthly = source.Monthly,
                Credits = source.Credits,
                Tokens = source.Tokens,
                Runs = source.Runs,
                CreditsPending = source.CreditsPending,
                FiveHourPercent = source.FiveHourPercent,
                WeeklyPercent = source.WeeklyPercent,
                MonthlyPercent = source.MonthlyPercent,
                FiveHourUsage = source.FiveHourUsage,
                WeeklyUsage = source.WeeklyUsage,
                MonthlyUsage = source.MonthlyUsage,
                FiveHourResetIn = source.FiveHourResetIn,
                WeeklyResetIn = source.WeeklyResetIn,
                MonthlyResetIn = source.MonthlyResetIn,
                FiveHourResetAt = source.FiveHourResetAt,
                WeeklyResetAt = source.WeeklyResetAt,
                MonthlyResetAt = source.MonthlyResetAt,
                TokensValue = source.TokensValue,
                RunsValue = source.RunsValue,
                CreditsText = source.CreditsText,
                Tooltip = source.Tooltip,
            };
        }
    }

    /// <summary>A response with a non-success status, carrying that status.</summary>
    internal sealed class HttpStatusException : Exception
    {
        public readonly int Status;
        public HttpStatusException(int status) : base("HTTP " + status) { Status = status; }
    }
}
