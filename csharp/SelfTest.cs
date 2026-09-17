using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Windows.Forms;

namespace CommandCodeMonitor
{
    /// <summary>
    /// Offline checks for the executable: configuration, credentials, the
    /// formatters, the parsing of real captured API responses, and the drawing.
    ///
    /// This exists because the development sandbox denies Schannel credentials,
    /// so the live HTTP path cannot run there. Everything above the transport is
    /// still proven here, against response bodies captured from the real API, and
    /// the numbers are compared with the values the Node implementation produced
    /// from the same input.
    ///
    /// The labels follow the configured language; the values do not. An assertion
    /// on a formatted number therefore builds its expectation from the active
    /// culture's decimal separator and from the table's unit suffixes, so the same
    /// thirteen checks pass in English, Italian and Chinese.
    /// </summary>
    internal static class SelfTest
    {
        private static int _passed;
        private static int _failed;

        public static int Run(string[] args, string configPath)
        {
            var renderPath = Program_ValueOf(args, "--render");
            var iconPath = Program_ValueOf(args, "--save-icon");

            if (iconPath != null)
            {
                var configForIcon = MonitorConfig.Load(configPath);
                using (var renderer = new IconRenderer(configForIcon))
                    WriteIcon(renderer, iconPath);
                Console.WriteLine(Lang.T("selftest.iconWritten", iconPath));
                return 0;
            }

            Console.WriteLine(Lang.T("selftest.title"));
            Console.WriteLine(Lang.T("selftest.executable", Application.ExecutablePath));
            Console.WriteLine(Lang.T("selftest.config", configPath));
            // Which tables this executable carries: a language missing from the
            // build shows up here instead of as an English interface.
            Console.WriteLine(Lang.T("selftest.languagesLoaded", string.Join(", ", Lang.LanguageCodes())));
            Console.WriteLine();

            Console.WriteLine(Lang.T("selftest.sectionConfig"));
            MonitorConfig config = null;
            Check(Lang.T("selftest.configReadable"), () =>
            {
                config = MonitorConfig.Load(configPath);
                if (!File.Exists(configPath)) throw new Exception("missing: " + configPath);
                return "baseUrl " + config.BaseUrl + ", refresh " + config.RefreshSeconds + "s, language " + Lang.Active;
            });
            if (config == null) return Finish();

            Check(Lang.T("selftest.credentialFound"), () =>
            {
                // Resolved through the same profile list the tray uses, so a named
                // account that forgot its key is reported here as well; a named
                // account deliberately ignores the ambient COMMANDCODE_API_KEY.
                List<Profile> profiles;
                try
                {
                    profiles = Profiles.Resolve(config);
                }
                catch (ConfigException error)
                {
                    throw new Exception(Lang.T("error.profilesInvalid", error.Message));
                }

                var sources = new List<string>();
                foreach (var profile in profiles)
                {
                    var credential = Credentials.Resolve(config.ForProfile(profile));
                    if (!credential.Ok) throw new Exception(profile.Id + ": " + credential.Message);
                    sources.Add(profiles.Count == 1 ? credential.Source : profile.Id + " -> " + credential.Source);
                }
                return string.Join(", ", sources.ToArray());
            });

            Console.WriteLine();
            Console.WriteLine(Lang.T("selftest.sectionFormat"));
            Check(Lang.T("selftest.percentRounded"), () =>
            {
                Equal("37%", Format.Percent(36.59));
                Equal("-", Format.Percent(double.NaN));
                return Format.Percent(36.59);
            });
            Check(Lang.T("selftest.amountsTwoDecimals"), () =>
            {
                Equal("2", Format.Amount(2.000223421));
                Equal("8" + DecimalSeparator + "45", Format.Amount(8.452685563));
                Equal("69" + DecimalSeparator + "91", Format.Amount(69.907555494));
                return Format.Amount(8.452685563);
            });
            Check(Lang.T("selftest.tokenCountAbbreviated"), () =>
            {
                Equal("564" + DecimalSeparator + "0 " + Lang.T("units.million"), Format.TokenCount(563961963));
                Equal("1" + DecimalSeparator + "84 " + Lang.T("units.billion"), Format.TokenCount(1843200000));
                Equal("45" + DecimalSeparator + "2 " + Lang.T("units.thousand"), Format.TokenCount(45231));
                return Format.TokenCount(563961963);
            });
            Check(Lang.T("selftest.resetReadable"), () =>
            {
                Equal("3" + Lang.T("format.hours") + " 12" + Lang.T("format.minutes"),
                    Format.Delta(TimeSpan.FromMinutes(192)));
                Equal("2" + Lang.T("format.days") + " 4" + Lang.T("format.hours"),
                    Format.Delta(TimeSpan.FromMinutes(2 * 1440 + 4 * 60)));
                Equal(Lang.T("format.lessThanMinute"), Format.Delta(TimeSpan.FromMinutes(-5)));
                return Format.Delta(TimeSpan.FromMinutes(192));
            });

            Console.WriteLine();
            Console.WriteLine(Lang.T("selftest.sectionParse"));
            Check(Lang.T("selftest.panelPopulated"), () =>
            {
                var result = ParseRealistic();
                if (result.Status != null) throw new Exception("status " + result.Status + ": " + result.Message);
                // Percentages, run counts and percentages are the same in every
                // language; the token total and the credit row are not.
                Equal("20%", result.FiveHourPercent);
                Equal("26%", result.WeeklyPercent);
                Equal("13%", result.MonthlyPercent);
                Equal("3120", result.RunsValue);
                Equal(Format.TokenCount(563961963), result.TokensValue);
                if (result.CreditsText == null) throw new Exception("no credits row");
                if (result.CreditsText.IndexOf(Format.Amount(result.Credits.Used), StringComparison.Ordinal) < 0 ||
                    result.CreditsText.IndexOf(Format.Amount(result.Credits.Limit), StringComparison.Ordinal) < 0)
                    throw new Exception("credits row does not carry the amounts: " + result.CreditsText);
                if (result.Tooltip.Length > 63) throw new Exception("tooltip too long: " + result.Tooltip.Length);
                return Lang.T("tooltip.fiveHour") + " " + result.FiveHourPercent +
                       ", " + Lang.T("tooltip.weekly") + " " + result.WeeklyPercent +
                       ", " + Lang.T("tooltip.monthly") + " " + result.MonthlyPercent +
                       ", " + result.TokensValue + ", " + result.RunsValue;
            });
            Check(Lang.T("selftest.windowNotZero"), () =>
            {
                var window = LimitWindow.ParseMilliseconds(Json.Parse("{\"cap\":0,\"used\":0}"));
                if (window != null) throw new Exception("a zero cap must yield null");
                var clamped = LimitWindow.ParseMilliseconds(Json.Parse("{\"cap\":500,\"used\":750}"));
                Equal(100.0, clamped.Percent);
                return "zero cap -> absent, usage over the cap -> 100%";
            });
            Check(Lang.T("selftest.authReported"), () =>
            {
                using (var client = new LimitsClient(TestConfig()))
                {
                    client.DebugTransport = url => { throw new HttpStatusException(401); };
                    var result = client.FetchAsync(null, System.Threading.CancellationToken.None)
                        .GetAwaiter().GetResult();
                    Equal("auth_needed", result.Status);
                    return "status " + result.Status;
                }
            });
            Check(Lang.T("selftest.networkReported"), () =>
            {
                using (var client = new LimitsClient(TestConfig()))
                {
                    client.DebugTransport = url => { throw new System.Net.Http.HttpRequestException("no route"); };
                    var result = client.FetchAsync(null, System.Threading.CancellationToken.None)
                        .GetAwaiter().GetResult();
                    Equal("network_error", result.Status);
                    return "status " + result.Status;
                }
            });

            Console.WriteLine();
            Console.WriteLine(Lang.T("selftest.sectionUi"));
            Check(Lang.T("selftest.iconDrawn"), () =>
            {
                using (var renderer = new IconRenderer(config))
                using (var icon = renderer.DrawStatusIcon(40, 24))
                using (var bitmap = icon.ToBitmap())
                {
                    var visible = 0;
                    for (var y = 0; y < bitmap.Height; y++)
                        for (var x = 0; x < bitmap.Width; x++)
                            if (bitmap.GetPixel(x, y).A > 40) visible++;
                    if (visible < 30) throw new Exception("icon nearly empty: " + visible + " pixel");
                    return visible + " visible pixels (" + bitmap.Width + "x" + bitmap.Height + ")";
                }
            });
            Check(Lang.T("selftest.bubbleDrawn"), () =>
            {
                using (var renderer = new IconRenderer(config))
                {
                    // One account: the Accounts section is absent and the panel keeps
                    // its historical size, which is what the check pins down.
                    var model = new PanelModel { Data = ParseRealistic(), Fetching = false };
                    var height = IconRenderer.HeightFor(model.Accounts.Count);
                    using (var bitmap = new Bitmap(IconRenderer.PanelWidth, height))
                    {
                        using (var graphics = Graphics.FromImage(bitmap))
                            renderer.DrawPanel(graphics, new Rectangle(0, 0, bitmap.Width, bitmap.Height), model);
                        if (bitmap.GetPixel(4, 4).ToArgb() == Color.Transparent.ToArgb())
                            throw new Exception("background not drawn");
                        var size = IconRenderer.PanelWidth + "x" + height + " px, " + renderer.PanelFontFamily;
                        if (renderPath != null)
                        {
                            var directory = Path.GetDirectoryName(Path.GetFullPath(renderPath));
                            if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
                            bitmap.Save(renderPath, ImageFormat.Png);
                            return size + " -> " + renderPath;
                        }
                        return size;
                    }
                }
            });
            Check(Lang.T("selftest.closeClickable"), () =>
            {
                var rect = IconRenderer.CloseRect();
                if (rect.Width < 14 || rect.Height < 14) throw new Exception("area too small");
                if (rect.Right > IconRenderer.PanelWidth) throw new Exception("outside the panel");
                return rect.ToString();
            });

            return Finish();
        }

