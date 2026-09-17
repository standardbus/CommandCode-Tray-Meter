using System;
using System.Collections.Generic;
using System.Globalization;

namespace CommandCodeMonitor
{
    /// <summary>A rolling usage window: how much of the cap is used, and when it resets.</summary>
    internal sealed class LimitWindow
    {
        public double Used;
        public double Cap;
        public double Percent;
        public DateTime? ResetAt;

        /// <summary>
        /// A window with no positive cap has not opened yet, or does not apply to
        /// the plan, and must not be rendered as 0% used.
        /// </summary>
        public static LimitWindow Parse(object node)
        {
            var cap = Json.Number(Json.Get(node, "cap"));
            var used = Json.Number(Json.Get(node, "used"));
            if (!cap.HasValue || !used.HasValue) return null;
            if (cap.Value <= 0 || used.Value < 0) return null;

            return new LimitWindow
            {
                Cap = cap.Value,
                Used = used.Value,
                Percent = Round2(ClampPercent(used.Value / cap.Value * 100)),
                ResetAt = ParseTimestamp(Json.Get(node, "resetAt")),
            };
        }

        public static LimitWindow ParseMilliseconds(object node)
        {
            var cap = Json.Number(Json.Get(node, "cap"));
            var used = Json.Number(Json.Get(node, "used"));
            if (!cap.HasValue || !used.HasValue) return null;
            if (cap.Value <= 0 || used.Value < 0) return null;
            return new LimitWindow
            {
                Cap = cap.Value,
                Used = used.Value,
                Percent = Round2(ClampPercent(used.Value / cap.Value * 100)),
                ResetAt = ParseEpochMs(Json.Get(node, "resetAt")),
            };
        }

        internal static double ClampPercent(double value)
        {
            if (double.IsNaN(value)) return 0;
            if (value < 0) return 0;
            if (value > 100) return 100;
            return value;
        }

        internal static double Round2(double value)
        {
            return Math.Round(value * 100) / 100;
        }

        /// <summary>
        /// Accepts ISO text, epoch seconds or epoch milliseconds. The live API
        /// sends epoch milliseconds for the rolling windows and ISO text for the
        /// billing period, so both shapes have to be understood.
        /// </summary>
        internal static DateTime? ParseTimestamp(object node)
        {
            var text = Json.Text(node);
            if (!string.IsNullOrEmpty(text))
            {
                DateTime parsed;
                if (DateTime.TryParse(text, CultureInfo.InvariantCulture,
                        DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out parsed))
                    return parsed;
                return null;
            }
            return ParseEpochMs(node);
        }

        internal static DateTime? ParseEpochMs(object node)
        {
            var value = Json.Number(node);
            if (!value.HasValue || value.Value <= 0) return null;
            // Below ~1e11 the value is seconds, not milliseconds.
            var ms = value.Value < 1e11 ? value.Value * 1000 : value.Value;
            try { return DateTimeOffset.FromUnixTimeMilliseconds((long)ms).UtcDateTime; }
            catch { return null; }
        }
    }

    /// <summary>The USD credit pools and the optional billing-period window.</summary>
    internal sealed class CreditsInfo
    {
        public double Used;
        public double Limit;
        public double Remaining;
        public double Percent;
        public DateTime? ExpiresAt;
    }

    internal sealed class TokensInfo
    {
        public double Total;
        public double? Input;
        public double? Output;
    }

    internal sealed class RunsInfo
    {
        public double Total;
        public double? Completed;
        public double? Failed;
        public double? SuccessRate;
    }

    internal sealed class PlanInfo
    {
        public string Id;
        public DateTime? PeriodStart;
        public DateTime? PeriodEnd;
    }

    /// <summary>
    /// One complete reading of the account, plus the pre-formatted strings the
    /// panel and tooltip draw. Formatting lives here so the UI never touches a
    /// raw API float: the live values carry nine decimals.
    /// </summary>
    internal sealed class LimitsResult
    {
        // Set only on failure; a null Status means the reading is good.
        public string Status;
        public string Message;
        public int? HttpStatus;
        public string Source = "none";

        public DateTime FetchedAt = DateTime.UtcNow;
        public bool Stale;
        public string StaleReason;
        public long Revision;

        public PlanInfo Plan;
        public LimitWindow FiveHour;
        public LimitWindow Weekly;
        public LimitWindow Monthly;
        public CreditsInfo Credits;
        public TokensInfo Tokens;
        public RunsInfo Runs;
        public bool CreditsPending;

