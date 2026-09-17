using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

namespace CommandCodeMonitor
{
    /// <summary>
    /// The tray application: owns the icon, the bubble, the polling loop and the
    /// dismissal rules.
    ///
    /// Every configured account is fetched, in parallel, and the icon follows the
    /// active one. With a single account - every configuration that predates
    /// profiles - the behaviour is exactly what it always was.
    /// </summary>
    internal sealed class MainForm : ApplicationContext
    {
        private const int WhMouseLl = 14;
        private const int WmLButtonDown = 0x0201;
        private const int WmRButtonDown = 0x0204;
        private const int WmMButtonDown = 0x0207;
        private const int WmMouseWheel = 0x020A;
        private const int WmMouseHWheel = 0x020E;
        private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string RunValueName = "CommandCodeMonitor";

        private readonly MonitorConfig _config;
        private readonly IconRenderer _renderer;
        private readonly NotifyIcon _tray;
        private readonly PopupForm _popup;
        private readonly ToolStripMenuItem _autostartItem;
        private readonly System.Windows.Forms.Timer _tick;
        private readonly System.Windows.Forms.Timer _refresh;
        private readonly System.Windows.Forms.Timer _watchdog;

        /// <summary>Every configured account, in configuration order.</summary>
        private readonly List<MonitorAccount> _accounts = new List<MonitorAccount>();
        /// <summary>The menu entry per account id, so the check mark can follow the choice.</summary>
        private readonly Dictionary<string, ToolStripMenuItem> _accountItems =
            new Dictionary<string, ToolStripMenuItem>(StringComparer.Ordinal);
        private readonly ProfileState _state;

        /// <summary>The account the icon, the tooltip and the panel follow.</summary>
        private MonitorAccount _active;

        private long _revision;
        private bool _closing;
        private string _iconSignature = "";
        private IntPtr _mouseHook = IntPtr.Zero;
        private NativeMethods.HookProc _mouseHookProc;
        private bool _demo;

        /// <summary>
        /// In demo mode the bubble opens by itself and the program exits after a
        /// few seconds. Used to prove the real window paints and dismisses,
        /// which rendering to a bitmap cannot show.
        /// </summary>
        public void EnableDemo(int showAfterMs, int quitAfterMs)
        {
            _demo = true;
            Diag(Lang.T("demo.starting", showAfterMs, quitAfterMs));
            var show = new System.Windows.Forms.Timer { Interval = showAfterMs };
            show.Tick += (sender, args) =>
            {
                show.Stop();
                show.Dispose();
                ShowBubble();
            };
            show.Start();

            var quit = new System.Windows.Forms.Timer { Interval = quitAfterMs };
            quit.Tick += (sender, args) =>
            {
                quit.Stop();
                quit.Dispose();
                // The state is logged once, at close: the bubble has been on screen
                // for the whole run by then, which is what this diagnostic proves.
                Diag(Lang.T("demo.closeRequested", DescribeState()));
                Quit();
                Diag(Lang.T("demo.quitReturned"));
            };
            quit.Start();
        }

        /// <summary>Diagnostics for a demo run, written where a console can read it.</summary>
        private static void Diag(string message)
        {
            try
            {
                var path = Path.Combine(Path.GetTempPath(), "ccm-diag.log");
                File.AppendAllText(path, DateTime.Now.ToString("HH:mm:ss.fff") + "  " + message + Environment.NewLine);
            }
            catch { }
        }

        /// <summary>Diagnostics for the demo run: what the bubble believes.</summary>
        public string DescribeState()
        {
            // Field names, not prose: this line is read by a developer in the diag
            // log, and only the window labels and the "no data" marker are text.
            var data = _active == null ? null : _active.Data;
            var status = data == null ? Lang.T("demo.noData") : (data.Status ?? "ok");
            return "visible=" + _popup.Visible +
                   " bounds=" + _popup.Bounds +
                   " profile=" + (_active == null ? "-" : _active.Profile.Id) +
                   " status=" + status +
                   " " + Lang.T("tooltip.fiveHour") + "=" + (data == null ? "--" : data.FiveHourPercent) +
                   " " + Lang.T("tooltip.monthly") + "=" + (data == null ? "--" : data.MonthlyPercent);
        }

