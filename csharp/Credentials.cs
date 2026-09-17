using System;
using System.Collections.Generic;
using System.IO;

namespace CommandCodeMonitor
{
    /// <summary>Result of credential discovery: a token plus where it came from.</summary>
    internal sealed class Credential
    {
        public string Token = "";
        /// <summary>A description for diagnostics. Never the secret itself.</summary>
        public string Source = "none";
        public string Error;
        public string Message;

        public bool Ok { get { return string.IsNullOrEmpty(Error); } }
    }

    /// <summary>
    /// Finds the Command Code bearer token.
    ///
    /// Precedence and file handling follow the Node implementation exactly: an
    /// environment variable, then config.json, then the credential files. A named
    /// account is resolved from its own fields alone (`COMMANDCODE_API_KEY` never
    /// answers for it), which is why the configuration carries a strict flag.
    ///
    /// The files are only ever read - a lapsed token is reported, never refreshed,
    /// because refreshing belongs to the CLI that owns the file and writing it
    /// here would race every other tool on the machine.
    /// </summary>
    internal static class Credentials
    {
        private static readonly string[] ProviderKeys = { "command-code", "commandcode" };
        private static readonly string[] TokenFields = { "access", "apiKey", "key" };

        public static Credential Resolve(MonitorConfig config)
        {
            var envName = (config.ApiKeyEnv ?? "").Trim();

            // A named account resolves only from its own fields. An ambient
            // COMMANDCODE_API_KEY must not stand in for an account that configured
            // its own key: silently monitoring the wrong account is worse than
            // saying so.
            if (config.StrictCredential)
            {
                if (envName.Length > 0)
                {
                    var named = Environment.GetEnvironmentVariable(envName);
                    if (!string.IsNullOrEmpty(named) && named.Trim().Length > 0)
                        return new Credential { Token = named.Trim(), Source = envName };
                }
                if (!string.IsNullOrEmpty(config.ApiKey) && config.ApiKey.Trim().Length > 0)
                    return new Credential { Token = config.ApiKey.Trim(), Source = "config.json" };
                return new Credential
                {
                    Error = "auth_needed",
                    Source = "none",
                    Message = Lang.T("error.profileNoCredentials", config.ProfileName),
                };
            }

            var ambientName = envName.Length > 0 ? envName : "COMMANDCODE_API_KEY";
            var fromEnv = Environment.GetEnvironmentVariable(ambientName);
            if (!string.IsNullOrEmpty(fromEnv) && fromEnv.Trim().Length > 0)
                return new Credential { Token = fromEnv.Trim(), Source = ambientName };

            if (!string.IsNullOrEmpty(config.ApiKey) && config.ApiKey.Trim().Length > 0)
                return new Credential { Token = config.ApiKey.Trim(), Source = "config.json" };

            bool sawExpired = false;
            foreach (var raw in config.CreditFiles)
            {
                var path = ExpandHome(raw);
                if (string.IsNullOrEmpty(path)) continue;

                var record = ReadRecord(path);
                if (record != null)
                {
                    var found = FindCandidate(record, IsOfficialFile(path), DateTime.UtcNow);
                    if (found != null)
                        return new Credential { Token = found.Token, Source = path };
                    if (HasOnlyExpired(record, IsOfficialFile(path), DateTime.UtcNow)) sawExpired = true;
                }
            }

            var credential = new Credential { Error = "auth_needed" };
            // A lapsed session and a machine with no key at all need different
            // instructions, and only the second one benefits from a hint about the
            // environment variable.
            credential.Message = sawExpired
                ? Lang.T("error.expired")
                : Lang.T("error.noCredentials");
            return credential;
        }

        internal static string ExpandHome(string path)
        {
            if (path == null) return null;
            var trimmed = path.Trim();
            if (trimmed.Length == 0) return null;
            if (trimmed == "~") return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            if (trimmed.StartsWith("~/") || trimmed.StartsWith("~\\"))
            {
                var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                return Path.Combine(home, trimmed.Substring(2));
            }
            return Path.IsPathRooted(trimmed) ? trimmed : Path.GetFullPath(trimmed);
        }

        private static bool IsOfficialFile(string path)
        {
            var normalized = path.Replace('\\', '/');
            return normalized.EndsWith(".commandcode/auth.json", StringComparison.OrdinalIgnoreCase);
        }

        private static IDictionary<string, object> ReadRecord(string path)
        {
            try
            {
                if (!File.Exists(path)) return null;
                var text = File.ReadAllText(path);
                if (text.Length > 0 && text[0] == '\uFEFF') text = text.Substring(1);
                return Json.Parse(text) as IDictionary<string, object>;
            }
            catch
            {
                // A missing or malformed file is skipped, never fatal: one broken
                // source must not mask a working one further down the list.
                return null;
            }
        }

        /// <summary>
        /// `apiKey` is unkeyed, so it is only consulted in Command Code's own
        /// file: a shared harness keystore holds every provider the user signed
        /// into, and a key naming no provider must not be read out of one.
        /// </summary>
        private static List<object> Candidates(IDictionary<string, object> record, bool official)
        {
            var values = new List<object>();
            foreach (var key in ProviderKeys)
            {
                object value;
                if (record.TryGetValue(key, out value)) values.Add(value);
            }
            if (official)
            {
                object generic;
                if (record.TryGetValue("apiKey", out generic)) values.Add(generic);
            }
            return values;
        }

        private static Credential FindCandidate(IDictionary<string, object> record, bool official, DateTime now)
        {
            foreach (var raw in Candidates(record, official))
            {
                DateTime? expires;
                var token = TokenOf(raw, out expires);
                if (token == null) continue;
                if (IsExpired(expires, now)) continue;
                return new Credential { Token = token };
            }
            return null;
        }

        private static bool HasOnlyExpired(IDictionary<string, object> record, bool official, DateTime now)
        {
            foreach (var raw in Candidates(record, official))
            {
                DateTime? expires;
                var token = TokenOf(raw, out expires);
                if (token != null && IsExpired(expires, now)) return true;
            }
            return false;
        }

        private static string TokenOf(object value, out DateTime? expires)
        {
            expires = null;
            var text = Json.Text(value);
            if (!string.IsNullOrEmpty(text)) return text;

            var record = value as IDictionary<string, object>;
            if (record == null) return null;

            double? expiresMs = Json.Number(Json.Get(record, "expires"));
            if (expiresMs.HasValue && expiresMs.Value > 0)
                expires = DateTimeOffset.FromUnixTimeMilliseconds((long)expiresMs.Value).UtcDateTime;

            foreach (var field in TokenFields)
            {
                var token = Json.Text(Json.Get(record, field));
                if (!string.IsNullOrEmpty(token)) return token;
            }
            return null;
        }

        private static bool IsExpired(DateTime? expires, DateTime now)
        {
            return expires.HasValue && expires.Value <= now;
        }
    }
}