        public string FiveHourPercent = "--";
        public string WeeklyPercent = "--";
        public string MonthlyPercent = "--";
        public string FiveHourUsage = "--";
        public string WeeklyUsage = "--";
        public string MonthlyUsage = "--";
        public string FiveHourResetIn;
        public string WeeklyResetIn;
        public string MonthlyResetIn;
        public string FiveHourResetAt;
        public string WeeklyResetAt;
        public string MonthlyResetAt;
        public string TokensValue = "-";
        public string RunsValue = "-";
        public string CreditsText;
        public string Tooltip = Lang.T("status.starting");

        public string PercentFor(string metric)
        {
            switch (metric)
            {
                case "weekly": return WeeklyPercent;
                case "monthly": return MonthlyPercent;
                default: return FiveHourPercent;
            }
        }

        public double? ValueFor(string metric)
        {
            var window = WindowFor(metric);
            return window == null ? (double?)null : window.Percent;
        }

        public LimitWindow WindowFor(string metric)
        {
            switch (metric)
            {
                case "weekly": return Weekly;
                case "monthly": return Monthly;
                default: return FiveHour;
            }
        }

        /// <summary>True once there is something real to draw.</summary>
        public bool HasData
        {
            get { return FiveHour != null || Weekly != null || Monthly != null || Status != null; }
        }

        /// <summary>Recompute every display string from the parsed fields.</summary>
        public LimitsResult BuildDisplay(DateTime now)
        {
            if (FiveHour != null) Fill("FiveHour", FiveHour, now);
            if (Weekly != null) Fill("Weekly", Weekly, now);
            if (Monthly != null) Fill("Monthly", Monthly, now);

            if (Credits != null)
            {
                CreditsText = Lang.T("panel.creditsLine",
                    Format.Amount(Credits.Used), Format.Amount(Credits.Limit), Format.Amount(Credits.Remaining));
            }
            if (Tokens != null) TokensValue = Format.TokenCount(Tokens.Total);
            if (Runs != null) RunsValue = Format.Count(Runs.Total);

            Tooltip = BuildTooltip();
            return this;
        }

        private void Fill(string prefix, LimitWindow window, DateTime now)
        {
            var percent = Format.Percent(window.Percent);
            var usage = Format.UsagePair(window.Used, window.Cap);
            string resetIn = null, resetAt = null;
            if (window.ResetAt.HasValue)
            {
                resetIn = Format.Delta(window.ResetAt.Value - now);
                resetAt = Format.ResetAt(window.ResetAt.Value, now);
            }
            switch (prefix)
            {
                case "Weekly":
                    WeeklyPercent = percent; WeeklyUsage = usage;
                    WeeklyResetIn = resetIn; WeeklyResetAt = resetAt; break;
                case "Monthly":
                    MonthlyPercent = percent; MonthlyUsage = usage;
                    MonthlyResetIn = resetIn; MonthlyResetAt = resetAt; break;
                default:
                    FiveHourPercent = percent; FiveHourUsage = usage;
                    FiveHourResetIn = resetIn; FiveHourResetAt = resetAt; break;
            }
        }

        /// <summary>Compact tooltip text; Windows caps a tray tooltip at 63 characters.</summary>
        private string BuildTooltip()
        {
            if (!string.IsNullOrEmpty(Status))
            {
                return Status == "auth_needed"
                    ? Lang.T("status.authNeeded")
                    : Lang.T("status.unavailable");
            }
            var parts = new List<string>();
            if (FiveHour != null)
            {
                var label = Lang.T("tooltip.fiveHour");
                parts.Add(string.IsNullOrEmpty(FiveHourResetIn)
                    ? Lang.T("tooltip.window", label, FiveHourPercent)
                    : Lang.T("tooltip.windowReset", label, FiveHourPercent, FiveHourResetIn));
            }
            if (Weekly != null) parts.Add(Lang.T("tooltip.window", Lang.T("tooltip.weekly"), WeeklyPercent));
            if (Monthly != null) parts.Add(Lang.T("tooltip.window", Lang.T("tooltip.monthly"), MonthlyPercent));
            if (parts.Count == 0) return Lang.T("status.noLimits");
            return Lang.T("tooltip.full", string.Join(Lang.T("tooltip.separator"), parts.ToArray()));
        }
    }
}