        /// <summary>The decimal separator the active language writes numbers with.</summary>
        private static string DecimalSeparator
        {
            get { return Lang.Culture.NumberFormat.NumberDecimalSeparator; }
        }

        /// <summary>
        /// Replays a realistic set of API bodies through the real parsing path.
        ///
        /// The bodies are inline rather than the shared test fixtures: those are
        /// tuned to the Node suite's expectations, and this check needs the live
        /// account's numbers so the derived monthly figure can be compared with
        /// what Studio reports (13% of a $70 pool).
        ///
        /// The client's transport hook stands in for the network, which the
        /// development sandbox blocks at the Schannel layer.
        /// </summary>
        private static LimitsResult ParseRealistic()
        {
            const string whoami =
                "{\"success\":true,\"user\":{\"id\":\"u1\"},\"org\":null}";
            const string credits =
                "{\"credits\":{\"belowThreshold\":false,\"creditThreshold\":0," +
                "\"monthlyCredits\":61.63,\"purchasedCredits\":0,\"freeCredits\":0}," +
                "\"windowLimits\":{\"limited\":true,\"exceeded\":null," +
                "\"fiveHour\":{\"used\":2.798116965,\"cap\":14,\"exceeded\":false,\"resetAt\":1789466466573}," +
                "\"weekly\":{\"used\":9.250579107,\"cap\":35,\"exceeded\":false,\"resetAt\":1789681097378}}}";
            const string subscriptions =
                "{\"success\":true,\"data\":{\"id\":\"sub_1\",\"status\":\"active\"," +
                "\"currentPeriodStart\":\"2026-09-10T21:25:59.000Z\"," +
                "\"currentPeriodEnd\":\"2026-10-10T21:25:59.000Z\",\"planId\":\"individual-goat\"}}";
            const string usage =
                "{\"totalCount\":3120,\"totalCost\":8.936571315,\"averageCost\":0.00286," +
                "\"successRate\":100,\"completedCount\":3120,\"failedCount\":0," +
                "\"totalTokensIn\":560106201,\"totalTokensOut\":3855762,\"totalTokens\":563961963," +
                "\"totalCredits\":8.936571315,\"periodBasis\":\"billing-period\"}";

            using (var client = new LimitsClient(TestConfig()))
            {
                client.DebugTransport = url =>
                {
                    if (url.IndexOf("whoami", StringComparison.Ordinal) >= 0) return Json.Parse(whoami);
                    if (url.IndexOf("subscriptions", StringComparison.Ordinal) >= 0) return Json.Parse(subscriptions);
                    if (url.IndexOf("usage/summary", StringComparison.Ordinal) >= 0) return Json.Parse(usage);
                    return Json.Parse(credits);
                };
                return client.FetchAsync(null, System.Threading.CancellationToken.None)
                    .GetAwaiter().GetResult();
            }
        }

