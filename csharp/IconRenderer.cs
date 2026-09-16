using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;

namespace CommandCodeMonitor
{
    /// <summary>
    /// Everything the tray draws: the ring icon and the limits panel.
    ///
    /// Kept apart from the form so the panel can be rendered to a bitmap for
    /// inspection without showing a window.
    /// </summary>
    internal sealed class IconRenderer : IDisposable
    {
        public const int PanelWidth = 320;
        public const int PanelHeight = 306;
        public const int CloseSize = 16;

        private readonly MonitorConfig _config;

        // Palette: readable on both light and dark taskbars.
        private readonly Color _ok = Color.FromArgb(46, 160, 67);
        private readonly Color _warn = Color.FromArgb(210, 153, 34);
        private readonly Color _critical = Color.FromArgb(209, 36, 47);
        private readonly Color _idle = Color.FromArgb(140, 143, 150);
        private readonly Color _track = Color.FromArgb(70, 128, 128, 128);
        private readonly Color _text = Color.FromArgb(235, 235, 235);
        private readonly Color _textDim = Color.FromArgb(160, 163, 168);
        private readonly Color _panel = Color.FromArgb(32, 33, 36);

        private readonly Font _fontTitle = new Font("Segoe UI", 11f, FontStyle.Bold);
        private readonly Font _fontLabel = new Font("Segoe UI", 9.5f);
        private readonly Font _fontSmall = new Font("Segoe UI", 8f);
        private readonly SolidBrush _brushText;
        private readonly SolidBrush _brushDim;

        public bool CloseHover;

        public IconRenderer(MonitorConfig config)
        {
            _config = config;
            _brushText = new SolidBrush(_text);
            _brushDim = new SolidBrush(_textDim);
        }

        public void Dispose()
        {
            _fontTitle.Dispose();
            _fontLabel.Dispose();
            _fontSmall.Dispose();
            _brushText.Dispose();
            _brushDim.Dispose();
        }

        public static Rectangle CloseRect()
        {
            return new Rectangle(PanelWidth - 16 - CloseSize, 9, CloseSize, CloseSize);
        }

        public Color PhaseColor(double? percent)
        {
            if (!percent.HasValue) return _idle;
            if (_config.Monochrome) return _idle;
            if (percent.Value >= _config.CriticalThreshold) return _critical;
            if (percent.Value >= _config.WarnThreshold) return _warn;
            return _ok;
        }

        // --- tray icon ------------------------------------------------------

        /// <summary>
        /// Draws the status icon: a ring for the configured window and a dot for
        /// the weekly one. Drawn at 64px and resampled by the shell, because a
        /// 16px master leaves too few pixels for the ring's stroke and hole.
        /// </summary>
        public Bitmap DrawStatusBitmap(double? ringPercent, double? weeklyPercent)
        {
            const int size = 64;
            var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
            using (var graphics = Graphics.FromImage(bitmap))
            {
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                graphics.Clear(Color.Transparent);

                const int inset = 6;
                const int ringWidth = 10;
                int diameter = size - 2 * inset;

                using (var trackPen = new Pen(_track, ringWidth))
                    graphics.DrawEllipse(trackPen, inset, inset, diameter, diameter);

                if (ringPercent.HasValue)
                {
                    var sweep = Math.Max(0.0, Math.Min(100.0, ringPercent.Value)) * 3.6;
                    if (sweep > 0)
                    {
                        using (var pen = new Pen(PhaseColor(ringPercent), ringWidth))
                        {
                            pen.StartCap = LineCap.Round;
                            pen.EndCap = LineCap.Round;
                            // A single-arc sweep of a full turn renders as nothing
                            // in GDI+, so a complete ring is drawn as an ellipse.
                            if (sweep >= 359.9) graphics.DrawEllipse(pen, inset, inset, diameter, diameter);
                            else graphics.DrawArc(pen, inset, inset, diameter, diameter, -90f, (float)sweep);
                        }
                    }
                }

                const int dotSize = 22;
                using (var dotBrush = new SolidBrush(PhaseColor(weeklyPercent)))
                    graphics.FillEllipse(dotBrush, size - dotSize, size - dotSize, dotSize, dotSize);
                using (var outline = new Pen(_panel, 4f))
                    graphics.DrawEllipse(outline, size - dotSize, size - dotSize, dotSize, dotSize);
            }
            return bitmap;
        }

