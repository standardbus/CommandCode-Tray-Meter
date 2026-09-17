using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace CommandCodeMonitor
{
    /// <summary>
    /// The language the interface speaks, process-wide.
    ///
    /// The tables are compiled in (`Lang.Generated.cs`, generated from `lang/*.json`
    /// by `scripts/gen-lang.ps1`) because the executable is a single self-contained
    /// file: nothing is read from `lang/` at runtime, so a moved or missing
    /// directory can never blank the interface.
    ///
    /// Lookup order, mirroring `src/i18n.mjs`: the active table, then English, then
    /// the key itself. A visible `panel.tokens` in the interface is a bug report,
    /// not a crash.
    /// </summary>
    internal static class Lang
    {
        /// <summary>Language used when nothing is configured, or when a lookup fails.</summary>
        public const string DefaultLanguage = "en";

        /// <summary>Selector asking for whatever the operating system is set to.</summary>
        private const string AutoLanguage = "auto";

        /// <summary>Environment variables a POSIX system reports its locale with.</summary>
        private static readonly string[] LocaleEnvironment = { "LC_ALL", "LC_MESSAGES", "LANG" };

        // Written once at startup and read from the fetch threads as well, which is
        // why it is volatile: a reference assignment is atomic, but the reader must
        // not be allowed to keep a stale table for the rest of a fetch.
        private static volatile string _active = DefaultLanguage;
        private static string _notice = "";

        // The fallback table is also the argument-order contract used by T: see
        // ArgumentOrder below. Both are built by the type initializer, which the
        // runtime runs once and single-threaded.
        private static readonly Dictionary<string, string[]> ArgumentOrder = BuildArgumentOrder();

        /// <summary>The language code the interface is rendered in.</summary>
        public static string Active { get { return _active; } }

        /// <summary>A fallback message recorded by the last SetLanguage, or an empty string.</summary>
        public static string FallbackNotice { get { return _notice; } }

        /// <summary>Every language compiled into this executable, in selector order.</summary>
        public static string[] LanguageCodes()
        {
            var codes = new string[LangTables.Codes.Length];
            Array.Copy(LangTables.Codes, codes, codes.Length);
            return codes;
        }

        /// <summary>
        /// The culture numbers, dates and month names are formatted with. The
        /// language names a market locale (`it` is `it-IT`), exactly as the Node
        /// implementation does, so both render `8,45` and `settimanale` alike.
        /// </summary>
        public static CultureInfo Culture
        {
            get
            {
                switch (_active)
                {
                    case "it": return CultureInfo.GetCultureInfo("it-IT");
                    case "zh": return CultureInfo.GetCultureInfo("zh-CN");
                    default: return CultureInfo.GetCultureInfo("en-US");
                }
            }
        }

        /// <summary>
        /// Translate one key, substituting `{name}` placeholders from `args`.
        ///
        /// Arguments are positional and are given in the order the placeholders
        /// appear in the *English* string. That is what the call sites read like,
        /// and it keeps a translation that reorders placeholders correct: Chinese
        /// writes `format.monthDay` as `{month}{day}日`, and the day and the month
        /// still receive their own values.
        ///
        /// A placeholder with no matching argument is left as it stands, again like
        /// the Node implementation: printing `{time}` shows a caller bug instead of
        /// swallowing the value silently.
        /// </summary>
        public static string T(string key, params object[] args)
        {
            var value = Lookup(_active, key);
            if (value == null && _active != DefaultLanguage) value = Lookup(DefaultLanguage, key);
            if (value == null) return key;
            if (args == null || args.Length == 0) return value;
            return Substitute(value, key, args);
        }

        /// <summary>
        /// Select the language for this process.
        /// </summary>
        /// <param name="requested">
        /// `en`, `it`, `zh`, `auto` to follow the operating system, or anything else
        /// to keep English.
        /// </param>
        /// <returns>The code that is now active.</returns>
        public static string SetLanguage(string requested)
        {
            var wanted = (requested ?? "").Trim().ToLowerInvariant();
            _notice = "";
            if (wanted.Length == 0 || wanted == DefaultLanguage)
            {
                _active = DefaultLanguage;
                return _active;
            }

            var code = wanted == AutoLanguage ? DetectSystemLanguage() : wanted;
            if (Array.IndexOf(LangTables.Codes, code) < 0)
            {
                // Fall back first, then compose the notice: a notice about an
                // unreadable language is itself readable only in English.
                _active = DefaultLanguage;
                _notice = T("language.unknown", wanted);
                return _active;
            }

            var table = LangTables.For(code);
            if (table == null || table.Count == 0)
            {
                _active = DefaultLanguage;
                _notice = T("language.missingFile", code);
                return _active;
            }

            _active = code;
            return _active;
        }

        /// <summary>
        /// The language a system locale such as `it_IT.UTF-8` or `zh-Hans-CN` asks
        /// for, or English when it names no language we ship.
        ///
        /// The environment is consulted first because it is what a portable or
        /// POSIX-style runtime sets; the Windows display language is the fallback.
        /// </summary>
        public static string DetectSystemLanguage()
        {
            foreach (var name in LocaleEnvironment)
            {
                var value = Environment.GetEnvironmentVariable(name);
                if (!string.IsNullOrEmpty(value) && value.Trim().Length > 0) return MapLocale(value);
            }
            return MapLocale(CultureInfo.CurrentUICulture.Name);
        }

        private static string MapLocale(string tag)
        {
            var trimmed = (tag ?? "").Trim().ToLowerInvariant();
            if (trimmed.Length == 0) return DefaultLanguage;
            var separator = trimmed.IndexOfAny(new[] { '_', '-', '.' });
            var basis = separator < 0 ? trimmed : trimmed.Substring(0, separator);
            if (basis == "it") return "it";
            if (basis == "zh") return "zh";
            return DefaultLanguage;
        }

        private static string Lookup(string code, string key)
        {
            var table = LangTables.For(code);
            if (table == null) return null;
            string value;
            return table.TryGetValue(key, out value) ? value : null;
        }

        /// <summary>Placeholder names of the English string of a key, in order.</summary>
        private static Dictionary<string, string[]> BuildArgumentOrder()
        {
            var order = new Dictionary<string, string[]>(StringComparer.Ordinal);
            foreach (var entry in LangTables.En)
            {
                var names = new List<string>();
                CollectPlaceholders(entry.Value, names);
                order[entry.Key] = names.ToArray();
            }
            return order;
        }

        private static void CollectPlaceholders(string value, List<string> names)
        {
            var index = 0;
            while (index < value.Length)
            {
                var open = value.IndexOf('{', index);
                if (open < 0) return;
                var close = value.IndexOf('}', open + 1);
                if (close < 0) return;
                var name = value.Substring(open + 1, close - open - 1);
                if (IsPlaceholder(name) && !names.Contains(name)) names.Add(name);
                index = close + 1;
            }
        }

        private static string Substitute(string value, string key, object[] args)
        {
            string[] order;
            if (!ArgumentOrder.TryGetValue(key, out order)) order = new string[0];

            var builder = new StringBuilder(value.Length + 16);
            var index = 0;
            while (index < value.Length)
            {
                var open = value.IndexOf('{', index);
                if (open < 0)
                {
                    builder.Append(value, index, value.Length - index);
                    break;
                }
                var close = value.IndexOf('}', open + 1);
                if (close < 0)
                {
                    builder.Append(value, index, value.Length - index);
                    break;
                }

                builder.Append(value, index, open - index);
                var name = value.Substring(open + 1, close - open - 1);
                var position = IsPlaceholder(name) ? Array.IndexOf(order, name) : -1;
                if (position >= 0 && position < args.Length && args[position] != null)
                    builder.Append(Convert.ToString(args[position], CultureInfo.InvariantCulture));
                else
                    builder.Append(value, open, close - open + 1);
                index = close + 1;
            }
            return builder.ToString();
        }

        /// <summary>`{time}`, but not `{}` or `{two words}`: the same shape the Node table uses.</summary>
        private static bool IsPlaceholder(string name)
        {
            if (name.Length == 0) return false;
            foreach (var character in name)
                if (!(character >= 'a' && character <= 'z') && !(character >= 'A' && character <= 'Z')) return false;
            return true;
        }
    }
}
