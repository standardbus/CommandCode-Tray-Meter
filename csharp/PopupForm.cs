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

        private readonly Func<PanelModel> _model;
        private readonly System.ComponentModel.Container _components = new System.ComponentModel.Container();
        private readonly ToolTip _tips;
        private IconRenderer _renderer;
        /// <summary>Accounts in the model as last drawn, for the hit tests.</summary>
        private int _accounts;
        private int _tabHover = -1;
        private bool _tipShown;

        public event EventHandler CloseRequested;

        /// <summary>Raised with the index of the tab the user clicked.</summary>
        public Action<int> TabSelected;

        public PopupForm(IconRenderer renderer, Func<PanelModel> model)
        {
            _renderer = renderer;
            _model = model;
            _tips = new ToolTip(_components);

            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            TopMost = true;
            DoubleBuffered = true;
            BackColor = Color.FromArgb(32, 33, 36);
            // The panel grows by the tab strip when more than one account is
            // configured, so the window is sized from the model, not a constant.
            _accounts = Count();
            Size = new Size(IconRenderer.PanelWidth, IconRenderer.HeightFor(_accounts));
            KeyPreview = true;
        }

        /// <summary>
        /// The renderer that paints this bubble. The main form replaces it when the
        /// language is changed from the settings window: the font family - and with
        /// Chinese the whole face - is chosen when a renderer is built.
        /// </summary>
        public IconRenderer Renderer
        {
            get { return _renderer; }
            set
            {
                _renderer = value;
                if (Visible) Invalidate();
            }
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
            var model = Built();
            _renderer.DrawPanel(e.Graphics, new Rectangle(0, 0, Width, Height), model);
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            var tab = TabAt(e.Location);
            var hover = IconRenderer.CloseRect(Strip()).Contains(e.Location);

            var changed = false;
            if (hover != _renderer.CloseHover)
            {
                _renderer.CloseHover = hover;
                changed = true;
            }
            if (tab != _tabHover)
            {
                _tabHover = tab;
                _renderer.TabHover = tab;
                changed = true;
            }

            // One tooltip for the whole strip: it says what a tab does, not which
            // account it belongs to - the tab already carries the name.
            var wanted = tab >= 0;
            if (wanted != _tipShown)
            {
                _tipShown = wanted;
                _tips.SetToolTip(this, wanted ? Lang.T("panel.tabTip") : "");
            }

            if (changed) Invalidate();
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            var changed = false;
            if (_renderer.CloseHover) { _renderer.CloseHover = false; changed = true; }
            if (_tabHover >= 0)
            {
                _tabHover = -1;
                _renderer.TabHover = -1;
                changed = true;
            }
            if (_tipShown)
            {
                _tipShown = false;
                _tips.SetToolTip(this, "");
            }
            if (changed) Invalidate();
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Left) return;

            var tab = TabAt(e.Location);
            if (tab >= 0)
            {
                var handler = TabSelected;
                if (handler != null) handler(tab);
                return;
            }

            if (IconRenderer.CloseRect(Strip()).Contains(e.Location)) RequestClose();
        }

        /// <summary>The tab under a point, or -1: the same rectangles that are drawn.</summary>
        private int TabAt(Point location)
        {
            return IconRenderer.TabAt(location, _accounts);
        }

        /// <summary>How far the figures below the strip are shifted down.</summary>
        private int Strip()
        {
            return IconRenderer.StripHeightFor(_accounts);
        }

        private int Count()
        {
            var model = _model();
            return model == null || model.Accounts == null ? 0 : model.Accounts.Count;
        }

        /// <summary>
        /// The model to draw, remembering how many accounts it carries so the hit
        /// tests and the size keep using the same number between two paints.
        /// </summary>
        private PanelModel Built()
        {
            var model = _model();
            _accounts = model == null || model.Accounts == null ? 0 : model.Accounts.Count;
            return model;
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
            Built();
            var height = IconRenderer.HeightFor(_accounts);
            if (Height != height) Size = new Size(IconRenderer.PanelWidth, height);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) _components.Dispose();
            base.Dispose(disposing);
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
