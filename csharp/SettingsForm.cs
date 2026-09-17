using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace CommandCodeMonitor
{
    /// <summary>
    /// The Settings window: the accounts, the language, the polling interval, the
    /// thresholds, the ring metric and the two switches, all in one place.
    ///
    /// It replaces an external editor. The old menu entry opened config.json in
    /// notepad, which fails on a machine without a configured editor, and it could
    /// not know the schema anyway: this window edits the settings the program
    /// actually reads, validates them first and writes the file itself.
    ///
    /// Built in code, like the rest of the program: no designer file, no resource
    /// stream, nothing that a build with csc cannot reproduce from source.
    ///
    /// The keys of every account are masked with `UseSystemPasswordChar`, which
    /// hides the characters on screen while the text box keeps the real text, so
    /// saving can never write a row of dots over a key.
    /// </summary>
    internal sealed class SettingsForm : Form
    {
        /// <summary>Height of one account row, including the gap under it.</summary>
        private const int RowStep = 58;

        private readonly string _path;
        private readonly MonitorConfig _config;
        private readonly List<Row> _rows = new List<Row>();
        private readonly System.ComponentModel.Container _components = new System.ComponentModel.Container();
        private readonly ToolTip _tips;
        private readonly Panel _host;
        private readonly GroupBox _accounts;
        private readonly GroupBox _options;
        private readonly Button _add;
        private readonly Label _status;
        private readonly Button _save;
        private readonly Button _close;
        // Assigned by BuildOptions, called from the constructor.
        private ComboBox _language;
        private ComboBox _ring;
        private NumericUpDown _refresh;
        private NumericUpDown _warn;
        private NumericUpDown _critical;
        private CheckBox _monochrome;
        private CheckBox _tooltip;
        private readonly Font _font;

        private bool _saved;

        /// <summary>The `language` value each selector position writes.</summary>
        private static readonly string[] Languages = { "auto", "en", "it", "zh" };

        /// <summary>The `ui.iconMetric` value each selector position writes.</summary>
        private static readonly string[] Metrics = { "fiveHour", "weekly", "monthly" };

        private static readonly Color OkColor = Color.FromArgb(46, 160, 67);
        private static readonly Color ProblemColor = Color.FromArgb(209, 36, 47);

        /// <summary>True once a save has succeeded, so the caller reloads.</summary>
        public bool Saved { get { return _saved; } }

        /// <summary>One account row: its controls, and where the account came from.</summary>
        private sealed class Row
        {
            public Panel Panel;
            public TextBox Name;
            public TextBox Key;
            public Button Reveal;
            public Label Kept;
            public Button Remove;
            /// <summary>The id in config.json, or "" for a row just added.</summary>
            public string Id = "";
            /// <summary>The name the row showed when the window opened.</summary>
            public string OriginalName = "";
            /// <summary>The environment variable this account falls back to.</summary>
            public string Env = "";
        }

        public SettingsForm(string path, MonitorConfig config)
        {
            _path = path;
            _config = config;
            _tips = new ToolTip(_components);

            // Chinese needs a CJK-capable face even on an English system, and the
            // panel's font resolution is the one place that knows which.
            _font = new Font(IconRenderer.ResolveFontFamily(), 9f);
            Font = _font;

            Text = Lang.T("settings.title");
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            ShowInTaskbar = true;
            ClientSize = new Size(560, 620);

            var layout = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 1,
                RowCount = 2,
            };
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 52f));
            Controls.Add(layout);

            _host = new Panel { Dock = DockStyle.Fill, AutoScroll = true };
            layout.Controls.Add(_host, 0, 0);

            var bottom = new Panel { Dock = DockStyle.Fill };
            layout.Controls.Add(bottom, 0, 1);

            var file = new Label
            {
                Text = Lang.T("settings.file", path),
                Location = new Point(12, 10),
                Size = new Size(516, 18),
                AutoEllipsis = true,
                ForeColor = SystemColors.GrayText,
            };
            _host.Controls.Add(file);

            _accounts = new GroupBox
            {
                Text = Lang.T("settings.accounts"),
                Location = new Point(12, 36),
                Size = new Size(516, 120),
            };
            _host.Controls.Add(_accounts);

            var hint = new Label
            {
                Text = Lang.T("settings.accountsHint"),
                Location = new Point(10, 20),
                Size = new Size(496, 18),
            };
            _accounts.Controls.Add(hint);

            _add = new Button
            {
                Text = Lang.T("settings.add"),
                Size = new Size(34, 26),
                Location = new Point(10, 44),
            };
            _add.Click += (sender, args) => Guarded(() => AppendRow(null));
            _tips.SetToolTip(_add, Lang.T("settings.addTip"));
            _accounts.Controls.Add(_add);

            _options = new GroupBox
            {
                Location = new Point(12, 166),
                Size = new Size(516, 244),
            };
            _host.Controls.Add(_options);
            BuildOptions();

            _status = new Label
            {
                Location = new Point(12, 18),
                Size = new Size(330, 20),
                AutoEllipsis = true,
            };
            bottom.Controls.Add(_status);

            _save = new Button
            {
                Text = Lang.T("settings.save"),
                Location = new Point(360, 12),
                Size = new Size(90, 28),
            };
            _save.Click += (sender, args) => Save();
            bottom.Controls.Add(_save);

            _close = new Button
            {
                Text = Lang.T("settings.cancel"),
                Location = new Point(456, 12),
                Size = new Size(92, 28),
            };
            _close.Click += (sender, args) => Close();
            bottom.Controls.Add(_close);

            AcceptButton = _save;
            CancelButton = _close;

            var profiles = LoadProfiles();
            foreach (var profile in profiles)
                AppendRow(new AccountEdit
                {
                    Id = profile.Id,
                    OriginalName = profile.Name,
                    Name = profile.Name,
                    ApiKey = profile.ApiKey,
                    ApiKeyEnv = profile.ApiKeyEnv,
                });

            LoadOptions();
            LayoutContent();
        }

        /// <summary>The accounts as the window should show them.</summary>
        private List<Profile> LoadProfiles()
        {
            try
            {
                return Profiles.Resolve(_config);
            }
            catch (ConfigException)
            {
                // A broken `profiles` list is exactly what the window is opened to
                // fix, so it shows what is in the file rather than refusing to open.
                var rows = new List<Profile>();
                if (_config.Profiles != null)
                {
                    foreach (var raw in _config.Profiles)
                    {
                        var entry = raw as IDictionary<string, object>;
                        if (entry == null) continue;
                        rows.Add(new Profile
                        {
                            Id = (Json.Text(Json.Get(entry, "id")) ?? "").Trim().ToLowerInvariant(),
                            Name = (Json.Text(Json.Get(entry, "name")) ?? "").Trim(),
                            ApiKey = (Json.Text(Json.Get(entry, "apiKey")) ?? "").Trim(),
                            ApiKeyEnv = (Json.Text(Json.Get(entry, "apiKeyEnv")) ?? "").Trim(),
                        });
                    }
                }
                if (rows.Count == 0) rows.Add(new Profile());
                return rows;
            }
        }

        // --- accounts -------------------------------------------------------

        /// <summary>
        /// Add one row. The "+" button is the whole account list editor: the user
        /// asked for a single field with a "+" that adds another.
        /// </summary>
        private void AppendRow(AccountEdit seed)
        {
            var row = new Row();
            var panel = new Panel { Location = new Point(10, 44), Size = new Size(496, 52) };
            row.Panel = panel;

            panel.Controls.Add(new Label
            {
                Text = Lang.T("settings.name"),
                Location = new Point(2, 5),
                Size = new Size(56, 18),
            });

            row.Name = new TextBox
            {
                Location = new Point(60, 2),
                Size = new Size(176, 24),
                Text = seed == null ? "" : seed.Name,
            };
            panel.Controls.Add(row.Name);

            panel.Controls.Add(new Label
            {
                Text = Lang.T("settings.apiKey"),
                Location = new Point(2, 33),
                Size = new Size(56, 18),
            });

            row.Key = new TextBox
            {
                Location = new Point(60, 30),
                Size = new Size(176, 24),
                Text = seed == null ? "" : seed.ApiKey,
                // Masking is visual only: the box holds the real key, so saving
                // writes the key and never the dots.
                UseSystemPasswordChar = true,
            };
            panel.Controls.Add(row.Key);

            row.Reveal = new Button
            {
                Text = Lang.T("settings.show"),
                Location = new Point(242, 29),
                Size = new Size(52, 26),
            };
            row.Reveal.Click += (sender, args) => Guarded(() => ToggleReveal(row));
            panel.Controls.Add(row.Reveal);

            row.Kept = new Label
            {
                Location = new Point(300, 33),
                Size = new Size(158, 18),
                ForeColor = SystemColors.GrayText,
                AutoEllipsis = true,
            };
            panel.Controls.Add(row.Kept);

            row.Remove = new Button
            {
                Text = Lang.T("settings.remove"),
                Location = new Point(462, 2),
                Size = new Size(30, 26),
            };
            row.Remove.Click += (sender, args) => Guarded(() => RemoveRow(row));
            _tips.SetToolTip(row.Remove, Lang.T("settings.removeTip"));
            panel.Controls.Add(row.Remove);

            row.Id = seed == null ? "" : seed.Id;
            row.OriginalName = seed == null ? "" : seed.OriginalName;
            row.Env = seed == null ? "" : (seed.ApiKeyEnv ?? "").Trim();

            // The hint tracks what the box holds: an environment variable is kept
            // only while the box is empty.
            row.Key.TextChanged += (sender, args) => Guarded(() => RefreshKept(row));

            _rows.Add(row);
            _accounts.Controls.Add(panel);
            RefreshKept(row);
            LayoutContent();

            if (seed == null)
            {
                // A new row is scrolled into view and ready to type in.
                _host.ScrollControlIntoView(panel);
                row.Name.Focus();
            }
        }

        private void ToggleReveal(Row row)
        {
            var masked = !row.Key.UseSystemPasswordChar;
            row.Key.UseSystemPasswordChar = masked;
            row.Reveal.Text = masked ? Lang.T("settings.show") : Lang.T("settings.hide");
        }

        /// <summary>
        /// Remove a row. The last row is never removed, only emptied: a window with
        /// no account at all would have nothing to save.
        /// </summary>
        private void RemoveRow(Row row)
        {
            if (_rows.Count <= 1)
            {
                row.Name.Text = "";
                row.Key.Text = "";
                row.Id = "";
                row.OriginalName = "";
                row.Env = "";
                RefreshKept(row);
                row.Name.Focus();
                return;
            }

            _rows.Remove(row);
            _accounts.Controls.Remove(row.Panel);
            row.Panel.Dispose();
            LayoutContent();
        }

        private void RefreshKept(Row row)
        {
            var keeps = row.Env.Length > 0 && row.Key.Text.Trim().Length == 0;
            row.Kept.Visible = keeps;
            row.Kept.Text = keeps ? Lang.T("settings.keyKept", row.Env) : "";
        }

        /// <summary>Place every row, then the "+" button, then the rest below.</summary>
        private void LayoutContent()
        {
            for (var index = 0; index < _rows.Count; index++)
                _rows[index].Panel.Location = new Point(10, 44 + index * RowStep);

            var addY = 44 + _rows.Count * RowStep;
            _add.Location = new Point(10, addY);
            _accounts.Height = addY + _add.Height + 14;
            _options.Location = new Point(12, _accounts.Bottom + 10);
            _host.AutoScrollMinSize = new Size(0, _options.Bottom + 12);
        }

        // --- options --------------------------------------------------------

        private void BuildOptions()
        {
            var languageLabel = new Label
            {
                Text = Lang.T("settings.language"),
                Location = new Point(12, 28),
                Size = new Size(150, 18),
            };
            _options.Controls.Add(languageLabel);

            _language = new ComboBox
            {
                Location = new Point(170, 24),
                Size = new Size(200, 24),
                DropDownStyle = ComboBoxStyle.DropDownList,
            };
            _language.Items.AddRange(new object[]
            {
                Lang.T("settings.langAuto"),
                Lang.T("settings.langEn"),
                Lang.T("settings.langIt"),
                Lang.T("settings.langZh"),
            });
            _options.Controls.Add(_language);

            _refresh = Numeric("settings.refresh", 58, 15, 86400);
            _warn = Numeric("settings.warn", 88, 0, 100);
            _critical = Numeric("settings.critical", 118, 0, 100);

            var ringLabel = new Label
            {
                Text = Lang.T("settings.ringShows"),
                Location = new Point(12, 148),
                Size = new Size(150, 18),
            };
            _options.Controls.Add(ringLabel);

            _ring = new ComboBox
            {
                Location = new Point(170, 144),
                Size = new Size(200, 24),
                DropDownStyle = ComboBoxStyle.DropDownList,
            };
            _ring.Items.AddRange(new object[]
            {
                Lang.T("panel.fiveHour"),
                Lang.T("panel.weekly"),
                Lang.T("panel.monthly"),
            });
            _options.Controls.Add(_ring);

            _monochrome = new CheckBox
            {
                Text = Lang.T("settings.monochrome"),
                Location = new Point(12, 180),
                Size = new Size(400, 22),
            };
            _options.Controls.Add(_monochrome);

            _tooltip = new CheckBox
            {
                Text = Lang.T("settings.tooltip"),
                Location = new Point(12, 206),
                Size = new Size(400, 22),
            };
            _options.Controls.Add(_tooltip);
        }

        /// <summary>A captioned numeric field, on the grid the other options use.</summary>
        private NumericUpDown Numeric(string labelKey, int y, int minimum, int maximum)
        {
            var label = new Label
            {
                Text = Lang.T(labelKey),
                Location = new Point(12, y + 4),
                Size = new Size(150, 18),
            };
            _options.Controls.Add(label);

            var box = new NumericUpDown
            {
                Location = new Point(170, y),
                Size = new Size(90, 24),
                Minimum = minimum,
                Maximum = maximum,
                DecimalPlaces = 0,
            };
            _options.Controls.Add(box);
            return box;
        }

        private void LoadOptions()
        {
            var language = (_config.Language ?? "").Trim().ToLowerInvariant();
            var languageIndex = Array.IndexOf(Languages, language);
            // No `language` in the file means English, which is what the program
            // does; `auto` has to be written there to follow Windows.
            _language.SelectedIndex = languageIndex < 0 ? Array.IndexOf(Languages, "en") : languageIndex;

            var metric = Array.IndexOf(Metrics, (_config.IconMetric ?? "").Trim());
            _ring.SelectedIndex = metric < 0 ? 0 : metric;

            SetValue(_refresh, Clamp(_config.RefreshSeconds, 15, 86400));
            SetValue(_warn, Round(_config.WarnThreshold));
            SetValue(_critical, Round(_config.CriticalThreshold));
            _monochrome.Checked = _config.Monochrome;
            _tooltip.Checked = _config.ShowTooltip;
        }

        /// <summary>
        /// Put a value into a spinner, inside the spinner's own range.
        ///
        /// Assigning below `Minimum` is an exception - "'0' is not a valid value
        /// for 'Value'. 'Value' should be between 'Minimum' and 'Maximum'" - and an
        /// exception raised while the window is being built is nothing the user can
        /// act on. The bounds are read back from the control rather than repeated
        /// from the code that created it, so the two can never disagree.
        /// </summary>
        private static void SetValue(NumericUpDown spinner, decimal value)
        {
            if (value < spinner.Minimum) value = spinner.Minimum;
            if (value > spinner.Maximum) value = spinner.Maximum;
            spinner.Value = value;
        }

        private static decimal Round(double value)
        {
            if (double.IsNaN(value)) return 0;
            var rounded = Math.Round(value, MidpointRounding.AwayFromZero);
            if (rounded < 0) return 0;
            if (rounded > 100) return 100;
            return (decimal)rounded;
        }

        private static decimal Clamp(int value, int minimum, int maximum)
        {
            if (value < minimum) return minimum;
            if (value > maximum) return maximum;
            return value;
        }

        // --- saving ---------------------------------------------------------

        /// <summary>
        /// The Save button.
        ///
        /// Every failure - validation, an unwritable file, a control that cannot
        /// report its value - ends as a message inside the window. Nothing here may
        /// throw: an exception would leave the event handler, become the WinForms
        /// unhandled-exception dialog, and take the settings window and the tray
        /// behind it with it.
        /// </summary>
        private void Save()
        {
            SaveNow();
        }

        /// <summary>
        /// Perform the save and return the message the window now shows.
        ///
        /// Internal so the self-test can drive it without a mouse, and prove that a
        /// save that cannot write reports itself instead of escaping.
        /// </summary>
        internal string SaveNow()
        {
            try
            {
                var edit = Collect();

                var problem = ConfigEditor.Validate(edit.Accounts);
                if (problem != null)
                {
                    FocusProblem();
                    return ShowStatus(problem, false);
                }

                ConfigEditor.Save(_path, edit);

                _saved = true;
                _close.Text = Lang.T("settings.close");
                // The ids the file now carries may be new (a rename derives one):
                // adopt them so saving twice writes the same file.
                var ids = ConfigEditor.DeriveIds(edit.Accounts);
                for (var index = 0; index < _rows.Count; index++)
                {
                    _rows[index].Id = ids[index];
                    _rows[index].OriginalName = edit.Accounts[index].Name;
                }
                return ShowStatus(Lang.T("settings.saved"), true);
            }
            catch (Exception error)
            {
                Diagnostics.Log("settings save: " + error);
                return ShowStatus(Lang.T("settings.saveFailed", error.Message), false);
            }
        }

        /// <summary>
        /// Run a control's handler. A failure becomes a message in the window - the
        /// one place the user is already looking - rather than an exception on the
        /// UI thread.
        /// </summary>
        private void Guarded(Action action)
        {
            try
            {
                action();
            }
            catch (Exception error)
            {
                Diagnostics.Log("settings control: " + error);
                ShowStatus(Lang.T("error.unexpected", error.Message), false);
            }
        }

        /// <summary>
        /// What the controls currently say.
        ///
        /// Internal so the self-test can read a window back without showing it: the
        /// mapping from the file to the controls is the part worth checking offline.
        /// </summary>
        internal ConfigEdit Current()
        {
            return Collect();
        }

        /// <summary>What the controls currently say.</summary>
        private ConfigEdit Collect()
        {
            var edit = new ConfigEdit();
            foreach (var row in _rows)
            {
                edit.Accounts.Add(new AccountEdit
                {
                    Id = row.Id,
                    OriginalName = row.OriginalName,
                    Name = row.Name.Text.Trim(),
                    ApiKey = row.Key.Text.Trim(),
                    ApiKeyEnv = row.Env,
                });
            }

            edit.Language = Languages[_language.SelectedIndex < 0 ? 1 : _language.SelectedIndex];
            edit.RefreshSeconds = (int)_refresh.Value;
            edit.Warn = (double)_warn.Value;
            edit.Critical = (double)_critical.Value;
            edit.IconMetric = Metrics[_ring.SelectedIndex < 0 ? 0 : _ring.SelectedIndex];
            edit.Monochrome = _monochrome.Checked;
            edit.ShowTooltip = _tooltip.Checked;
            edit.ActiveProfile = ActiveProfileAfterRename(edit.Accounts);
            return edit;
        }

        /// <summary>
        /// `activeProfile` if this save would otherwise strand it, else null.
        ///
        /// Only a rename can strand it: the account it names keeps its id unless its
        /// name - and therefore the id derived from it - changed, and then the file
        /// would name an account that no longer exists.
        /// </summary>
        private string ActiveProfileAfterRename(IList<AccountEdit> rows)
        {
            var active = (_config.ActiveProfile ?? "").Trim().ToLowerInvariant();
            if (active.Length == 0) return null;

            var usesProfiles = (_config.Profiles != null && _config.Profiles.Count > 0) || rows.Count > 1;
            if (!usesProfiles) return null;

            var ids = ConfigEditor.DeriveIds(rows);
            for (var index = 0; index < rows.Count; index++)
            {
                var id = (rows[index].Id ?? "").Trim().ToLowerInvariant();
                if (id.Length > 0 && string.Equals(id, active, StringComparison.Ordinal)) return ids[index];
            }
            return null;
        }

        /// <summary>Point at the box the message is about.</summary>
        private void FocusProblem()
        {
            foreach (var row in _rows)
            {
                if (row.Name.Text.Trim().Length == 0) { row.Name.Focus(); return; }
            }
            foreach (var row in _rows)
            {
                if (row.Key.Text.Trim().Length == 0 && row.Env.Length == 0) { row.Key.Focus(); return; }
            }
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var row in _rows)
            {
                if (!seen.Add(row.Name.Text.Trim())) { row.Name.Focus(); row.Name.SelectAll(); return; }
            }
        }

        private string ShowStatus(string message, bool ok)
        {
            _status.ForeColor = ok ? OkColor : ProblemColor;
            _status.Text = message;
            return message;
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _components.Dispose();
                _font.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
