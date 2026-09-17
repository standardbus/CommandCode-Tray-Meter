using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;

namespace CommandCodeMonitor
{
    /// <summary>
    /// One configured account: its identity and the credential fields it owns.
    ///
    /// A `Profile` is presentation and address only - the token itself is never
    /// copied out of it, and the name is what the panel and the tray menu show.
    /// </summary>
    internal sealed class Profile
    {
        public string Id = "";
        public string Name = "";
        public string ApiKey = "";
        public string ApiKeyEnv = "";
        /// <summary>
        /// True for an account named in `profiles`: it resolves its credential only
        /// from its own fields. False for the implicit single account, which keeps
        /// the historical env -> config.json -> auth files precedence.
        /// </summary>
        public bool Strict;
    }

    /// <summary>
    /// Turns the configuration into the accounts to monitor, mirroring
    /// `resolveProfiles` in `src/limits.mjs`.
    ///
    /// A configuration without `profiles` is one implicit account, which is exactly
    /// how the monitor behaved before profiles existed: every existing config.json
    /// keeps working untouched.
    /// </summary>
    internal static class Profiles
    {
        /// <summary>An account id: lower case, digits and hyphens, usable as a config key.</summary>
        private static bool IsValidId(string id)
        {
            if (string.IsNullOrEmpty(id)) return false;
            if (!IsLowerOrDigit(id[0])) return false;
            foreach (var character in id)
                if (!IsLowerOrDigit(character) && character != '-') return false;
            return true;
        }

        private static bool IsLowerOrDigit(char character)
        {
            return (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9');
        }

        /// <summary>
        /// The accounts described by the configuration, in configuration order.
        /// </summary>
        /// <exception cref="ConfigException">
        /// Naming the offending entry, never a generic failure: an unusable
        /// `profiles` list is a user mistake the panel has to explain.
        /// </exception>
        public static List<Profile> Resolve(MonitorConfig config)
        {
            var entries = config.Profiles;
            if (entries == null || entries.Count == 0)
            {
                var name = (config.Name ?? "").Trim();
                return new List<Profile>
                {
                    new Profile
                    {
                        Id = "default",
                        Name = name.Length > 0 ? name : "default",
                        ApiKey = config.ApiKey,
                        ApiKeyEnv = config.ApiKeyEnv,
                        // Not strict: the implicit account is the pre-profiles
                        // configuration, and it must keep behaving like it.
                        Strict = false,
                    },
                };
            }

            var seen = new HashSet<string>(StringComparer.Ordinal);
            var profiles = new List<Profile>();
            for (var index = 0; index < entries.Count; index++)
            {
                var record = entries[index] as IDictionary<string, object>;
                if (record == null)
                    throw new ConfigException("entry " + (index + 1) + " is not an object");

                var rawId = Json.Text(Json.Get(record, "id")) ?? "";
                var id = rawId.Trim().ToLowerInvariant();
                if (!IsValidId(id))
                    throw new ConfigException("entry " + (index + 1) + " has an invalid id \"" + rawId + "\"");
                if (!seen.Add(id))
                    throw new ConfigException("duplicate account id \"" + id + "\"");

                var apiKey = (Json.Text(Json.Get(record, "apiKey")) ?? "").Trim();
                var apiKeyEnv = (Json.Text(Json.Get(record, "apiKeyEnv")) ?? "").Trim();
                if (apiKey.Length == 0 && apiKeyEnv.Length == 0)
                    throw new ConfigException("account \"" + id + "\" has neither apiKey nor apiKeyEnv");

                var name = (Json.Text(Json.Get(record, "name")) ?? "").Trim();
                profiles.Add(new Profile
                {
                    Id = id,
                    Name = name.Length > 0 ? name : id,
                    ApiKey = apiKey,
                    ApiKeyEnv = apiKeyEnv,
                    Strict = true,
                });
            }
            return profiles;
        }
    }

    /// <summary>
    /// A monitored account: its identity, its HTTP client and its latest reading.
    /// One instance per account, fetched independently of the others.
    /// </summary>
    internal sealed class MonitorAccount
    {
        public Profile Profile;
        public LimitsClient Client;
        public LimitsResult Data;
        public bool Fetching;
        public CancellationTokenSource Pending;

        public void Cancel()
        {
            try { if (Pending != null) Pending.Cancel(); } catch { }
        }

        public void Dispose()
        {
            Cancel();
            try { if (Client != null) Client.Dispose(); } catch { }
        }
    }

    /// <summary>
    /// The runtime state the tray keeps between runs: which account the icon follows.
    ///
    /// It is the same `.cache/active-profile.json` the Node session and the
    /// PowerShell tray read and write - `{"id": "...", "at": <epoch ms>}` - so a
    /// choice made in one of them is honoured by the others. It is never written
    /// into config.json: this program does not rewrite the file the user maintains.
    ///
    /// Every failure is swallowed. A monitor that cannot read or write its own
    /// state must still monitor.
    /// </summary>
    internal sealed class ProfileState
    {
        /// <summary>Cache entry, shared with `src/limits.mjs` and `src/tray.ps1`.</summary>
        private const string FileName = "active-profile.json";

        private readonly string _directory;
        private readonly string _path;

        /// <summary>The remembered account id, or an empty string.</summary>
        public string ActiveProfile = "";

        private ProfileState(string directory, string path)
        {
            _directory = directory;
            _path = path;
        }

        public static ProfileState Open(string configPath)
        {
            string directory = null;
            if (!string.IsNullOrEmpty(configPath))
            {
                try { directory = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(configPath)), ".cache"); }
                catch { directory = null; }
            }
            var path = directory == null ? null : Path.Combine(directory, FileName);
            var state = new ProfileState(directory, path);
            state.Load();
            return state;
        }

        private void Load()
        {
            if (_path == null) return;
            try
            {
                if (!File.Exists(_path)) return;
                var text = File.ReadAllText(_path);
                // The PowerShell tray writes this file with Set-Content -Encoding
                // UTF8, which prepends a BOM on Windows PowerShell 5.1.
                if (text.Length > 0 && text[0] == '\uFEFF') text = text.Substring(1);
                var id = Json.Text(Json.Get(Json.Parse(text), "id"));
                if (!string.IsNullOrEmpty(id)) ActiveProfile = id.Trim().ToLowerInvariant();
            }
            catch
            {
                // Unreadable or malformed state is no state: the configuration then
                // decides which account the tray follows.
            }
        }

        /// <summary>Remember the account the user picked in the tray menu.</summary>
        public void Remember(string profileId)
        {
            var id = (profileId ?? "").Trim().ToLowerInvariant();
            if (_path == null || id.Length == 0) return;
            ActiveProfile = id;
            if (id.IndexOf('"') >= 0 || id.IndexOf('\\') >= 0) return; // never write text that could break the file
            try
            {
                if (!Directory.Exists(_directory)) Directory.CreateDirectory(_directory);
                var json = new StringBuilder("{\"id\":\"").Append(id).Append("\",\"at\":")
                    .Append(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()).Append('}').ToString();
                File.WriteAllText(_path, json, new UTF8Encoding(false));
            }
            catch
            {
                // Read-only installation folder: the choice just does not survive a
                // restart, which is not worth interrupting the user for.
            }
        }
    }
}