        /// <summary>
        /// The tray icon at the size Windows actually shows. Drawing the 16px
        /// frame directly with antialiasing gives a crisper result than letting
        /// the shell resample the 64px master.
        /// </summary>
        public Icon DrawStatusIcon(double? ringPercent, double? weeklyPercent)
        {
            const int size = 16;
            var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
            using (var graphics = Graphics.FromImage(bitmap))
            {
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                graphics.Clear(Color.Transparent);

                const float inset = 1.5f;
                const float ringWidth = 2.2f;
                float diameter = size - 2 * inset;
                using (var trackPen = new Pen(_track, ringWidth))
                    graphics.DrawEllipse(trackPen, inset, inset, diameter, diameter);

                if (ringPercent.HasValue)
                {
                    var sweep = Math.Max(0.0, Math.Min(100.0, ringPercent.Value)) * 3.6;
                    if (sweep > 0)
                    {
                        using (var pen = new Pen(PhaseColor(ringPercent), ringWidth))
                        {
                            pen.StartCap = LineCap.Round;
                            pen.EndCap = LineCap.Round;
                            if (sweep >= 359.9) graphics.DrawEllipse(pen, inset, inset, diameter, diameter);
                            else graphics.DrawArc(pen, inset, inset, diameter, diameter, -90f, (float)sweep);
                        }
                    }
                }

                const float dotSize = 6.5f;
                using (var dotBrush = new SolidBrush(PhaseColor(weeklyPercent)))
                    graphics.FillEllipse(dotBrush, size - dotSize, size - dotSize, dotSize, dotSize);
            }

            var handle = bitmap.GetHicon();
            bitmap.Dispose();
            try
            {
                using (var fromHandle = Icon.FromHandle(handle))
                    return (Icon)fromHandle.Clone();
            }
            finally
            {
                NativeMethods.DestroyIcon(handle);
            }
        }

        /// <summary>The application icon, at the sizes an .ico should carry.</summary>
        public Bitmap DrawAppBitmap(int size)
        {
            var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
            using (var graphics = Graphics.FromImage(bitmap))
            {
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                graphics.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
                graphics.Clear(_panel);

                float inset = size * 0.16f;
                float ringWidth = size * 0.12f;
                float diameter = size - 2 * inset;
                using (var pen = new Pen(_ok, ringWidth))
                {
                    pen.StartCap = LineCap.Round;
                    pen.EndCap = LineCap.Round;
                    graphics.DrawArc(pen, inset, inset, diameter, diameter, -90f, 250f);
                }
                float dot = size * 0.3f;
                using (var brush = new SolidBrush(_critical))
                    graphics.FillEllipse(brush, size - dot - inset * 0.4f, size - dot - inset * 0.4f, dot, dot);
            }
            return bitmap;
        }

        // --- panel ----------------------------------------------------------

        public void DrawPanel(Graphics graphics, Rectangle bounds, LimitsResult data, bool fetching)
        {
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;

            using (var background = new SolidBrush(_panel))
                graphics.FillRectangle(background, bounds);

            bool hasError = data != null && !string.IsNullOrEmpty(data.Status);
            bool noData = data == null;

            // Header: title, plan, accent dot and close button.
            var accent = hasError || noData ? _idle : PhaseColor(data.ValueFor(_config.IconMetric));
            using (var marker = new SolidBrush(accent))
                graphics.FillEllipse(marker, 16, 18, 10, 10);

            graphics.DrawString("Command Code", _fontTitle, _brushText, 30f, 13f);

            var close = CloseRect();
            if (data != null && data.Plan != null && !string.IsNullOrEmpty(data.Plan.Id))
            {
                var planSize = graphics.MeasureString(data.Plan.Id, _fontSmall);
                var titleSize = graphics.MeasureString("Command Code", _fontTitle);
                var planX = close.Left - 10 - planSize.Width;
                if (planX > 30 + titleSize.Width + 8)
                    graphics.DrawString(data.Plan.Id, _fontSmall, _brushDim, planX, 18f);
            }

            // Always drawn, including on the error card, so the bubble can never
            // be left on screen without a way out.
            if (CloseHover)
            {
                using (var hover = new SolidBrush(Color.FromArgb(58, 235, 235, 235)))
                    graphics.FillEllipse(hover, close);
            }
            using (var crossPen = new Pen(CloseHover ? _text : _textDim, 1.6f))
            {
                const int crossInset = 5;
                graphics.DrawLine(crossPen, close.Left + crossInset, close.Top + crossInset,
                    close.Right - crossInset, close.Bottom - crossInset);
                graphics.DrawLine(crossPen, close.Right - crossInset, close.Top + crossInset,
                    close.Left + crossInset, close.Bottom - crossInset);
            }

            if (noData)
            {
                graphics.DrawString("Waiting for the first update...", _fontLabel, _brushDim, 16f, 56f);
                return;
            }

            if (hasError)
            {
                var message = string.IsNullOrEmpty(data.Message) ? "Data unavailable." : data.Message;
                var rect = new RectangleF(16, 54, PanelWidth - 32, 200);
                graphics.DrawString(message, _fontLabel, _brushText, rect);
                graphics.DrawString("Right-click the icon > Open config.json", _fontSmall, _brushDim, 16f, 240f);
                return;
            }

            DrawLimitRow(graphics, 50, "5 hours", data.FiveHour, data.FiveHourResetIn, data.FiveHourResetAt, data.FiveHourUsage);
            DrawLimitRow(graphics, 106, "Weekly", data.Weekly, data.WeeklyResetIn, data.WeeklyResetAt, data.WeeklyUsage);
            DrawLimitRow(graphics, 162, "Monthly", data.Monthly, data.MonthlyResetIn, data.MonthlyResetAt, data.MonthlyUsage);

            DrawTextRow(graphics, 218, "Tokens used", data.Tokens != null ? data.TokensValue : "unavailable");
            DrawTextRow(graphics, 242, "Runs", data.Runs != null ? data.RunsValue : "unavailable");

            if (data.Credits != null && !string.IsNullOrEmpty(data.CreditsText))
                graphics.DrawString(data.CreditsText, _fontSmall, _brushDim, 16f, 266f);

            var footerY = PanelHeight - 18f;
            graphics.DrawString("Updated at " + Format.Clock(data.FetchedAt), _fontSmall, _brushDim, 16f, footerY);

            string note = null;
            Color noteColor = _textDim;
            if (fetching) note = "refreshing...";
            else if (data.Stale) { note = "not updated"; noteColor = _warn; }
            if (note != null)
            {
                var noteSize = graphics.MeasureString(note, _fontSmall);
                using (var noteBrush = new SolidBrush(noteColor))
                    graphics.DrawString(note, _fontSmall, noteBrush, PanelWidth - 16 - noteSize.Width, footerY);
            }
        }