        private static MonitorConfig TestConfig()
        {
            return new MonitorConfig
            {
                ApiKey = "selftest-token",
                BaseUrl = "https://selftest.invalid",
                RequestTimeoutMs = 2000,
            };
        }

        private static void Equal(object expected, object actual)
        {
            if (!Equals(expected, actual))
                throw new Exception(Lang.T("selftest.expected", expected, actual));
        }

        /// <summary>
        /// Writes a multi-size .ico containing PNG-compressed frames, which
        /// Windows Vista and later read natively. Building it here keeps the
        /// executable's icon identical to the tray icon without shipping a binary
        /// asset that nobody can regenerate.
        /// </summary>
        private static void WriteIcon(IconRenderer renderer, string path)
        {
            var sizes = new[] { 16, 32, 48, 64, 128, 256 };
            var frames = new List<byte[]>();
            foreach (var size in sizes)
            {
                using (var bitmap = renderer.DrawAppBitmap(size))
                using (var stream = new MemoryStream())
                {
                    bitmap.Save(stream, ImageFormat.Png);
                    frames.Add(stream.ToArray());
                }
            }

            var directory = Path.GetDirectoryName(Path.GetFullPath(path));
            if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);

            using (var file = File.Create(path))
            using (var writer = new BinaryWriter(file))
            {
                writer.Write((ushort)0);            // reserved
                writer.Write((ushort)1);            // type: icon
                writer.Write((ushort)sizes.Length); // image count

                var offset = 6 + 16 * sizes.Length;
                for (var index = 0; index < sizes.Length; index++)
                {
                    var size = sizes[index];
                    writer.Write((byte)(size >= 256 ? 0 : size)); // width (0 means 256)
                    writer.Write((byte)(size >= 256 ? 0 : size)); // height
                    writer.Write((byte)0);                        // palette colours
                    writer.Write((byte)0);                        // reserved
                    writer.Write((ushort)1);                      // colour planes
                    writer.Write((ushort)32);                     // bits per pixel
                    writer.Write(frames[index].Length);            // payload size
                    writer.Write(offset);                          // payload offset
                    offset += frames[index].Length;
                }
                foreach (var frame in frames) writer.Write(frame);
            }
        }

        private static void Check(string name, Func<string> body)
        {
            try
            {
                var detail = body();
                _passed++;
                Console.WriteLine("  [ok]   " + name + (string.IsNullOrEmpty(detail) ? "" : " - " + detail));
            }
            catch (Exception error)
            {
                _failed++;
                Console.WriteLine("  [FAIL] " + name + " - " + error.Message);
            }
        }

        private static int Finish()
        {
            Console.WriteLine();
            Console.WriteLine(Lang.T("selftest.result", _passed, _failed));
            // The marker resolves to the same untranslated text in all three tables:
            // scripts/build-exe.ps1 parses this line, and a localized summary would
            // make the build fail in any language but English.
            Console.WriteLine(Lang.T("selftest.marker", _passed, _failed));
            return _failed > 0 ? 1 : 0;
        }

        private static string Program_ValueOf(string[] args, string name)
        {
            for (var index = 0; index < args.Length; index++)
            {
                if (string.Equals(args[index], name, StringComparison.OrdinalIgnoreCase))
                    return index + 1 < args.Length ? args[index + 1] : null;
                if (args[index].StartsWith(name + "=", StringComparison.OrdinalIgnoreCase))
                    return args[index].Substring(name.Length + 1);
            }
            return null;
        }
    }
}
