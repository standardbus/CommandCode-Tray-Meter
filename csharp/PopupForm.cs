using System;
using System.Drawing;
using System.Windows.Forms;

namespace CommandCodeMonitor
{
    /// <summary>
    /// The limits bubble.
    ///
    /// A borderless, non-activating window drawn entirely by hand rather than a
    /// ContextMenuStrip: a menu cannot hold a fixed custom size reliably and its
    /// owner-drawn item reports a tiny preferred size, which clipped the panel to
    /// a narrow sliver. A plain form also keeps the bubble out of the way of the
    /// taskbar's own dismissal rules.
    ///
    /// Dismissal is owned by MainForm (outside click, Escape, close button), so
    /// this class only paints and reports hits.
    /// </summary>
    internal sealed class PopupForm : Form
    {
        private const int WsExNoActivate = 0x08000000;
        private const int WsExToolWindow = 0x00000080;

        private readonly IconRenderer _renderer;
        private readonly Func<PanelModel> _model;

        public event EventHandler CloseRequested;

        public PopupForm(IconRenderer renderer, Func<PanelModel> model)
        {
            _renderer = renderer;
            _model = model;

            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            TopMost = true;
            DoubleBuffered = true;
            BackColor = Color.FromArgb(32, 33, 36);
            // The Accounts section needs one row per account, so the window is sized
            // from the model rather than from a constant.
            Size = new Size(IconRenderer.PanelWidth, IconRenderer.HeightFor(model().Accounts.Count));
            KeyPreview = true;
        }

        protected override bool ShowWithoutActivation
        {
            // Taking focus would steal it from whatever the user is typing in.
            get { return true; }
        }

        protected override CreateParams CreateParams
        {
            get
            {
                var parameters = base.CreateParams;
                parameters.ExStyle |= WsExNoActivate | WsExToolWindow;
                return parameters;
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            _renderer.DrawPanel(e.Graphics, new Rectangle(0, 0, Width, Height), _model());
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            var hover = IconRenderer.CloseRect().Contains(e.Location);
            if (hover != _renderer.CloseHover)
            {
                _renderer.CloseHover = hover;
                Invalidate();
            }
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            if (_renderer.CloseHover)
            {
                _renderer.CloseHover = false;
                Invalidate();
            }
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            if (IconRenderer.CloseRect().Contains(e.Location)) RequestClose();
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape) RequestClose();
        }

        /// <summary>Raise the close request; the main form performs the dismissal.</summary>
        public void RequestClose()
        {
            var handler = CloseRequested;
            if (handler != null) handler(this, EventArgs.Empty);
        }

        /// <summary>
        /// Place the bubble against the notification-area corner rather than
        /// under the cursor, so it never covers the tray icon itself.
        /// </summary>
        public void PlaceAtTray()
        {
            // Sized before it is placed: a taller panel anchored to the tray corner
            // has to be measured while there is still room for it.
            SyncSize();

            var screen = Screen.PrimaryScreen;
            var working = screen.WorkingArea;
            var bounds = screen.Bounds;
            const int margin = 8;

            var roomBelow = bounds.Bottom - working.Bottom;
            var roomAbove = working.Top - bounds.Top;

            var x = working.Right - Width - margin;
            if (x < working.Left) x = working.Left;

            int y;
            if (roomBelow >= roomAbove) y = working.Bottom - Height - margin;
            else y = working.Top + margin;

            if (y < working.Top) y = working.Top;
            if (y + Height > working.Bottom) y = working.Bottom - Height;

            Location = new Point(x, y);
        }

        /// <summary>
        /// Match the window to the number of accounts it has to show. Called before
        /// every show, so the panel can never be taller or shorter than its model.
        /// </summary>
        public void SyncSize()
        {
            var height = IconRenderer.HeightFor(_model().Accounts.Count);
            if (Height != height) Size = new Size(IconRenderer.PanelWidth, height);
        }

        /// <summary>Redraw without stealing focus and without a flicker.</summary>
        public void Refresh_NoActivate()
        {
            if (!Visible) return;
            Invalidate();
            Update();
        }
    }
}
