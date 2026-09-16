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
                Console.WriteLine("icona scritta: " + iconPath);
                return 0;
            }

            Console.WriteLine("CommandCode Monitor - selftest");
            Console.WriteLine("  eseguibile : " + Application.ExecutablePath);
            Console.WriteLine("  config     : " + configPath);
            Console.WriteLine();

            Console.WriteLine("Configurazione");
            MonitorConfig config = null;
            Check("config.json leggibile", () =>
            {
                config = MonitorConfig.Load(configPath);
                if (!File.Exists(configPath)) throw new Exception("assente: " + configPath);
                return "baseUrl " + config.BaseUrl + ", refresh " + config.RefreshSeconds + "s";
            });
            if (config == null) return Finish();

            Check("sorgente credenziale trovata", () =>
            {
                var credential = Credentials.Resolve(config);
                if (!credential.Ok) throw new Exception(credential.Message);
                return credential.Source;
            });

            Console.WriteLine();
            Console.WriteLine("Formattazione");
            Check("percentuale arrotondata", () =>
            {
                Equal("37%", Format.Percent(36.59));
                Equal("-", Format.Percent(double.NaN));
                return Format.Percent(36.59);
            });
            Check("importi a due decimali", () =>
            {
                Equal("2", Format.Amount(2.000223421));
                Equal("8,45", Format.Amount(8.452685563));
                Equal("69,91", Format.Amount(69.907555494));
                return Format.Amount(8.452685563);
            });
            Check("conteggio token abbreviato", () =>
            {
                Equal("564,0 M", Format.TokenCount(563961963));
                Equal("1,84 Mrd", Format.TokenCount(1843200000));
                Equal("45,2 K", Format.TokenCount(45231));
                return Format.TokenCount(563961963);
            });
            Check("intervallo di reset leggibile", () =>
            {
                Equal("3h 12m", Format.Delta(TimeSpan.FromMinutes(192)));
                Equal("2g 4h", Format.Delta(TimeSpan.FromMinutes(2 * 1440 + 4 * 60)));
                Equal("ora", Format.Delta(TimeSpan.FromMinutes(-5)));
                return Format.Delta(TimeSpan.FromMinutes(192));
            });

            Console.WriteLine();
            Console.WriteLine("Parsing delle risposte reali");
            Check("pannello popolato da un payload realistico", () =>
            {
                var result = ParseRealistic();
                if (result.Status != null) throw new Exception("status " + result.Status + ": " + result.Message);
                // Values cross-checked by running the same payload through the
                // Node implementation, which yields exactly these strings.
                Equal("20%", result.FiveHourPercent);
                Equal("26%", result.WeeklyPercent);
                Equal("13%", result.MonthlyPercent);
                Equal("564,0 M", result.TokensValue);
                Equal("3120", result.RunsValue);
                if (result.CreditsText == null || !result.CreditsText.StartsWith("Crediti:"))
                    throw new Exception("riga crediti inattesa: " + result.CreditsText);
                if (result.Tooltip.Length > 63) throw new Exception("tooltip troppo lungo: " + result.Tooltip.Length);
                return "5h " + result.FiveHourPercent + ", 7g " + result.WeeklyPercent +
                       ", 30g " + result.MonthlyPercent + ", " + result.TokensValue + ", " + result.RunsValue;
            });
            Check("finestra non aperta non diventa 0%", () =>
            {
                var window = LimitWindow.ParseMilliseconds(Json.Parse("{\"cap\":0,\"used\":0}"));
                if (window != null) throw new Exception("cap 0 deve dare null");
                var clamped = LimitWindow.ParseMilliseconds(Json.Parse("{\"cap\":500,\"used\":750}"));
                Equal(100.0, clamped.Percent);
                return "cap 0 -> assente, uso oltre il cap -> 100%";
            });
            Check("401 segnalato come accesso richiesto", () =>
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
            Check("rete assente segnalata come tale", () =>
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
            Console.WriteLine("Interfaccia");
            Check("icona disegnata a 16x16", () =>
            {
                using (var renderer = new IconRenderer(config))
                using (var icon = renderer.DrawStatusIcon(40, 24))
                using (var bitmap = icon.ToBitmap())
                {
                    var visible = 0;
                    for (var y = 0; y < bitmap.Height; y++)
                        for (var x = 0; x < bitmap.Width; x++)
                            if (bitmap.GetPixel(x, y).A > 40) visible++;
                    if (visible < 30) throw new Exception("icona quasi vuota: " + visible + " pixel");
                    return visible + " pixel visibili (" + bitmap.Width + "x" + bitmap.Height + ")";
                }
            });
            Check("bolla disegnata", () =>
            {
                using (var renderer = new IconRenderer(config))
                using (var bitmap = new Bitmap(IconRenderer.PanelWidth, IconRenderer.PanelHeight))
                {
                    using (var graphics = Graphics.FromImage(bitmap))
                        renderer.DrawPanel(graphics, new Rectangle(0, 0, bitmap.Width, bitmap.Height),
                            ParseRealistic(), false);
                    if (bitmap.GetPixel(4, 4).ToArgb() == Color.Transparent.ToArgb())
                        throw new Exception("sfondo non disegnato");
                    if (renderPath != null)
                    {
                        var directory = Path.GetDirectoryName(Path.GetFullPath(renderPath));
                        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
                        bitmap.Save(renderPath, ImageFormat.Png);
                        return IconRenderer.PanelWidth + "x" + IconRenderer.PanelHeight + " px -> " + renderPath;
                    }
                    return IconRenderer.PanelWidth + "x" + IconRenderer.PanelHeight + " px";
                }
            });
            Check("pulsante di chiusura cliccabile", () =>
            {
                var rect = IconRenderer.CloseRect();
                if (rect.Width < 14 || rect.Height < 14) throw new Exception("area troppo piccola");
                if (rect.Right > IconRenderer.PanelWidth) throw new Exception("fuori dal pannello");
                return rect.ToString();
            });

            return Finish();
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
                throw new Exception("atteso <" + expected + ">, ottenuto <" + actual + ">");
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
            Console.WriteLine("Risultato: " + _passed + " ok, " + _failed + " falliti");
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