        public MainForm(MonitorConfig config)
        {
            _config = config;
            _renderer = new IconRenderer(config);
            _state = ProfileState.Open(config.SourcePath);
            CreateAccounts();
            _active = PickActiveAccount();
            _popup = new PopupForm(_renderer, BuildPanel);
            _popup.CloseRequested += (sender, args) => HideBubble();

            var menu = new ContextMenuStrip();
            menu.Items.Add(Lang.T("menu.show"), null, (sender, args) => ShowBubble());
            menu.Items.Add(Lang.T("menu.refresh"), null, (sender, args) => StartUpdate());
            menu.Items.Add(Lang.T("menu.openConfig", Path.GetFileName(config.SourcePath)), null,
                (sender, args) => OpenConfig());
            menu.Items.Add(Lang.T("menu.settings"), null,
                (sender, args) => Process.Start("https://commandcode.ai/settings/keys"));
            // A single account needs no submenu: there is nothing to choose.
            if (_accounts.Count > 1) menu.Items.Add(BuildAccountMenu());
            _autostartItem = new ToolStripMenuItem(Lang.T("menu.autostart"), null, (sender, args) => ToggleAutostart());
            _autostartItem.Checked = IsAutostartEnabled();
            menu.Items.Add(_autostartItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(Lang.T("menu.exit"), null, (sender, args) => Quit());

            _tray = new NotifyIcon
            {
                Icon = _renderer.DrawStatusIcon(null, null),
                Text = Lang.T("status.starting"),
                ContextMenuStrip = menu,
                Visible = true,
            };
            _tray.MouseClick += (sender, args) =>
            {
                if (args.Button == MouseButtons.Left) ShowBubble();
            };
            _tray.DoubleClick += (sender, args) => ShowBubble();

            _tick = new System.Windows.Forms.Timer { Interval = 1000 };
            _tick.Tick += (sender, args) => OnTick();

            _refresh = new System.Windows.Forms.Timer { Interval = Math.Max(15, config.RefreshSeconds) * 1000 };
            _refresh.Tick += (sender, args) =>
            {
                // Skipped while the bubble is open: the tick already polls there.
                if (!_popup.Visible) StartUpdate();
            };

            _watchdog = new System.Windows.Forms.Timer { Interval = 1000 };
            _watchdog.Tick += (sender, args) =>
            {
                if (_active != null && _active.Data != null && _active.Data.HasData) { _watchdog.Stop(); return; }
                if (!_active.Fetching) StartUpdate();
            };

            _tick.Start();
            _refresh.Start();
            _watchdog.Start();
            StartUpdate();
        }

        // --- accounts -------------------------------------------------------

        /// <summary>
        /// Build every account, and every client, once at startup.
        ///
        /// An unusable `profiles` list is neither a crash nor an empty tray: it
        /// becomes one account carrying the reason, which the panel and the tooltip
        /// already know how to render.
        /// </summary>
        private void CreateAccounts()
        {
            List<Profile> profiles;
            try
            {
                profiles = Profiles.Resolve(_config);
            }
            catch (ConfigException error)
            {
                var broken = new MonitorAccount { Profile = new Profile { Id = "config", Name = "config" } };
                broken.Data = new LimitsResult
                {
                    Status = "http_error",
                    Message = Lang.T("error.profilesInvalid", error.Message),
                    FetchedAt = DateTime.UtcNow,
                }.BuildDisplay(DateTime.UtcNow);
                _accounts.Add(broken);
                return;
            }

            foreach (var profile in profiles)
            {
                _accounts.Add(new MonitorAccount
                {
                    Profile = profile,
                    Client = new LimitsClient(_config.ForProfile(profile)),
                });
            }
        }

        /// <summary>
        /// The account the tray follows: the one picked in the menu last time, else
        /// `activeProfile` from the configuration, else the first.
        ///
        /// The remembered choice outranks the configuration because it is the more
        /// recent statement of intent, and remembering it is the whole point; an id
        /// that no longer names an account is ignored rather than trusted, and the
        /// configuration decides. The same precedence as `resolveActiveProfileId`
        /// in `src/limits.mjs`.
        /// </summary>
        private MonitorAccount PickActiveAccount()
        {
            var remembered = FindAccount(_state.ActiveProfile);
            if (remembered != null) return remembered;
            var configured = FindAccount((_config.ActiveProfile ?? "").Trim().ToLowerInvariant());
            return configured ?? _accounts[0];
        }

        private MonitorAccount FindAccount(string id)
        {
            if (string.IsNullOrEmpty(id)) return null;
            foreach (var account in _accounts)
                if (string.Equals(account.Profile.Id, id, StringComparison.Ordinal)) return account;
            return null;
        }

        private ToolStripMenuItem BuildAccountMenu()
        {
            var parent = new ToolStripMenuItem(Lang.T("menu.account"));
            foreach (var account in _accounts)
            {
                var target = account;
                var item = new ToolStripMenuItem(account.Profile.Name) { Checked = account == _active, CheckOnClick = false };
                item.Click += (sender, args) => ActivateAccount(target);
                _accountItems[account.Profile.Id] = item;
                parent.DropDownItems.Add(item);
            }
            return parent;
        }

        /// <summary>
        /// Follow another account. The choice is runtime state and is written to
        /// `.cache`, never to config.json: this program does not rewrite the file
        /// the user maintains.
        /// </summary>
        private void ActivateAccount(MonitorAccount account)
        {
            if (account == null || account == _active) return;
            _active = account;
            _state.Remember(account.Profile.Id);
            foreach (var entry in _accountItems)
                entry.Value.Checked = entry.Key == account.Profile.Id;

            // The icon, the tooltip and the panel all describe the active account,
            // so the cached signature must not survive the switch.
            _iconSignature = "";
            UpdateTray();
            if (_popup.Visible) _popup.Refresh_NoActivate();
            StartUpdate();
        }

        // --- polling --------------------------------------------------------

        /// <summary>
        /// Kick a fetch off for every account that is not already fetching. Never
        /// blocks the UI thread: the fast path is folded in when it lands and the
        /// slow tail replaces it later.
        /// </summary>
        private void StartUpdate()
        {
            if (_closing) return;
            foreach (var account in _accounts)
            {
                if (account.Fetching || account.Client == null) continue;
                var target = account;
                target.Fetching = true;
                target.Pending = new CancellationTokenSource();
                var token = target.Pending.Token;

                Task.Run(async () =>
                {
                    try
                    {
                        var result = await target.Client.FetchAsync(partial =>
                        {
                            BeginInvokeSafe(() => ApplyResult(target, partial, true));
                        }, token).ConfigureAwait(false);

                        if (token.IsCancellationRequested) return;
                        BeginInvokeSafe(() => ApplyResult(target, result, false));
                    }
                    catch (Exception error)
                    {
                        BeginInvokeSafe(() => ApplyFailure(target, error));
                    }
                });
            }
        }

        /// <summary>
        /// Publish a reading. A failed fetch must not blank the numbers the user
        /// is looking at, so the previous ones are kept and flagged stale.
        /// </summary>
        private void ApplyResult(MonitorAccount account, LimitsResult result, bool partial)
        {
            if (_closing) return;
            var previous = account.Data;
            _revision += 1;
            result.Revision = _revision;

            if (!string.IsNullOrEmpty(result.Status))
            {
                if (previous != null && string.IsNullOrEmpty(previous.Status))
                {
                    previous.Stale = true;
                    previous.StaleReason = result.Message;
                }
                else
                {
                    account.Data = result;
                }
            }
            else if (partial && previous != null)
            {
                // Keep the slow-tail fields: a partial result means "these windows
                // are newer", not "forget the rest".
                result.Credits = previous.Credits;
                result.CreditsText = previous.CreditsText;
                result.Tokens = previous.Tokens;
                result.TokensValue = previous.TokensValue;
                result.Runs = previous.Runs;
                result.RunsValue = previous.RunsValue;
                result.Monthly = previous.Monthly;
                result.MonthlyPercent = previous.MonthlyPercent;
                result.MonthlyUsage = previous.MonthlyUsage;
                result.MonthlyResetIn = previous.MonthlyResetIn;
                result.MonthlyResetAt = previous.MonthlyResetAt;
                result.Plan = previous.Plan;
                result.Tooltip = previous.Tooltip;
                account.Data = result;
            }
            else
            {
                account.Data = result;
            }

            if (!partial)
            {
                account.Fetching = false;
                DisposePending(account);
            }

            // Only the active account drives the icon, but every account owns a row
            // in the open bubble, so any of them landing repaints it.
            if (account == _active) UpdateTray();
            if (_popup.Visible) _popup.Refresh_NoActivate();
        }

        private void ApplyFailure(MonitorAccount account, Exception error)
        {
            account.Fetching = false;
            DisposePending(account);
            if (account.Data != null)
            {
                account.Data.Stale = true;
                account.Data.StaleReason = error.Message;
            }
            else
            {
                account.Data = new LimitsResult
                {
                    Status = "network_error",
                    Message = Lang.T("error.unexpected", error.Message),
                    FetchedAt = DateTime.UtcNow,
                }.BuildDisplay(DateTime.UtcNow);
            }
            if (account == _active) UpdateTray();
            if (_popup.Visible) _popup.Refresh_NoActivate();
        }

        private static void DisposePending(MonitorAccount account)
        {
            if (account.Pending == null) return;
            try { account.Pending.Dispose(); } catch { }
            account.Pending = null;
        }

        /// <summary>
        /// Hand work to the UI thread. Uses the bubble's window handle, which
        /// exists for the lifetime of the program even while the bubble is
        /// hidden, so this works before the first show as well.
        /// </summary>
        private void BeginInvokeSafe(Action action)
        {
            if (_closing) return;
            try
            {
                if (_popup != null && _popup.IsHandleCreated)
                    _popup.BeginInvoke(action);
                else
                    action();
            }
            catch
            {
                // A torn-down handle during shutdown must not surface as a crash.
            }
        }

        private void OnTick()
        {
            // Nothing to poll: fresh numbers arrive through ApplyResult, and the
            // bubble repaints from the cached reading when they do.
        }

        // --- presentation ---------------------------------------------------

        /// <summary>What the bubble draws: the active reading plus one row per account.</summary>
        private PanelModel BuildPanel()
        {
            var data = _active == null ? null : _active.Data;
            var model = new PanelModel
            {
                Data = data,
                Fetching = _active != null && _active.Fetching,
            };
            if (_accounts.Count > 1)
            {
                foreach (var account in _accounts)
                {
                    model.Accounts.Add(new AccountRow
                    {
                        Name = account.Profile.Name,
                        Active = account == _active,
                        Five = PercentOf(account.Data, "fiveHour"),
                        Weekly = PercentOf(account.Data, "weekly"),
                        Monthly = PercentOf(account.Data, "monthly"),
                    });
                }
            }
            return model;
        }

        private static string PercentOf(LimitsResult data, string metric)
        {
            return data == null ? "--" : data.PercentFor(metric);
        }

        private void UpdateTray()
        {
            var data = _active == null ? null : _active.Data;
            double? ring = null;
            double? weekly = null;
            string tooltip;

            if (data != null && string.IsNullOrEmpty(data.Status))
            {
                var window = data.WindowFor(_config.IconMetric);
                ring = window == null ? (double?)null : window.Percent;
                weekly = data.Weekly == null ? (double?)null : data.Weekly.Percent;
                tooltip = data.Tooltip ?? Lang.T("panel.title");
                if (data.Stale) tooltip += Lang.T("panel.stale");
                // Only the active account is reported, so with several configured
                // the tooltip has to say which one it is.
                if (_accounts.Count > 1 && _active != null) tooltip = _active.Profile.Name + " " + tooltip;
            }
            else if (data != null)
            {
                tooltip = data.Status == "auth_needed"
                    ? Lang.T("status.authNeeded")
                    : Lang.T("status.unavailable");
            }
            else
            {
                tooltip = Lang.T("status.starting");
            }

            // The active account is part of the signature: two accounts can report
            // the same percentages and still need different pixels.
            var signature = ring + "|" + weekly + "|" + _config.IconMetric + "|" + _config.Monochrome + "|" +
                            (data == null ? "" : data.Status) + "|" + (_active == null ? "" : _active.Profile.Id);
            if (signature != _iconSignature)
            {
                _iconSignature = signature;
                var previous = _tray.Icon;
                _tray.Icon = _renderer.DrawStatusIcon(ring, weekly);
                if (previous != null) previous.Dispose();
            }

            if (_config.ShowTooltip)
            {
                // Windows caps a tray tooltip at 63 characters.
                if (tooltip.Length > 63) tooltip = tooltip.Substring(0, 60) + "...";
                _tray.Text = tooltip;
            }
        }

        // --- bubble ---------------------------------------------------------

        private void ShowBubble()
        {
            if (_popup.Visible || _closing) return;
            _renderer.CloseHover = false;
            // Open first, fetch after: the bubble paints from the cached reading
            // and the fresh numbers replace it while it is already on screen.
            _popup.PlaceAtTray();
            _popup.Show();
            _popup.Refresh_NoActivate();
            StartMouseWatch();
            StartUpdate();
        }

        private void HideBubble()
        {
            if (!_popup.Visible) return;
            StopMouseWatch();
            _popup.Hide();
        }

        private void ToggleBubble()
        {
            if (_popup.Visible) HideBubble();
            else ShowBubble();
        }

        // --- dismissal ------------------------------------------------------

        /// <summary>
        /// Installs a WH_MOUSE_LL hook so a click anywhere outside the bubble
        /// dismisses it. A borderless window cannot detect that on its own: it
        /// never receives the message and never holds capture.
        /// </summary>
        private void StartMouseWatch()
        {
            if (_mouseHook != IntPtr.Zero) return;
            try
            {
                _mouseHookProc = HookCallback;
                var module = NativeMethods.GetModuleHandle(null);
                _mouseHook = NativeMethods.SetWindowsHookEx(WhMouseLl, _mouseHookProc, module, 0);
            }
            catch { _mouseHook = IntPtr.Zero; }
        }

        private void StopMouseWatch()
        {
            if (_mouseHook == IntPtr.Zero) return;
            try { NativeMethods.UnhookWindowsHookEx(_mouseHook); } catch { }
            _mouseHook = IntPtr.Zero;
            _mouseHookProc = null;
        }

        private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0 && _popup != null && _popup.Visible && !_closing)
            {
                var message = wParam.ToInt32();
                var isButtonDown = message == WmLButtonDown || message == WmRButtonDown || message == WmMButtonDown;
                var isWheel = message == WmMouseWheel || message == WmMouseHWheel;

                if (isButtonDown || isWheel)
                {
                    bool outside;
                    try
                    {
                        var info = (NativeMethods.MSLLHOOKSTRUCT)Marshal.PtrToStructure(
                            lParam, typeof(NativeMethods.MSLLHOOKSTRUCT));
                        outside = IsOutside(info.pt.X, info.pt.Y);
                    }
                    catch { outside = false; }

                    if (isButtonDown)
                    {
                        // A press inside the bubble is handled by the form itself;
                        // anything else is a click away.
                        try { BeginInvokeSafe(() => { if (outside) HideBubble(); }); } catch { }
                    }
                    else if (outside)
                    {
                        try { BeginInvokeSafe(HideBubble); } catch { }
                    }
                }
            }
            return NativeMethods.CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
        }

