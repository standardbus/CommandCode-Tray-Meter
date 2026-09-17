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
            // Where the scratch configurations live. Named (and kept) when another
            // program is going to read what this one wrote.
            var scratchRoot = Program_ValueOf(args, "--scratch");

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
            // One payload for every render below. The footer carries a wall-clock
            // stamp with seconds in it, so two renders of "the same" panel a second
            // apart differ in exactly the pixels these checks compare.
            var panel = ParseRealistic();

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
                    // The accounts the configuration names, so the file matches what
                    // the tray would show for it: one account keeps the historical
                    // 306px panel, two or more carry the tab strip and 334.
                    var model = RenderModel(config, panel);
                    var height = IconRenderer.HeightFor(model.Accounts.Count);
                    using (var bitmap = new Bitmap(IconRenderer.PanelWidth, height))
                    {
                        using (var graphics = Graphics.FromImage(bitmap))
                            renderer.DrawPanel(graphics, new Rectangle(0, 0, bitmap.Width, bitmap.Height), model);
                        if (bitmap.GetPixel(4, 4).ToArgb() == Color.Transparent.ToArgb())
                            throw new Exception("background not drawn");
                        var size = IconRenderer.PanelWidth + "x" + height + " px, " + renderer.PanelFontFamily;
                        if (model.Accounts.Count > 1) size += ", " + model.Accounts.Count + " accounts";
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

            // The tab strip is the account switcher. Its whole contract is
            // arithmetic: the strip is exactly additive, and with one account it is
            // not there at all.
            Check(Lang.T("panel.tabTip"), () =>
            {
                Equal(306, IconRenderer.HeightFor(0));
                Equal(306, IconRenderer.HeightFor(1));
                Equal(334, IconRenderer.HeightFor(2));
                Equal(334, IconRenderer.HeightFor(7));
                Equal(0, IconRenderer.StripHeightFor(1));
                Equal(28, IconRenderer.StripHeightFor(2));
                Equal(28, IconRenderer.CloseRect(28).Top - IconRenderer.CloseRect(0).Top);

                for (var count = 2; count <= 6; count++)
                    for (var index = 0; index < count; index++)
                    {
                        var rect = IconRenderer.TabRect(index, count);
                        if (rect.Left < 0 || rect.Right > IconRenderer.PanelWidth)
                            throw new Exception("tab " + (index + 1) + " of " + count + " leaves the panel");
                        if (rect.Bottom > IconRenderer.TabStripHeight)
                            throw new Exception("tab " + (index + 1) + " of " + count + " reaches into the figures");
                        if (index > 0 && rect.Left < IconRenderer.TabRect(index - 1, count).Right)
                            throw new Exception("tabs overlap at " + count + " accounts");

                        // Clicking where a tab is drawn hits that tab, and nothing
                        // else on the strip does.
                        Equal(index, IconRenderer.TabAt(TabCentre(index, count), count));
                    }

                // A single account has no strip, so nowhere is a tab.
                Equal(-1, IconRenderer.TabAt(new Point(20, 14), 1));
                Equal(-1, IconRenderer.TabAt(new Point(20, 14), 0));
                // The gap between two tabs belongs to neither.
                Equal(-1, IconRenderer.TabAt(new Point(108, 14), 3));
                // The close button moved down with the figures, so where it used to
                // be there is now the last tab - which switches account, and is the
                // reason the popup's hit test has to carry the same offset.
                var shifted = IconRenderer.CloseRect(28);
                Equal(9 + 28, shifted.Top);
                Equal(IconRenderer.PanelWidth - 32, shifted.Left);
                Equal(1, IconRenderer.TabAt(new Point(294, 17), 2));
                Equal(-1, IconRenderer.TabAt(new Point(shifted.Left + 8, shifted.Top + 8), 2));
                for (var count = 2; count <= 6; count++)
                    if (IconRenderer.CloseRect(28).Top < IconRenderer.TabStripHeight)
                        throw new Exception("the close button overlaps the strip at " + count + " accounts");

                using (var renderer = new IconRenderer(config))
                {
                    // The proof that a single-account panel is untouched: the two
                    // accounts panel, minus its strip, is the one-account panel
                    // pixel for pixel. The figures were translated, not redrawn.
                    var data = panel;
                    var noNames = new string[0];
                    using (var one = Render(renderer, data, noNames))
                    using (var two = Render(renderer, data, new[] { "Personal", "Work" }))
                    {
                        if (one.Height != 306 || two.Height != 334) throw new Exception("unexpected panel height");

                        // Row 0 is left out, and it is the only row that may be:
                        // GDI+ leaves the first scanline of a fresh bitmap at half
                        // alpha, in the one-account panel and in the renders this
                        // change started from exactly alike. It is not a difference
                        // the panel makes.
                        var differing = 0;
                        for (var y = 1; y < one.Height; y++)
                            for (var x = 0; x < one.Width; x++)
                                if (one.GetPixel(x, y).ToArgb() != two.GetPixel(x, y + 28).ToArgb()) differing++;
                        if (differing > 0)
                            throw new Exception(differing + " pixel below the strip are not the same drawing");
                    }

                    // The strip itself, for a translator to look at, with one name
                    // long enough to be trimmed. Only for a configuration that has no
                    // strip of its own: with two or more accounts the requested file
                    // is already the tabbed panel.
                    if (renderPath != null && ConfiguredProfiles(config).Count < 2)
                    {
                        var names = new[] { "Personal", "Work (a much longer account name)", "Third" };
                        using (var three = Render(renderer, data, names))
                        {
                            var tabs = TabRenderPath(renderPath);
                            var directory = Path.GetDirectoryName(tabs);
                            if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
                            three.Save(tabs, ImageFormat.Png);
                        }
                    }
                }
                return "306 single, 334 with tabs, the figures below are byte for byte the same drawing";
            });

            Console.WriteLine();
            Console.WriteLine(Lang.T("settings.title"));

            Check(Lang.T("settings.accounts"), () =>
            {
                // Ids come from names, because the schema only accepts
                // `^[a-z0-9][a-z0-9-]*$` and the window asks for a name.
                var rows = new List<AccountEdit>();
                rows.Add(new AccountEdit { Id = "work", OriginalName = "Work", Name = "Work" });
                rows.Add(new AccountEdit { Name = "  Work  " });
                rows.Add(new AccountEdit { Name = "Studio 2026!" });
                rows.Add(new AccountEdit { Name = "!!!" });
                rows.Add(new AccountEdit { Id = "personal", OriginalName = "Personal", Name = "Personal 2" });
                var ids = ConfigEditor.DeriveIds(rows);

                Equal("work", ids[0]);        // unchanged name keeps the id it had
                Equal("work-2", ids[1]);      // derived, then made unique
                Equal("studio-2026", ids[2]); // separators collapse, the tail is trimmed
                Equal("account", ids[3]);     // a name the alphabet cannot carry
                Equal("personal-2", ids[4]);  // a rename derives a new id

                var shape = new System.Text.RegularExpressions.Regex("^[a-z0-9][a-z0-9-]*$");
                var seen = new HashSet<string>(StringComparer.Ordinal);
                foreach (var id in ids)
                {
                    if (!shape.IsMatch(id)) throw new Exception("invalid id: " + id);
                    if (!seen.Add(id)) throw new Exception("duplicate id: " + id);
                }
                return string.Join(", ", ids.ToArray());
            });

            Check(Lang.T("settings.nameRequired"), () =>
            {
                var rows = new List<AccountEdit> { new AccountEdit { Name = "   ", ApiKey = "k" } };
                Equal(Lang.T("settings.nameRequired"), ConfigEditor.Validate(rows));
                return Lang.T("settings.nameRequired");
            });

            Check(Lang.T("settings.keyRequired", "Work"), () =>
            {
                // A key, or the environment variable the account already keeps.
                var rows = new List<AccountEdit> { new AccountEdit { Name = "Work" } };
                Equal(Lang.T("settings.keyRequired", "Work"), ConfigEditor.Validate(rows));
                rows[0].ApiKeyEnv = "COMMANDCODE_API_KEY_WORK";
                Equal(null, ConfigEditor.Validate(rows));
                return Lang.T("settings.keyRequired", "Work");
            });

            Check(Lang.T("settings.duplicateName", "Work"), () =>
            {
                var rows = new List<AccountEdit>
                {
                    new AccountEdit { Name = "Work", ApiKey = "a" },
                    new AccountEdit { Name = " work ", ApiKey = "b" },
                };
                Equal(Lang.T("settings.duplicateName", "work"), ConfigEditor.Validate(rows));
                return Lang.T("settings.duplicateName", "work");
            });

            Check(Lang.T("selftest.configReadable"), () =>
            {
                // The round trip, on a scratch copy: a name, a key, a threshold and
                // the language change, and everything the window does not manage
                // has to come back untouched.
                var keep = false;
                var directory = ScratchDirectory(scratchRoot, "preserve", out keep);
                var path = Path.Combine(directory, "config.json");
                try
                {
                    File.WriteAllText(path, ScratchConfig(), new System.Text.UTF8Encoding(false));

                    var edit = new ConfigEdit
                    {
                        Language = "it",
                        RefreshSeconds = 300,
                        Warn = 70,
                        Critical = 90,
                        IconMetric = "monthly",
                        Monochrome = true,
                        ShowTooltip = false,
                        ActiveProfile = "renamed",
                    };
                    edit.Accounts.Add(new AccountEdit
                    {
                        Id = "personal",
                        OriginalName = "Personal",
                        Name = "Renamed",
                        ApiKey = "sk-scratch-inline",
                    });
                    edit.Accounts.Add(new AccountEdit
                    {
                        Id = "work",
                        OriginalName = "Work",
                        Name = "Work",
                        ApiKeyEnv = "COMMANDCODE_API_KEY_WORK",
                    });
                    ConfigEditor.Save(path, edit);

                    // An independent read: the raw bytes, through the parser, with
                    // no help from the writer.
                    var bytes = File.ReadAllBytes(path);
                    if (bytes.Length > 2 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
                        throw new Exception("the file was written with a BOM");
                    var text = new System.Text.UTF8Encoding(false).GetString(bytes);
                    var root = Json.Parse(text) as IDictionary<string, object>;

                    Equal("it", Json.Text(Json.Get(root, "language")));
                    Equal(300.0, Json.Number(Json.Get(root, "refreshSeconds")));
                    Equal(70.0, Json.Number(Json.Get(Json.Get(root, "thresholds"), "warn")));
                    Equal(90.0, Json.Number(Json.Get(Json.Get(root, "thresholds"), "critical")));
                    Equal("monthly", Json.Text(Json.Get(Json.Get(root, "ui"), "iconMetric")));
                    Equal(true, Json.Get(Json.Get(root, "ui"), "monochrome"));
                    Equal(false, Json.Get(Json.Get(root, "ui"), "showTooltip"));
                    Equal("renamed", Json.Text(Json.Get(root, "activeProfile")));

                    // Unknown keys, at the top level and nested, survive.
                    if (Json.Get(root, "$comment_endpoints") == null) throw new Exception("$comment_endpoints was dropped");
                    var endpoints = Json.Get(root, "endpoints");
                    Equal("https://scratch.invalid", Json.Text(Json.Get(endpoints, "baseUrl")));
                    Equal("/alpha/scratch", Json.Text(Json.Get(endpoints, "scratchPath")));
                    Equal(4321.0, Json.Number(Json.Get(root, "requestTimeoutMs")));
                    var creditFiles = Json.Get(root, "creditFiles") as List<object>;
                    if (creditFiles == null || creditFiles.Count != 2) throw new Exception("creditFiles was changed");
                    Equal(1234.0, Json.Number(Json.Get(Json.Get(root, "extra"), "kept")));

                    // The accounts, and the keys: never a mask, never an empty box.
                    var profiles = Json.Get(root, "profiles") as List<object>;
                    if (profiles == null || profiles.Count != 2) throw new Exception("profiles was not rewritten");
                    var first = profiles[0] as IDictionary<string, object>;
                    var second = profiles[1] as IDictionary<string, object>;
                    Equal("renamed", Json.Text(Json.Get(first, "id")));
                    Equal("Renamed", Json.Text(Json.Get(first, "name")));
                    Equal("sk-scratch-inline", Json.Text(Json.Get(first, "apiKey")));
                    Equal(null, Json.Get(first, "apiKeyEnv"));
                    // Even a key inside the account entry this window rewrites.
                    Equal("keep", Json.Text(Json.Get(first, "note")));
                    Equal("work", Json.Text(Json.Get(second, "id")));
                    Equal("COMMANDCODE_API_KEY_WORK", Json.Text(Json.Get(second, "apiKeyEnv")));
                    Equal(null, Json.Get(second, "apiKey"));
                    if (text.IndexOf('\u25CF') >= 0) throw new Exception("a mask character reached the file");

                    // And the document still parses, which is what makes it usable.
                    if (Json.Parse(text) == null) throw new Exception("the written file is not JSON");

                    return "language, thresholds, accounts and keys changed; " +
                           "$comment, endpoints, creditFiles, requestTimeoutMs preserved; UTF-8 without BOM";
                }
                finally
                {
                    if (!keep)
                    {
                        try { Directory.Delete(directory, true); } catch { }
                    }
                }
            });

            Check(Lang.T("settings.keyKept", "COMMANDCODE_API_KEY_WORK"), () =>
            {
                // An account with only an environment variable keeps it, and one
                // whose typed key replaces it loses the variable: an account
                // resolves the variable first, so both together would ignore the key.
                var keep = false;
                var directory = ScratchDirectory(scratchRoot, "credentials", out keep);
                var path = Path.Combine(directory, "config.json");
                try
                {
                    File.WriteAllText(path, ScratchConfig(), new System.Text.UTF8Encoding(false));

                    var edit = new ConfigEdit();
                    edit.Accounts.Add(new AccountEdit
                    {
                        Id = "work",
                        OriginalName = "Work",
                        Name = "Work",
                        ApiKeyEnv = "COMMANDCODE_API_KEY_WORK",
                    });
                    edit.Accounts.Add(new AccountEdit
                    {
                        Id = "personal",
                        OriginalName = "Personal",
                        Name = "Personal",
                        ApiKey = "sk-typed",
                        ApiKeyEnv = "COMMANDCODE_API_KEY_PERSONAL",
                    });
                    ConfigEditor.Save(path, edit);

                    var root = Json.Parse(File.ReadAllText(path)) as IDictionary<string, object>;
                    var profiles = Json.Get(root, "profiles") as List<object>;
                    var work = profiles[0] as IDictionary<string, object>;
                    var personal = profiles[1] as IDictionary<string, object>;
                    Equal("COMMANDCODE_API_KEY_WORK", Json.Text(Json.Get(work, "apiKeyEnv")));
                    Equal(null, Json.Get(work, "apiKey"));
                    Equal("sk-typed", Json.Text(Json.Get(personal, "apiKey")));
                    Equal(null, Json.Get(personal, "apiKeyEnv"));

                    // A configuration without profiles keeps its single-account form
                    // rather than being migrated behind the user's back.
                    var single = Path.Combine(directory, "single.json");
                    File.WriteAllText(single, SingleConfig(), new System.Text.UTF8Encoding(false));
                    var one = new ConfigEdit();
                    one.Accounts.Add(new AccountEdit { Id = "default", OriginalName = "Solo", Name = "Solo", ApiKey = "sk-solo" });
                    ConfigEditor.Save(single, one);

                    var singleRoot = Json.Parse(File.ReadAllText(single)) as IDictionary<string, object>;
                    Equal("sk-solo", Json.Text(Json.Get(singleRoot, "apiKey")));
                    Equal("Solo", Json.Text(Json.Get(singleRoot, "name")));
                    var leftProfiles = Json.Get(singleRoot, "profiles") as List<object>;
                    if (leftProfiles == null || leftProfiles.Count != 0)
                        throw new Exception("a config without profiles grew a profiles list");
                    Equal("keep me", Json.Text(Json.Get(singleRoot, "$comment")));

                    return "environment variable kept, typed key replaces it, single-account form kept";
                }
                finally
                {
                    if (!keep)
                    {
                        try { Directory.Delete(directory, true); } catch { }
                    }
                }
            });

            Check(Lang.T("menu.account"), () =>
            {
                // Picking a tab writes `activeProfile` into config.json as well as
                // into the cache, so the account opens next time even without it.
                var keep = false;
                var directory = ScratchDirectory(scratchRoot, "active", out keep);
                var path = Path.Combine(directory, "config.json");
                try
                {
                    File.WriteAllText(path, ScratchConfig(), new System.Text.UTF8Encoding(false));
                    var before = Json.Parse(File.ReadAllText(path));

                    if (!ConfigEditor.SetActiveProfile(path, "work"))
                        throw new Exception("the choice was not written");

                    var after = Json.Parse(File.ReadAllText(path)) as IDictionary<string, object>;
                    if (after == null) throw new Exception("the written file is not an object");
                    Equal("work", Json.Text(Json.Get(after, "activeProfile")));

                    // The accounts themselves are untouched, and so is everything
                    // else: a tab click may only move that one key.
                    var profiles = Json.Get(after, "profiles") as List<object>;
                    Equal("personal", Json.Text(Json.Get(profiles[0], "id")));
                    Equal("Personal", Json.Text(Json.Get(profiles[0], "name")));
                    Equal("sk-old", Json.Text(Json.Get(profiles[0], "apiKey")));
                    AssertPreserved(before, after, "");

                    // A file that is not there is not created by a tab click.
                    if (ConfigEditor.SetActiveProfile(Path.Combine(directory, "absent.json"), "work"))
                        throw new Exception("a missing config.json was created");

                    return "activeProfile written, every other key untouched";
                }
                finally
                {
                    if (!keep)
                    {
                        try { Directory.Delete(directory, true); } catch { }
                    }
                }
            });

            Check(Lang.T("settings.save"), () => SettingsRoundTrip(scratchRoot, configPath));

            // The crash the user hit while this window was being built: a spinner
            // whose value is assigned below its own Minimum throws
            // "'0' is not a valid value for 'Value'" straight out of the
            // constructor. Whatever a configuration says, the window must open and
            // its spinners must come up inside their ranges.
            Check(Lang.T("settings.refresh") + ", " + Lang.T("settings.warn") + ", " + Lang.T("settings.critical"),
                () => NumericRanges(scratchRoot));

            // And a save that cannot write reports itself in the window instead of
            // throwing out of the click handler.
            Check(Lang.T("settings.saveFailed", "").Trim(),
                () => UnwritableSave(scratchRoot));

            return Finish();
        }

        /// <summary>
        /// Every shape a numeric setting can arrive in, and what the window must do
        /// with it: open, and clamp.
        ///
        /// Two layers are exercised, because they protect against different things:
        /// the files drive the reader, which is what a user can actually write, and
        /// the poisoned configuration objects drive the window's own assignment,
        /// which is the line that threw.
        /// </summary>
        private static string NumericRanges(string scratchRoot)
        {
            var keep = false;
            var directory = ScratchDirectory(scratchRoot, "numeric", out keep);
            try
            {
                // (a) Out of range, and a `ui` object with keys missing. The reader
                // refuses a refresh below 15s and keeps its own default of 120, so
                // 120 is what the spinner has to show; -5 and 150 are clamped to 0
                // and 100 by the reader and again by the window.
                var odd = Path.Combine(directory, "odd.json");
                File.WriteAllText(odd,
                    "{\n" +
                    "  \"apiKey\": \"sk-numbers\",\n" +
                    "  \"refreshSeconds\": 0,\n" +
                    "  \"thresholds\": { \"warn\": -5, \"critical\": 150 },\n" +
                    "  \"ui\": { \"monochrome\": true }\n" +
                    "}\n", new System.Text.UTF8Encoding(false));
                AssertWindow("refreshSeconds 0, warn -5, critical 150, partial ui", odd,
                    MonitorConfig.Load(odd), 120, 0, 100);
                Equal(true, MonitorConfig.Load(odd).Monochrome);

                // (b) Negative again, with no `thresholds` at all.
                var negative = Path.Combine(directory, "negative.json");
                File.WriteAllText(negative,
                    "{\n  \"apiKey\": \"sk-numbers\",\n  \"refreshSeconds\": -30\n}\n",
                    new System.Text.UTF8Encoding(false));
                AssertWindow("refreshSeconds -30, no thresholds", negative,
                    MonitorConfig.Load(negative), 120, 60, 85);

                // (c) Nothing numeric at all: every field on its default.
                var bare = Path.Combine(directory, "bare.json");
                File.WriteAllText(bare, "{\n  \"apiKey\": \"sk-numbers\"\n}\n",
                    new System.Text.UTF8Encoding(false));
                AssertWindow("no refreshSeconds, thresholds or ui", bare,
                    MonitorConfig.Load(bare), 120, 60, 85);

                // (d) The values that threw, put straight into the configuration
                // object: the reader never produces these, so this is the window's
                // own clamp being tested rather than the reader's.
                var poisoned = MonitorConfig.Load(bare);
                poisoned.RefreshSeconds = 0;
                poisoned.WarnThreshold = -5;
                poisoned.CriticalThreshold = 150;
                AssertWindow("poisoned low and high", bare, poisoned, 15, 0, 100);

                poisoned.RefreshSeconds = int.MinValue;
                poisoned.WarnThreshold = double.NaN;
                poisoned.CriticalThreshold = double.PositiveInfinity;
                AssertWindow("int.MinValue, NaN, +infinity", bare, poisoned, 15, 0, 100);

                poisoned.RefreshSeconds = int.MaxValue;
                poisoned.WarnThreshold = double.NegativeInfinity;
                poisoned.CriticalThreshold = 1000;
                AssertWindow("int.MaxValue, -infinity, 1000", bare, poisoned, 86400, 0, 100);

                // What the window would write back is inside the ranges too, so
                // opening a poisoned configuration and pressing Save cannot store
                // the value that could not be shown.
                var written = Path.Combine(directory, "written.json");
                File.Copy(bare, written, true);
                var reloaded = MonitorConfig.Load(written);
                reloaded.RefreshSeconds = 3;
                reloaded.WarnThreshold = -40;
                reloaded.CriticalThreshold = 400;
                string message;
                using (var form = new SettingsForm(written, reloaded))
                {
                    message = form.SaveNow();
                    Equal(true, form.Saved);
                }
                Equal(Lang.T("settings.saved"), message);
                var saved = MonitorConfig.Load(written);
                Equal(15, saved.RefreshSeconds);
                Equal(0.0, saved.WarnThreshold);
                Equal(100.0, saved.CriticalThreshold);

                return "7 out-of-range shapes opened and clamped, nothing thrown";
            }
            finally
            {
                if (!keep)
                {
                    try { Directory.Delete(directory, true); } catch { }
                }
            }
        }

        /// <summary>
        /// The window has to build and the spinners to come up inside 15..86400 and
        /// 0..100. Anything thrown here fails the check, which is the point.
        /// </summary>
        private static void AssertWindow(string label, string path, MonitorConfig config,
            int refresh, double warn, double critical)
        {
            ConfigEdit edit;
            using (var form = new SettingsForm(path, config)) edit = form.Current();

            if (edit.RefreshSeconds < 15 || edit.RefreshSeconds > 86400)
                throw new Exception(label + ": refresh is " + edit.RefreshSeconds);
            if (edit.Warn < 0 || edit.Warn > 100)
                throw new Exception(label + ": warn is " + edit.Warn);
            if (edit.Critical < 0 || edit.Critical > 100)
                throw new Exception(label + ": critical is " + edit.Critical);

            Equal(refresh, edit.RefreshSeconds);
            Equal(warn, edit.Warn);
            Equal(critical, edit.Critical);
        }

        /// <summary>
        /// A save that cannot write must report itself inside the window - the
        /// message the user sees is `settings.saveFailed` - and must not throw out
        /// of the click handler, which is what put the WinForms dialog on screen.
        /// </summary>
        private static string UnwritableSave(string scratchRoot)
        {
            var keep = false;
            var directory = ScratchDirectory(scratchRoot, "unwritable", out keep);
            try
            {
                // A directory where config.json should be: the file cannot be
                // replaced, whatever the permissions on it are. The account has a
                // key, so validation passes and the write is actually reached.
                var path = Path.Combine(directory, "config.json");
                Directory.CreateDirectory(path);

                var config = MonitorConfig.Load(Path.Combine(directory, "none.json"));
                config.ApiKey = "sk-unwritable";
                string message;
                using (var form = new SettingsForm(path, config))
                {
                    message = form.SaveNow();
                    if (form.Saved) throw new Exception("a failed save claims it was saved");
                }

                var prefix = Lang.T("settings.saveFailed", "\u0000").Split('\u0000')[0];
                if (message == null || !message.StartsWith(prefix, StringComparison.Ordinal))
                    throw new Exception("the window shows <" + message + ">, not the save failure");
                if (message.IndexOf("{message}", StringComparison.Ordinal) >= 0)
                    throw new Exception("the failure message was left unfilled: " + message);

                foreach (var leftover in Directory.GetFiles(directory, "*.tmp"))
                    throw new Exception("a temporary file was left behind: " + Path.GetFileName(leftover));

                return "reported in the window: " + prefix.Trim();
            }
            finally
            {
                if (!keep)
                {
                    try { Directory.Delete(directory, true); } catch { }
                }
            }
        }

        /// <summary>
        /// The settings window, built and read back without ever being shown, on a
        /// copy of the file the README tells the user to copy.
        ///
        /// What a code-built window can be checked for offline: that it constructs
        /// against a real configuration, that it reads that configuration faithfully
        /// into its own controls, and that saving it writes what the window says
        /// while leaving every key it does not manage exactly as it was - verified
        /// against the whole original document, not just the keys this test happens
        /// to know about.
        /// </summary>
        private static string SettingsRoundTrip(string scratchRoot, string configPath)
        {
            var keep = false;
            var directory = ScratchDirectory(scratchRoot, "roundtrip", out keep);
            var path = Path.Combine(directory, "config.json");
            try
            {
                // A copy of config.example.json when there is one: the round trip is
                // then about the file the program actually documents. Without one -
                // a configuration kept in a folder of its own - the built-in
                // single-account sample, which is the shape the assertions below
                // read: the two-account shape has its own check.
                var source = ExamplePath(configPath);
                File.WriteAllText(path, source == null ? SingleConfig() : File.ReadAllText(source),
                    new System.Text.UTF8Encoding(false));
                var before = Json.Parse(File.ReadAllText(path));

                var config = MonitorConfig.Load(path);
                var profiles = Profiles.Resolve(config);
                var edit = new ConfigEdit();
                using (var form = new SettingsForm(path, config))
                {
                    if (form.Saved) throw new Exception("a window that was never saved says it was");
                    edit = form.Current();
                }

                // What the window shows is what the file says.
                Equal(profiles.Count, edit.Accounts.Count);
                Equal(profiles[0].Name, edit.Accounts[0].Name);
                Equal(profiles[0].ApiKey, edit.Accounts[0].ApiKey);
                Equal(profiles[0].ApiKeyEnv, edit.Accounts[0].ApiKeyEnv);
                Equal(config.RefreshSeconds, edit.RefreshSeconds);
                Equal(config.WarnThreshold, edit.Warn);
                Equal(config.CriticalThreshold, edit.Critical);
                Equal(config.IconMetric, edit.IconMetric);
                Equal(config.Monochrome, edit.Monochrome);
                Equal(config.ShowTooltip, edit.ShowTooltip);

                // Then change a name, a key, a threshold and the language, and save.
                const string key = "sk-roundtrip-key";
                edit.Accounts[0].Name = "Round trip";
                edit.Accounts[0].ApiKey = key;
                edit.Accounts[0].ApiKeyEnv = "";
                edit.Language = "it";
                edit.Warn = 42;
                edit.Critical = 93;
                edit.RefreshSeconds = 240;
                edit.IconMetric = "weekly";
                edit.Monochrome = true;
                edit.ShowTooltip = false;
                ConfigEditor.Save(path, edit);

                var text = File.ReadAllText(path);
                var after = Json.Parse(text) as IDictionary<string, object>;
                if (after == null) throw new Exception("the written file is not an object");
                if (text.Length == 0 || text[0] != '{') throw new Exception("the file does not start with an object");

                // The write goes through a temporary file in the same directory:
                // the replacement must have taken the old file's place and left
                // nothing of the temporary one behind.
                foreach (var leftover in Directory.GetFiles(directory, "*.tmp"))
                    throw new Exception("a temporary file was left behind: " + Path.GetFileName(leftover));

                Equal("Round trip", Json.Text(Json.Get(after, "name")));
                Equal(key, Json.Text(Json.Get(after, "apiKey")));
                Equal("it", Json.Text(Json.Get(after, "language")));
                Equal(240.0, Json.Number(Json.Get(after, "refreshSeconds")));
                Equal(42.0, Json.Number(Json.Get(Json.Get(after, "thresholds"), "warn")));
                Equal(93.0, Json.Number(Json.Get(Json.Get(after, "thresholds"), "critical")));
                Equal("weekly", Json.Text(Json.Get(Json.Get(after, "ui"), "iconMetric")));
                Equal(true, Json.Get(Json.Get(after, "ui"), "monochrome"));
                Equal(false, Json.Get(Json.Get(after, "ui"), "showTooltip"));
                if (text.IndexOf('\u25CF') >= 0) throw new Exception("a mask character reached the file");
                if (text.IndexOf(key, StringComparison.Ordinal) < 0) throw new Exception("the key is not in the file");

                // Everything else, key by key and nested, as the file had it.
                AssertPreserved(before, after, "");

                // The same window with a list long enough to need the strip and the
                // scrollbar: six accounts, one per row, ids derived and unique.
                var many = Path.Combine(directory, "many.json");
                var entries = new List<object>();
                for (var index = 1; index <= 6; index++)
                {
                    var entry = new JsonObject();
                    entry["id"] = "account-" + index;
                    entry["name"] = "Account " + index;
                    entry["apiKey"] = "sk-many-" + index;
                    entries.Add(entry);
                }
                var manyRoot = new JsonObject();
                manyRoot["profiles"] = entries;
                manyRoot["$comment_many"] = "kept while six accounts are saved";
                File.WriteAllText(many, Json.Write(manyRoot), new System.Text.UTF8Encoding(false));

                var manyBefore = Json.Parse(File.ReadAllText(many));
                ConfigEdit six;
                using (var form = new SettingsForm(many, MonitorConfig.Load(many)))
                {
                    six = form.Current();
                    Equal(6, six.Accounts.Count);
                }
                ConfigEditor.Save(many, six);

                var manyAfter = Json.Parse(File.ReadAllText(many)) as IDictionary<string, object>;
                var manyProfiles = Json.Get(manyAfter, "profiles") as List<object>;
                Equal(6, manyProfiles.Count);
                var ids = new HashSet<string>(StringComparer.Ordinal);
                foreach (var raw in manyProfiles)
                {
                    var id = Json.Text(Json.Get(raw, "id"));
                    if (!ids.Add(id)) throw new Exception("duplicate id after saving six accounts: " + id);
                }
                AssertPreserved(manyBefore, manyAfter, "");

                return "window built, file read back, changes written, every other key preserved (" +
                       (source == null ? "built-in sample" : "config.example.json copy") + ")";
            }
            finally
            {
                if (!keep)
                {
                    try { Directory.Delete(directory, true); } catch { }
                }
            }
        }

        /// <summary>
        /// Every key of `original` that this program does not manage must still be
        /// there, with the same value, at the same place.
        /// </summary>
        private static void AssertPreserved(object original, object written, string prefix)
        {
            var a = original as IDictionary<string, object>;
            if (a != null)
            {
                var b = written as IDictionary<string, object>;
                if (b == null) throw new Exception(prefix + " is no longer an object");
                foreach (var pair in a)
                {
                    var path = prefix.Length == 0 ? pair.Key : prefix + "." + pair.Key;
                    if (Managed(path)) continue;
                    object other;
                    if (!b.TryGetValue(pair.Key, out other)) throw new Exception(path + " was dropped");
                    AssertPreserved(pair.Value, other, path);
                }
                return;
            }

            var listA = original as List<object>;
            if (listA != null)
            {
                var listB = written as List<object>;
                if (listB == null || listB.Count != listA.Count)
                    throw new Exception(prefix + " is no longer a list of " + listA.Count);
                for (var index = 0; index < listA.Count; index++)
                    AssertPreserved(listA[index], listB[index], prefix + "[" + index + "]");
                return;
            }

            if (!Equals(original, written))
                throw new Exception(prefix + " changed from <" +
                    (original == null ? "null" : original.ToString()) + "> to <" +
                    (written == null ? "null" : written.ToString()) + ">");
        }

        /// <summary>The keys the settings window owns, which are allowed to change.</summary>
        private static bool Managed(string path)
        {
            switch (path)
            {
                case "profiles":
                case "activeProfile":
                case "language":
                case "refreshSeconds":
                case "apiKey":
                case "apiKeyEnv":
                case "name":
                case "thresholds.warn":
                case "thresholds.critical":
                case "ui.iconMetric":
                case "ui.monochrome":
                case "ui.showTooltip":
                    return true;
                default:
                    return false;
            }
        }

        /// <summary>config.example.json next to the configuration, when it is there.</summary>
        private static string ExamplePath(string configPath)
        {
            if (string.IsNullOrEmpty(configPath)) return null;
            try
            {
                var directory = Path.GetDirectoryName(Path.GetFullPath(configPath));
                if (string.IsNullOrEmpty(directory)) return null;
                var example = Path.Combine(directory, "config.example.json");
                return File.Exists(example) ? example : null;
            }
            catch
            {
                return null;
            }
        }

        /// <summary>
        /// A directory for one scratch configuration. With `--scratch` it is the
        /// named directory and its files are kept, so another program can read what
        /// this one wrote; without it, a fresh temporary directory, removed after.
        /// </summary>
        private static string ScratchDirectory(string scratchRoot, string name, out bool keep)
        {
            keep = !string.IsNullOrEmpty(scratchRoot);
            var directory = keep
                ? Path.Combine(scratchRoot, name)
                : Path.Combine(Path.GetTempPath(), "ccm-selftest-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            return directory;
        }

        /// <summary>
        /// The accounts a configuration names, in its own order, or none when the
        /// list cannot be read: the panel reports a broken list, a render must not
        /// fail on one.
        /// </summary>
        private static List<Profile> ConfiguredProfiles(MonitorConfig config)
        {
            try
            {
                return Profiles.Resolve(config);
            }
            catch (ConfigException)
            {
                return new List<Profile>();
            }
        }

        /// <summary>
        /// The panel `--render` draws: the accounts the configuration names, one tab
        /// each once there are two or more, and the realistic payload as the active
        /// reading.
        ///
        /// The same precedence the tray uses picks the active account - the
        /// remembered choice, then `activeProfile`, then the first - so the image
        /// matches the bubble. Nothing here fetches anything: a render has to work
        /// with no network and no real credential.
        /// </summary>
        private static PanelModel RenderModel(MonitorConfig config, LimitsResult data)
        {
            var model = new PanelModel { Data = data, Fetching = false };
            var profiles = ConfiguredProfiles(config);
            if (profiles.Count < 2) return model;

            var wanted = ProfileState.Open(config.SourcePath).ActiveProfile;
            if (string.IsNullOrEmpty(wanted)) wanted = (config.ActiveProfile ?? "").Trim().ToLowerInvariant();

            var activeIndex = 0;
            if (wanted.Length > 0)
            {
                for (var index = 0; index < profiles.Count; index++)
                {
                    if (!string.Equals(profiles[index].Id, wanted, StringComparison.Ordinal)) continue;
                    activeIndex = index;
                    break;
                }
            }

            for (var index = 0; index < profiles.Count; index++)
                model.Accounts.Add(new AccountRow
                {
                    Name = profiles[index].Name,
                    Active = index == activeIndex,
                });
            return model;
        }

        /// <summary>The middle of a tab, where a click has to land on it.</summary>
        private static Point TabCentre(int index, int count)
        {
            var rect = IconRenderer.TabRect(index, count);
            return new Point(rect.Left + rect.Width / 2, rect.Top + rect.Height / 2);
        }

        /// <summary>
        /// The file the tab strip is rendered to when `--render` asks for a panel:
        /// next to it, with `-tabs` on the name.
        /// </summary>
        private static string TabRenderPath(string renderPath)
        {
            var full = Path.GetFullPath(renderPath);
            var directory = Path.GetDirectoryName(full);
            var name = Path.GetFileNameWithoutExtension(full) + "-tabs.png";
            return string.IsNullOrEmpty(directory) ? name : Path.Combine(directory, name);
        }

        /// <summary>
        /// The panel of a model with the given account names, drawn the way the
        /// bubble draws it. The first account is the active one.
        /// </summary>
        private static Bitmap Render(IconRenderer renderer, LimitsResult data, string[] names)
        {
            var model = new PanelModel { Data = data, Fetching = false };
            for (var index = 0; index < names.Length; index++)
                model.Accounts.Add(new AccountRow { Name = names[index], Active = index == 0 });

            var height = IconRenderer.HeightFor(model.Accounts.Count);
            var bitmap = new Bitmap(IconRenderer.PanelWidth, height);
            using (var graphics = Graphics.FromImage(bitmap))
                renderer.DrawPanel(graphics, new Rectangle(0, 0, bitmap.Width, bitmap.Height), model);
            return bitmap;
        }

        /// <summary>
        /// A configuration for the round-trip checks, shaped like the real file: the
        /// notes, the endpoints, two accounts and a nested key no reader knows.
        /// </summary>
        private static string ScratchConfig()
        {
            return "{\n" +
                   "  \"$comment_endpoints\": \"the notes have to survive\",\n" +
                   "  \"endpoints\": {\n" +
                   "    \"baseUrl\": \"https://scratch.invalid\",\n" +
                   "    \"scratchPath\": \"/alpha/scratch\",\n" +
                   "    \"whoamiPath\": \"/alpha/whoami\"\n" +
                   "  },\n" +
                   "  \"extra\": { \"kept\": 1234 },\n" +
                   "  \"profiles\": [\n" +
                   "    { \"id\": \"personal\", \"name\": \"Personal\", \"apiKey\": \"sk-old\", \"note\": \"keep\" },\n" +
                   "    { \"id\": \"work\", \"name\": \"Work\", \"apiKeyEnv\": \"COMMANDCODE_API_KEY_WORK\" }\n" +
                   "  ],\n" +
                   "  \"activeProfile\": \"personal\",\n" +
                   "  \"language\": \"en\",\n" +
                   "  \"refreshSeconds\": 120,\n" +
                   "  \"thresholds\": { \"warn\": 60, \"critical\": 85 },\n" +
                   "  \"ui\": { \"iconMetric\": \"fiveHour\", \"monochrome\": false, \"showTooltip\": true },\n" +
                   "  \"creditFiles\": [ \"~/.commandcode/auth.json\", \"~/.pi/agent/auth.json\" ],\n" +
                   "  \"requestTimeoutMs\": 4321\n" +
                   "}\n";
        }

        /// <summary>A configuration in the single-account form, with a note to keep.</summary>
        private static string SingleConfig()
        {
            return "{\n" +
                   "  \"$comment\": \"keep me\",\n" +
                   "  \"apiKey\": \"sk-old\",\n" +
                   "  \"profiles\": [],\n" +
                   "  \"language\": \"en\"\n" +
                   "}\n";
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
            if (Equals(expected, actual)) return;
            // A null argument would leave its placeholder standing in the message
            // ("got <{actual}>"), which hides what actually failed.
            throw new Exception(Lang.T("selftest.expected",
                expected == null ? "null" : expected,
                actual == null ? "null" : actual));
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
