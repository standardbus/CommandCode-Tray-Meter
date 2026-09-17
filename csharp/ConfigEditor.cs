using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace CommandCodeMonitor
{
    /// <summary>
    /// One account as the settings window presents it: what the row shows, and
    /// what identifies the account it came from.
    /// </summary>
    internal sealed class AccountEdit
    {
        /// <summary>
        /// The id the account has in config.json, or an empty string for a row the
        /// user just added. Never shown: the id belongs to the file, the name
        /// belongs to the user.
        /// </summary>
        public string Id = "";

        /// <summary>The name the account had when the window opened.</summary>
        public string OriginalName = "";

        /// <summary>The name typed in the row.</summary>
        public string Name = "";

        /// <summary>
        /// What the key box holds. With `UseSystemPasswordChar` the box holds the
        /// real value whatever it displays, so this is never a row of dots.
        /// </summary>
        public string ApiKey = "";

        /// <summary>The environment variable to keep when no inline key was typed.</summary>
        public string ApiKeyEnv = "";
    }

    /// <summary>Everything the settings window edits, as plain data.</summary>
    internal sealed class ConfigEdit
    {
        public List<AccountEdit> Accounts = new List<AccountEdit>();
        /// <summary>`en`, `it`, `zh` or `auto`.</summary>
        public string Language = "en";
        public int RefreshSeconds = 120;
        public double Warn = 60;
        public double Critical = 85;
        /// <summary>`fiveHour`, `weekly` or `monthly`.</summary>
        public string IconMetric = "fiveHour";
        public bool Monochrome;
        public bool ShowTooltip = true;
        /// <summary>
        /// The account to record as active, or null to leave `activeProfile` as the
        /// file has it. Set only when a rename would otherwise strand it.
        /// </summary>
        public string ActiveProfile;
    }

    /// <summary>
    /// Turns what the settings window collected into a config.json.
    ///
    /// This is the first code in the program that writes the file the user
    /// maintains, so the rules are deliberately conservative:
    ///
    /// - the file is read back and *edited*, never regenerated, so every key this
    ///   window does not manage survives - `endpoints`, `creditFiles`,
    ///   `requestTimeoutMs`, the `$comment` notes, anything added by hand;
    /// - it is written to a temporary file in the same directory and that file is
    ///   moved over the real one, so an interrupted save cannot truncate it;
    /// - it is written as UTF-8 without a BOM, and read tolerating one.
    ///
    /// Ids are derived from names because the schema requires
    /// `^[a-z0-9][a-z0-9-]*$` and the window asks for a name: a row whose name did
    /// not change keeps the id it already had, so a cosmetic edit does not churn
    /// the file or lose `activeProfile`.
    /// </summary>
    internal static class ConfigEditor
    {
        private static readonly Regex IdShape = new Regex("^[a-z0-9][a-z0-9-]*$", RegexOptions.CultureInvariant);

        /// <summary>The id a name asks for, ignoring the ones already taken.</summary>
        public static string Slug(string name)
        {
            var builder = new StringBuilder();
            var hyphen = false;
            var text = (name ?? "").Trim();
            foreach (var raw in text)
            {
                var character = char.ToLowerInvariant(raw);
                if ((character >= 'a' && character <= 'z') || (character >= '0' && character <= '9'))
                {
                    builder.Append(character);
                    hyphen = false;
                    continue;
                }
                // Every separator collapses into one hyphen, so "Work  /  Home"
                // does not become "work---home".
                if (builder.Length > 0 && !hyphen)
                {
                    builder.Append('-');
                    hyphen = true;
                }
            }

            var slug = builder.ToString().Trim('-');
            // A name written entirely in a script the id alphabet cannot carry (or
            // in punctuation) still needs an id.
            return slug.Length == 0 ? "account" : slug;
        }

        /// <summary>
        /// The id of every row, in row order: derived from the name, unchanged when
        /// the name is unchanged, and made unique by appending -2, -3, ...
        /// </summary>
        public static List<string> DeriveIds(IList<AccountEdit> rows)
        {
            var taken = new HashSet<string>(StringComparer.Ordinal);
            var ids = new List<string>();
            foreach (var row in rows)
            {
                var name = (row.Name ?? "").Trim();
                var reuse = row.Id.Length > 0 && string.Equals(name, row.OriginalName, StringComparison.Ordinal);
                var basis = reuse && IdShape.IsMatch(row.Id) ? row.Id : Slug(name);

                var id = basis;
                var suffix = 1;
                while (!taken.Add(id))
                {
                    suffix++;
                    id = basis + "-" + suffix;
                }
                ids.Add(id);
            }
            return ids;
        }

        /// <summary>
        /// The message describing what is wrong with the rows, or null when they can
        /// be written. Nothing is written until this returns null.
        ///
        /// The messages are the `settings.*` ones, so the window can show them as
        /// they are and a translator owns the wording.
        /// </summary>
        public static string Validate(IList<AccountEdit> rows)
        {
            foreach (var row in rows)
                if ((row.Name ?? "").Trim().Length == 0) return Lang.T("settings.nameRequired");

            foreach (var row in rows)
            {
                var hasKey = (row.ApiKey ?? "").Trim().Length > 0;
                var keepsEnv = (row.ApiKeyEnv ?? "").Trim().Length > 0;
                if (!hasKey && !keepsEnv) return Lang.T("settings.keyRequired", (row.Name ?? "").Trim());
            }

            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var row in rows)
            {
                var name = (row.Name ?? "").Trim();
                if (!seen.Add(name)) return Lang.T("settings.duplicateName", name);
            }

            return null;
        }

        /// <summary>
        /// Write the edited configuration.
        /// </summary>
        /// <exception cref="ConfigException">
        /// The file exists but cannot be understood, so rewriting it would throw
        /// away whatever the user put there.
        /// </exception>
        public static void Save(string path, ConfigEdit edit)
        {
            if (path == null || path.Length == 0) throw new ConfigException("no config.json path");
            var problem = Validate(edit.Accounts);
            if (problem != null) throw new ConfigException(problem);

            var root = Read(path);
            var ids = DeriveIds(edit.Accounts);

            // A configuration that lists accounts keeps listing them; a
            // configuration without `profiles` keeps its single-account form until
            // the user asks for a second account. Migrating a working single-account
            // file on a cosmetic save would silently change how its key is resolved.
            var filesAccounts = false;
            var existingProfiles = Json.Get(root, "profiles") as List<object>;
            if (existingProfiles != null && existingProfiles.Count > 0) filesAccounts = true;
            if (filesAccounts || edit.Accounts.Count > 1) WriteProfiles(root, edit, ids);
            else WriteSingleAccount(root, edit.Accounts[0]);

            root["language"] = edit.Language;
            root["refreshSeconds"] = (double)edit.RefreshSeconds;

            var thresholds = Child(root, "thresholds");
            thresholds["warn"] = edit.Warn;
            thresholds["critical"] = edit.Critical;

            var ui = Child(root, "ui");
            ui["iconMetric"] = edit.IconMetric;
            ui["monochrome"] = edit.Monochrome;
            ui["showTooltip"] = edit.ShowTooltip;

            // Only ever set here to keep it pointing at the account it already
            // named; `null` leaves the file's own value alone.
            if (edit.ActiveProfile != null) root["activeProfile"] = edit.ActiveProfile;

            WriteAtomic(path, Json.Write(root));
        }

        /// <summary>
        /// Record the account the user picked in the bubble as the one that opens
        /// next time.
        ///
        /// Best effort by design: the same choice is written to `.cache` as well,
        /// so a read-only folder costs the persistence of the choice, not the
        /// switch itself.
        /// </summary>
        public static bool SetActiveProfile(string path, string id)
        {
            if (path == null || path.Length == 0 || string.IsNullOrEmpty(id)) return false;
            if (!File.Exists(path)) return false;
            try
            {
                var root = Read(path);
                if (!Equals(Json.Text(Json.Get(root, "activeProfile")), id)) root["activeProfile"] = id;
                WriteAtomic(path, Json.Write(root));
                return true;
            }
            catch
            {
                return false;
            }
        }

        /// <summary>The document as it is on disk, or an empty one.</summary>
        private static JsonObject Read(string path)
        {
            var root = new JsonObject();
            if (path == null || !File.Exists(path)) return root;

            string text;
            try
            {
                text = File.ReadAllText(path);
            }
            catch (Exception error)
            {
                throw new ConfigException(Lang.T("error.configUnreadable", error.Message));
            }

            if (text.Length > 0 && text[0] == '\uFEFF') text = text.Substring(1);
            if (text.Trim().Length == 0) return root;

            object parsed;
            try
            {
                parsed = Json.Parse(text);
            }
            catch (Exception error)
            {
                throw new ConfigException(Lang.T("error.configInvalid", error.Message));
            }

            var record = parsed as JsonObject;
            if (record == null)
                throw new ConfigException(Lang.T("error.configInvalid", "the root is not an object"));
            return record;
        }

        /// <summary>A nested object, created on first use.</summary>
        private static JsonObject Child(JsonObject root, string key)
        {
            var existing = Json.Get(root, key) as JsonObject;
            if (existing != null) return existing;
            var created = new JsonObject();
            root[key] = created;
            return created;
        }

        /// <summary>
        /// Rewrite the `profiles` list from the rows.
        ///
        /// An entry that is being kept is edited where it lies, so a key inside it
        /// this window knows nothing about - a note, a future field - is preserved
        /// exactly like the top level ones.
        /// </summary>
        private static void WriteProfiles(JsonObject root, ConfigEdit edit, List<string> ids)
        {
            var original = Json.Get(root, "profiles") as List<object>;
            var entries = new List<object>(edit.Accounts.Count);
            for (var index = 0; index < edit.Accounts.Count; index++)
            {
                var row = edit.Accounts[index];
                var entry = Take(original, row.Id) ?? new JsonObject();
                entry["id"] = ids[index];
                entry["name"] = (row.Name ?? "").Trim();
                WriteCredential(entry, row);
                entries.Add(entry);
            }
            root["profiles"] = entries;
        }

        /// <summary>Find the entry an existing account came from, once.</summary>
        private static JsonObject Take(List<object> entries, string id)
        {
            if (entries == null || string.IsNullOrEmpty(id)) return null;
            var wanted = id.Trim().ToLowerInvariant();
            for (var index = 0; index < entries.Count; index++)
            {
                var entry = entries[index] as JsonObject;
                if (entry == null) continue;
                var candidate = (Json.Text(Json.Get(entry, "id")) ?? "").Trim().ToLowerInvariant();
                if (!string.Equals(candidate, wanted, StringComparison.Ordinal)) continue;
                entries[index] = null; // claimed: a second row with the same id is a new account
                return entry;
            }
            return null;
        }

        /// <summary>
        /// Write the single account of a configuration without `profiles`: the key
        /// fields at the top level, exactly as that form is documented.
        /// </summary>
        private static void WriteSingleAccount(JsonObject root, AccountEdit row)
        {
            root["name"] = (row.Name ?? "").Trim();
            WriteCredential(root, row);
        }

        /// <summary>
        /// The credential pair of one account: an inline key wins, an environment
        /// variable is kept when nothing was typed.
        ///
        /// The two are never both left behind: an account resolves `apiKeyEnv` first,
        /// so a typed key that sat next to a stale variable would be ignored.
        /// </summary>
        private static void WriteCredential(JsonObject entry, AccountEdit row)
        {
            var key = (row.ApiKey ?? "").Trim();
            if (key.Length > 0)
            {
                entry["apiKey"] = key;
                entry.Remove("apiKeyEnv");
                return;
            }

            var env = (row.ApiKeyEnv ?? "").Trim();
            entry.Remove("apiKey");
            if (env.Length > 0) entry["apiKeyEnv"] = env;
            else entry.Remove("apiKeyEnv");
        }

        /// <summary>
        /// Replace the file with `text`, through a temporary file in the same
        /// directory.
        ///
        /// The temporary file is complete before the real one is touched, so a
        /// crash - or a full disk - leaves the previous configuration intact rather
        /// than a truncated one. Same directory, so the replace is a rename and not
        /// a copy across volumes.
        /// </summary>
        public static void WriteAtomic(string path, string text)
        {
            var full = Path.GetFullPath(path);
            var directory = Path.GetDirectoryName(full);
            if (!string.IsNullOrEmpty(directory) && !Directory.Exists(directory))
                Directory.CreateDirectory(directory);

            var temporary = Path.Combine(directory ?? ".",
                Path.GetFileName(full) + "." + Guid.NewGuid().ToString("N") + ".tmp");

            try
            {
                File.WriteAllText(temporary, text, new UTF8Encoding(false));
                if (File.Exists(full))
                {
                    try
                    {
                        // Atomic on NTFS, and it keeps the destination's attributes.
                        File.Replace(temporary, full, null);
                        return;
                    }
                    catch (Exception)
                    {
                        // A filesystem without Replace, or a destination another
                        // program removed in between: overwrite with the complete
                        // temporary file. Only the atomicity is lost, not the text.
                        File.Copy(temporary, full, true);
                        return;
                    }
                }
                File.Move(temporary, full);
            }
            finally
            {
                try { if (File.Exists(temporary)) File.Delete(temporary); } catch { }
            }
        }
    }
}