        private void DrawLimitRow(Graphics graphics, int y, string title, LimitWindow window,
            string resetIn, string resetAt, string usage)
        {
            const int left = 16;
            int valueRight = PanelWidth - 16;

            var percentText = window == null ? "--" : Format.Percent(window.Percent) + "";
            if (window != null) percentText = Format.Percent(window.Percent);
            var percentSize = graphics.MeasureString(percentText, _fontLabel);
            graphics.DrawString(title, _fontLabel, _brushText, left, y);
            graphics.DrawString(percentText, _fontLabel, _brushText, valueRight - percentSize.Width, y);

            if (window == null)
            {
                graphics.DrawString("window not open yet", _fontSmall, _brushDim, left, y + 18);
                return;
            }

            var barY = y + 20;
            DrawProgressBar(graphics, left, barY, PanelWidth - 32, 7, window.Percent, PhaseColor(window.Percent));

            var detail = "used " + usage;
            if (!string.IsNullOrEmpty(resetIn))
                detail += "   -   reset in " + resetIn + " (" + resetAt + ")";
            graphics.DrawString(detail, _fontSmall, _brushDim, left, barY + 11);
        }

        private void DrawTextRow(Graphics graphics, int y, string label, string value)
        {
            graphics.DrawString(label, _fontSmall, _brushDim, 16f, y + 2);
            var size = graphics.MeasureString(value, _fontLabel);
            graphics.DrawString(value, _fontLabel, _brushText, PanelWidth - 16 - size.Width, y);
        }

        private void DrawProgressBar(Graphics graphics, int x, int y, int width, int height,
            double percent, Color color)
        {
            const int radius = 3;
            using (var path = new GraphicsPath())
            {
                path.AddArc(x, y, radius * 2, radius * 2, 180, 90);
                path.AddArc(x + width - radius * 2 - 1, y, radius * 2, radius * 2, 270, 90);
                path.AddArc(x + width - radius * 2 - 1, y + height - radius * 2 - 1, radius * 2, radius * 2, 0, 90);
                path.AddArc(x, y + height - radius * 2 - 1, radius * 2, radius * 2, 90, 90);
                path.CloseFigure();

                using (var trackBrush = new SolidBrush(_track))
                    graphics.FillPath(trackBrush, path);

                var value = Math.Max(0.0, Math.Min(100.0, percent));
                var fillWidth = (int)Math.Round(width * value / 100.0);
                if (fillWidth < 2 && value > 0) fillWidth = 2;
                if (fillWidth <= 0) return;

                // Clip to the rounded track so the fill inherits the same shape.
                var previous = graphics.Clip;
                graphics.SetClip(path);
                using (var fillBrush = new SolidBrush(color))
                    graphics.FillRectangle(fillBrush, x, y, fillWidth, height);
                graphics.Clip = previous;
            }
        }
    }

    /// <summary>Win32 entry points used by this program.</summary>
    internal static class NativeMethods
    {
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool DestroyIcon(IntPtr handle);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool SetProcessDPIAware();

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        public struct POINT
        {
            public int X;
            public int Y;
        }

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        public struct MSLLHOOKSTRUCT
        {
            public POINT pt;
            public uint mouseData;
            public uint flags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        public delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

        [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);

        [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
        public static extern bool UnhookWindowsHookEx(IntPtr hhk);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

        [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        public static extern IntPtr GetModuleHandle(string lpModuleName);
    }
}