        /// <summary>
        /// Pure predicate for "this screen point is outside the bubble", with a
        /// small slack so a click on the border does not dismiss it while the
        /// pointer is still visually inside.
        /// </summary>
        internal bool IsOutside(int x, int y)
        {
            if (_popup == null) return false;
            const int slack = 6;
            var bounds = _popup.Bounds;
            var padded = new Rectangle(bounds.Left - slack, bounds.Top - slack,
                bounds.Width + 2 * slack, bounds.Height + 2 * slack);
            return !padded.Contains(new Point(x, y));
        }

        // --- menu actions ---------------------------------------------------

        private void OpenConfig()
        {
            var path = _config.SourcePath;
            if (!File.Exists(path))
            {
                var example = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "config.example.json");
                if (File.Exists(example))
                {
                    try { File.Copy(example, path); } catch { }
                }
            }
            if (File.Exists(path)) Process.Start("notepad.exe", "\"" + path + "\"");
        }

        private static bool IsAutostartEnabled()
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, false))
                {
                    if (key == null) return false;
                    return key.GetValue(RunValueName) != null;
                }
            }
            catch { return false; }
        }

        private void ToggleAutostart()
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, true))
                {
                    if (key == null) return;
                    if (IsAutostartEnabled()) key.DeleteValue(RunValueName, false);
                    else key.SetValue(RunValueName, "\"" + Application.ExecutablePath + "\"");
                }
                _autostartItem.Checked = IsAutostartEnabled();
            }
            catch (Exception error)
            {
                MessageBox.Show(Lang.T("log.autostartFailed", error.Message),
                    Lang.T("log.errorTitle"), MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        private void Quit()
        {
            if (_closing) return;
            _closing = true;
            foreach (var account in _accounts) account.Cancel();
            StopMouseWatch();
            _tick.Stop();
            _refresh.Stop();
            _watchdog.Stop();
            try { _popup.Hide(); _popup.Dispose(); } catch { }
            try { _tray.Visible = false; _tray.Dispose(); } catch { }
            foreach (var account in _accounts) account.Dispose();
            try { _renderer.Dispose(); } catch { }

            if (_demo) Diag(Lang.T("demo.exiting", Process.GetCurrentProcess().Threads.Count));

            // Leave at once rather than only ending the message loop: an
            // HttpClient request still parked on a socket keeps a background
            // thread alive, and a tray icon is not worth waiting for that drain.
            // Every resource owner above has already been disposed.
            Environment.Exit(0);
        }
    }
}
