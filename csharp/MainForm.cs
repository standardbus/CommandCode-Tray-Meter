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
        private readonly LimitsClient _client;
        private readonly IconRenderer _renderer;
        private readonly NotifyIcon _tray;
        private readonly PopupForm _popup;
        private readonly ToolStripMenuItem _autostartItem;
        private readonly System.Windows.Forms.Timer _tick;
        private readonly System.Windows.Forms.Timer _refresh;
        private readonly System.Windows.Forms.Timer _watchdog;

        private LimitsResult _data;
        private long _revision;
        private bool _fetching;
        private bool _closing;
        private string _iconSignature = "";
        private IntPtr _mouseHook = IntPtr.Zero;
        private NativeMethods.HookProc _mouseHookProc;
        private CancellationTokenSource _pending;
        private bool _demo;

        /// <summary>
        /// In demo mode the bubble opens by itself and the program exits after a
        /// few seconds. Used to prove the real window paints and dismisses,
        /// which rendering to a bitmap cannot show.
        /// </summary>
        public void EnableDemo(int showAfterMs, int quitAfterMs)
        {
            _demo = true;
            Diag("demo: avvio, bolla tra " + showAfterMs + "ms, uscita tra " + quitAfterMs + "ms");
            var show = new System.Windows.Forms.Timer { Interval = showAfterMs };
            show.Tick += (sender, args) =>
            {
                show.Stop();
                show.Dispose();
                ShowBubble();
                Diag("demo: " + DescribeState());
            };
            show.Start();

            var quit = new System.Windows.Forms.Timer { Interval = quitAfterMs };
            quit.Tick += (sender, args) =>
            {
                quit.Stop();
                quit.Dispose();
                Diag("demo: chiusura richiesta - " + DescribeState());
                Quit();
                Diag("demo: Quit() ritornato");
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
            var status = _data == null ? "(nessun dato)" : (_data.Status ?? "ok");
            return "visibile=" + _popup.Visible +
                   " bounds=" + _popup.Bounds +
                   " stato=" + status +
                   " 5h=" + (_data == null ? "--" : _data.FiveHourPercent) +
                   " 30g=" + (_data == null ? "--" : _data.MonthlyPercent);
        }

        public MainForm(MonitorConfig config)
        {
            _config = config;
            _client = new LimitsClient(config);
            _renderer = new IconRenderer(config);
            _popup = new PopupForm(_renderer, () => _data, () => _fetching);
            _popup.CloseRequested += (sender, args) => HideBubble();

            var menu = new ContextMenuStrip();
            menu.Items.Add("Mostra limiti", null, (sender, args) => ShowBubble());
            menu.Items.Add("Aggiorna ora", null, (sender, args) => StartUpdate());
            menu.Items.Add("Apri config.json (" + Path.GetFileName(config.SourcePath) + ")", null,
                (sender, args) => OpenConfig());
            menu.Items.Add("Impostazioni Command Code (Studio)", null,
                (sender, args) => Process.Start("https://commandcode.ai/studio/provider"));
            _autostartItem = new ToolStripMenuItem("Avvia con Windows", null, (sender, args) => ToggleAutostart());
            _autostartItem.Checked = IsAutostartEnabled();
            menu.Items.Add(_autostartItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Esci", null, (sender, args) => Quit());

            _tray = new NotifyIcon
            {
                Icon = _renderer.DrawStatusIcon(null, null),
                Text = "Command Code: avvio in corso",
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
                if (_data != null && _data.HasData) { _watchdog.Stop(); return; }
                if (!_fetching) StartUpdate();
            };

            _tick.Start();
            _refresh.Start();
            _watchdog.Start();
            StartUpdate();
        }

        // --- polling --------------------------------------------------------

        /// <summary>
        /// Kick a fetch off. Never blocks the UI thread: the fast path is folded
        /// in when it lands and the slow tail replaces it later.
        /// </summary>
        private void StartUpdate()
        {
            if (_fetching || _closing) return;
            _fetching = true;
            _pending = new CancellationTokenSource();
            var token = _pending.Token;

            Task.Run(async () =>
            {
                try
                {
                    var result = await _client.FetchAsync(partial =>
                    {
                        BeginInvokeSafe(() => ApplyResult(partial, true));
                    }, token).ConfigureAwait(false);

                    if (token.IsCancellationRequested) return;
                    BeginInvokeSafe(() => ApplyResult(result, false));
                }
                catch (Exception error)
                {
                    BeginInvokeSafe(() => ApplyFailure(error));
                }
            });
        }

        /// <summary>
        /// Publish a reading. A failed fetch must not blank the numbers the user
        /// is looking at, so the previous ones are kept and flagged stale.
        /// </summary>
        private void ApplyResult(LimitsResult result, bool partial)
        {
            if (_closing) return;
            _revision += 1;
            result.Revision = _revision;

            if (!string.IsNullOrEmpty(result.Status))
            {
                if (_data != null && string.IsNullOrEmpty(_data.Status))
                {
                    _data.Stale = true;
                    _data.StaleReason = result.Message;
                }
                else
                {
                    _data = result;
                }
            }
            else if (partial && _data != null)
            {
                // Keep the slow-tail fields: a partial result means "these windows
                // are newer", not "forget the rest".
                result.Credits = _data.Credits;
                result.CreditsText = _data.CreditsText;
                result.Tokens = _data.Tokens;
                result.TokensValue = _data.TokensValue;
                result.Runs = _data.Runs;
                result.RunsValue = _data.RunsValue;
                result.Monthly = _data.Monthly;
                result.MonthlyPercent = _data.MonthlyPercent;
                result.MonthlyUsage = _data.MonthlyUsage;
                result.MonthlyResetIn = _data.MonthlyResetIn;
                result.MonthlyResetAt = _data.MonthlyResetAt;
                result.Plan = _data.Plan;
                result.Tooltip = _data.Tooltip;
                _data = result;
            }
            else
            {
                _data = result;
            }

            if (!partial)
            {
                _fetching = false;
                DisposePending();
            }

            UpdateTray();
            if (_popup.Visible) _popup.Refresh_NoActivate();
        }

        private void ApplyFailure(Exception error)
        {
            _fetching = false;
            DisposePending();
            if (_data != null)
            {
                _data.Stale = true;
                _data.StaleReason = error.Message;
            }
            else
            {
                _data = new LimitsResult
                {
                    Status = "network_error",
                    Message = "Errore imprevisto: " + error.Message,
                    FetchedAt = DateTime.UtcNow,
                }.BuildDisplay(DateTime.UtcNow);
            }
            UpdateTray();
            if (_popup.Visible) _popup.Refresh_NoActivate();
        }

        private void DisposePending()
        {
            if (_pending == null) return;
            try { _pending.Dispose(); } catch { }
            _pending = null;
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

        private void UpdateTray()
        {
            var data = _data;
            double? ring = null;
            double? weekly = null;
            string tooltip;

            if (data != null && string.IsNullOrEmpty(data.Status))
            {
                var window = data.WindowFor(_config.IconMetric);
                ring = window == null ? (double?)null : window.Percent;
                weekly = data.Weekly == null ? (double?)null : data.Weekly.Percent;
                tooltip = data.Tooltip ?? "Command Code";
                if (data.Stale) tooltip += "  (dati non aggiornati)";
            }
            else if (data != null)
            {
                tooltip = data.Status == "auth_needed"
                    ? "Command Code: accesso richiesto"
                    : "Command Code: dati non disponibili";
            }
            else
            {
                tooltip = "Command Code: avvio in corso";
            }

            var signature = ring + "|" + weekly + "|" + _config.IconMetric + "|" + _config.Monochrome + "|" +
                            (data == null ? "" : data.Status);
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
                MessageBox.Show("Impossibile modificare l'avvio automatico:\n" + error.Message,
                    "CommandCode Monitor", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        private void Quit()
        {
            if (_closing) return;
            _closing = true;
            try { if (_pending != null) _pending.Cancel(); } catch { }
            StopMouseWatch();
            _tick.Stop();
            _refresh.Stop();
            _watchdog.Stop();
            try { _popup.Hide(); _popup.Dispose(); } catch { }
            try { _tray.Visible = false; _tray.Dispose(); } catch { }
            try { _client.Dispose(); } catch { }
            try { _renderer.Dispose(); } catch { }

            if (_demo) Diag("demo: uscita, thread attivi = " + Process.GetCurrentProcess().Threads.Count);

            // Leave at once rather than only ending the message loop: an
            // HttpClient request still parked on a socket keeps a background
            // thread alive, and a tray icon is not worth waiting for that drain.
            // Every resource owner above has already been disposed.
            Environment.Exit(0);
        }
    }
}
