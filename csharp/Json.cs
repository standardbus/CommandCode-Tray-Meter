using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace CommandCodeMonitor
{
    /// <summary>
    /// A JSON object that remembers the order its keys were read or written in.
    ///
    /// The parser returns this instead of a plain Dictionary because the settings
    /// window rewrites the file the user maintains: keeping their key order (and
    /// the `$comment` notes where they put them) is the difference between an
    /// edited file and a shuffled one. It implements IDictionary&lt;string,
    /// object&gt;, so every reader that already casts to that interface - the
    /// configuration, the credential files, the profiles list - is unaffected.
    /// </summary>
    internal sealed class JsonObject : IDictionary<string, object>
    {
        private readonly List<string> _order = new List<string>();
        private readonly Dictionary<string, object> _values =
            new Dictionary<string, object>(StringComparer.Ordinal);

        public object this[string key]
        {
            get { return _values[key]; }
            set
            {
                if (!_values.ContainsKey(key)) _order.Add(key);
                _values[key] = value;
            }
        }

        /// <summary>The keys, in the order they were read or written.</summary>
        public ICollection<string> Keys { get { return new List<string>(_order); } }

        public ICollection<object> Values
        {
            get
            {
                var values = new List<object>(_order.Count);
                foreach (var key in _order) values.Add(_values[key]);
                return values;
            }
        }

        public int Count { get { return _order.Count; } }

        public bool IsReadOnly { get { return false; } }

        public void Add(string key, object value)
        {
            if (_values.ContainsKey(key)) throw new ArgumentException("duplicate JSON key: " + key, "key");
            _order.Add(key);
            _values.Add(key, value);
        }

        public bool ContainsKey(string key) { return _values.ContainsKey(key); }

        public bool Remove(string key)
        {
            if (!_values.Remove(key)) return false;
            _order.Remove(key);
            return true;
        }

        public bool TryGetValue(string key, out object value)
        {
            return _values.TryGetValue(key, out value);
        }

        public void Add(KeyValuePair<string, object> item) { Add(item.Key, item.Value); }

        public void Clear()
        {
            _order.Clear();
            _values.Clear();
        }

        public bool Contains(KeyValuePair<string, object> item)
        {
            object value;
            return _values.TryGetValue(item.Key, out value) && Equals(value, item.Value);
        }

        public void CopyTo(KeyValuePair<string, object>[] array, int arrayIndex)
        {
            if (array == null) throw new ArgumentNullException("array");
            foreach (var pair in this) array[arrayIndex++] = pair;
        }

        public bool Remove(KeyValuePair<string, object> item)
        {
            if (!Contains(item)) return false;
            return Remove(item.Key);
        }

        public IEnumerator<KeyValuePair<string, object>> GetEnumerator()
        {
            foreach (var key in _order) yield return new KeyValuePair<string, object>(key, _values[key]);
        }

        System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator()
        {
            return GetEnumerator();
        }
    }

    /// <summary>
    /// Small JSON reader and writer sufficient for this program's own schema.
    ///
    /// Hand-rolled rather than taken from a dependency or from
    /// System.Web.Extensions: the executable is compiled with the in-box C#
    /// compiler, and this keeps it a single file with no external references and
    /// no dependency on which assemblies a given machine happens to carry.
    /// It reads into ordered objects (<see cref="JsonObject"/>), lists, strings,
    /// doubles, booleans and null, and writes the same shapes back out.
    ///
    /// The writer exists because the settings window maintains config.json, and a
    /// file the user reads deserves to stay readable: it indents by two spaces and
    /// escapes only what JSON requires, so the result looks like the file that was
    /// there before.
    /// </summary>
    internal static class Json
    {
        public static object Parse(string text)
        {
            if (text == null) return null;
            int index = 0;
            object value = ParseValue(text, ref index);
            SkipWhitespace(text, ref index);
            return value;
        }

        /// <summary>Read a property for a dictionary, or null when absent.</summary>
        public static object Get(object node, string key)
        {
            var record = node as IDictionary<string, object>;
            if (record == null) return null;
            object value;
            return record.TryGetValue(key, out value) ? value : null;
        }

        /// <summary>Unwrap a `data` envelope when present, as the API does.</summary>
        public static object UnwrapData(object node)
        {
            var inner = Get(node, "data") as IDictionary<string, object>;
            return inner != null ? (object)inner : node;
        }

        public static double? Number(object node)
        {
            if (node == null) return null;
            if (node is double) return (double)node;
            if (node is bool) return null;
            var text = node as string;
            if (text != null)
            {
                double parsed;
                if (double.TryParse(text.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out parsed))
                    return parsed;
            }
            return null;
        }

        public static string Text(object node)
        {
            var text = node as string;
            return text == null ? null : text.Trim();
        }

        private static void SkipWhitespace(string text, ref int index)
        {
            while (index < text.Length && char.IsWhiteSpace(text[index])) index++;
        }

        private static object ParseValue(string text, ref int index)
        {
            SkipWhitespace(text, ref index);
            if (index >= text.Length) throw new FormatException("truncated JSON");
            char c = text[index];
            switch (c)
            {
                case '{': return ParseObject(text, ref index);
                case '[': return ParseArray(text, ref index);
                case '"': return ParseString(text, ref index);
                case 't': Expect(text, ref index, "true"); return true;
                case 'f': Expect(text, ref index, "false"); return false;
                case 'n': Expect(text, ref index, "null"); return null;
                default: return ParseNumber(text, ref index);
            }
        }

        private static void Expect(string text, ref int index, string literal)
        {
            if (index + literal.Length > text.Length ||
                string.CompareOrdinal(text, index, literal, 0, literal.Length) != 0)
                throw new FormatException("unexpected JSON at position " + index);
            index += literal.Length;
        }

        private static JsonObject ParseObject(string text, ref int index)
        {
            // Ordered, because a configuration round-trip must not shuffle the
            // file the user keeps by hand.
            var result = new JsonObject();
            index++; // {
            SkipWhitespace(text, ref index);
            if (index < text.Length && text[index] == '}') { index++; return result; }
            while (true)
            {
                SkipWhitespace(text, ref index);
                string key = ParseString(text, ref index);
                SkipWhitespace(text, ref index);
                if (index >= text.Length || text[index] != ':') throw new FormatException("JSON: missing ':'");
                index++;
                result[key] = ParseValue(text, ref index);
                SkipWhitespace(text, ref index);
                if (index >= text.Length) throw new FormatException("truncated JSON");
                if (text[index] == ',') { index++; continue; }
                if (text[index] == '}') { index++; return result; }
                throw new FormatException("JSON: expected ',' or '}'");
            }
        }

        private static List<object> ParseArray(string text, ref int index)
        {
            var result = new List<object>();
            index++; // [
            SkipWhitespace(text, ref index);
            if (index < text.Length && text[index] == ']') { index++; return result; }
            while (true)
            {
                result.Add(ParseValue(text, ref index));
                SkipWhitespace(text, ref index);
                if (index >= text.Length) throw new FormatException("truncated JSON");
                if (text[index] == ',') { index++; continue; }
                if (text[index] == ']') { index++; return result; }
                throw new FormatException("JSON: expected ',' or ']'");
            }
        }

        private static string ParseString(string text, ref int index)
        {
            if (text[index] != '"') throw new FormatException("JSON: expected a string");
            index++;
            var builder = new StringBuilder();
            while (index < text.Length)
            {
                char c = text[index++];
                if (c == '"') return builder.ToString();
                if (c != '\\') { builder.Append(c); continue; }
                if (index >= text.Length) break;
                char escape = text[index++];
                switch (escape)
                {
                    case '"': builder.Append('"'); break;
                    case '\\': builder.Append('\\'); break;
                    case '/': builder.Append('/'); break;
                    case 'b': builder.Append('\b'); break;
                    case 'f': builder.Append('\f'); break;
                    case 'n': builder.Append('\n'); break;
                    case 'r': builder.Append('\r'); break;
                    case 't': builder.Append('\t'); break;
                    case 'u':
                        if (index + 4 > text.Length) throw new FormatException("JSON: incomplete \\u");
                        builder.Append((char)Convert.ToInt32(text.Substring(index, 4), 16));
                        index += 4;
                        break;
                    default: throw new FormatException("JSON: unknown escape \\" + escape);
                }
            }
            throw new FormatException("JSON: unterminated string");
        }

        private static object ParseNumber(string text, ref int index)
        {
            int start = index;
            while (index < text.Length && "+-0123456789.eE".IndexOf(text[index]) >= 0) index++;
            if (index == start) throw new FormatException("JSON: invalid number");
            double value;
            if (!double.TryParse(text.Substring(start, index - start), NumberStyles.Float,
                    CultureInfo.InvariantCulture, out value))
                throw new FormatException("JSON: invalid number");
            return value;
        }

        // --- writer ---------------------------------------------------------

        /// <summary>
        /// One JSON document as text, indented by two spaces and newline
        /// terminated, so a file this program writes still reads like the one the
        /// user keeps.
        ///
        /// The shapes it understands are the ones the parser produces, plus the
        /// plain dictionaries, lists and integers other callers build documents
        /// from.
        /// </summary>
        public static string Write(object value)
        {
            var builder = new StringBuilder(512);
            WriteValue(builder, value, 0);
            builder.Append("\r\n");
            return builder.ToString();
        }

        private static void WriteValue(StringBuilder builder, object value, int depth)
        {
            if (value == null) { builder.Append("null"); return; }

            var text = value as string;
            if (text != null) { WriteString(builder, text); return; }

            if (value is bool) { builder.Append(((bool)value) ? "true" : "false"); return; }

            if (value is double || value is float)
            {
                WriteNumber(builder, Convert.ToDouble(value, CultureInfo.InvariantCulture));
                return;
            }

            if (value is int || value is long || value is short || value is byte)
            {
                builder.Append(Convert.ToInt64(value, CultureInfo.InvariantCulture)
                    .ToString(CultureInfo.InvariantCulture));
                return;
            }

            var record = value as IDictionary<string, object>;
            if (record != null) { WriteObject(builder, record, depth); return; }

            var items = value as System.Collections.IEnumerable;
            if (items != null) { WriteArray(builder, items, depth); return; }

            // Nothing else can come out of the parser, and writing `null` beats
            // writing an invalid document.
            builder.Append("null");
        }

        private static void WriteObject(StringBuilder builder, IDictionary<string, object> record, int depth)
        {
            if (record.Count == 0) { builder.Append("{}"); return; }
            builder.Append('{');
            var first = true;
            foreach (var pair in record)
            {
                if (!first) builder.Append(',');
                first = false;
                builder.Append('\n').Append(Indent(depth + 1));
                WriteString(builder, pair.Key);
                builder.Append(": ");
                WriteValue(builder, pair.Value, depth + 1);
            }
            builder.Append('\n').Append(Indent(depth)).Append('}');
        }

        private static void WriteArray(StringBuilder builder, System.Collections.IEnumerable items, int depth)
        {
            var first = true;
            var any = false;
            var body = new StringBuilder();
            foreach (var item in items)
            {
                if (!first) body.Append(',');
                first = false;
                any = true;
                body.Append('\n').Append(Indent(depth + 1));
                WriteValue(body, item, depth + 1);
            }
            if (!any) { builder.Append("[]"); return; }
            builder.Append('[').Append(body).Append('\n').Append(Indent(depth)).Append(']');
        }

        private static string Indent(int depth)
        {
            return new string(' ', depth * 2);
        }

        private static void WriteNumber(StringBuilder builder, double number)
        {
            // A document holds no NaN or infinity: neither is expressible in JSON.
            if (double.IsNaN(number) || double.IsInfinity(number)) { builder.Append("null"); return; }
            // "R" round-trips, and writes 120 rather than 120.0 for the whole
            // numbers a configuration is full of.
            builder.Append(number.ToString("R", CultureInfo.InvariantCulture));
        }

        private static void WriteString(StringBuilder builder, string value)
        {
            builder.Append('"');
            foreach (var character in value)
            {
                switch (character)
                {
                    case '"': builder.Append("\\\""); break;
                    case '\\': builder.Append("\\\\"); break;
                    case '\b': builder.Append("\\b"); break;
                    case '\f': builder.Append("\\f"); break;
                    case '\n': builder.Append("\\n"); break;
                    case '\r': builder.Append("\\r"); break;
                    case '\t': builder.Append("\\t"); break;
                    default:
                        if (character < ' ')
                            builder.Append("\\u").Append(((int)character).ToString("x4", CultureInfo.InvariantCulture));
                        else
                            builder.Append(character);
                        break;
                }
            }
            builder.Append('"');
        }
    }
}
