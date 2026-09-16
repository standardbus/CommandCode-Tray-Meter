using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace CommandCodeMonitor
{
    /// <summary>
    /// Small JSON reader sufficient for this program's own schema.
    ///
    /// Hand-rolled rather than taken from a dependency or from
    /// System.Web.Extensions: the executable is compiled with the in-box C#
    /// compiler, and this keeps it a single file with no external references and
    /// no dependency on which assemblies a given machine happens to carry.
    /// It returns plain dictionaries, lists, strings, doubles, booleans and null.
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
            if (index >= text.Length) throw new FormatException("JSON troncato");
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
                throw new FormatException("JSON inatteso in posizione " + index);
            index += literal.Length;
        }

        private static Dictionary<string, object> ParseObject(string text, ref int index)
        {
            var result = new Dictionary<string, object>(StringComparer.Ordinal);
            index++; // {
            SkipWhitespace(text, ref index);
            if (index < text.Length && text[index] == '}') { index++; return result; }
            while (true)
            {
                SkipWhitespace(text, ref index);
                string key = ParseString(text, ref index);
                SkipWhitespace(text, ref index);
                if (index >= text.Length || text[index] != ':') throw new FormatException("JSON: manca ':'");
                index++;
                result[key] = ParseValue(text, ref index);
                SkipWhitespace(text, ref index);
                if (index >= text.Length) throw new FormatException("JSON troncato");
                if (text[index] == ',') { index++; continue; }
                if (text[index] == '}') { index++; return result; }
                throw new FormatException("JSON: atteso ',' o '}'");
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
                if (index >= text.Length) throw new FormatException("JSON troncato");
                if (text[index] == ',') { index++; continue; }
                if (text[index] == ']') { index++; return result; }
                throw new FormatException("JSON: atteso ',' o ']'");
            }
        }

        private static string ParseString(string text, ref int index)
        {
            if (text[index] != '"') throw new FormatException("JSON: attesa stringa");
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
                        if (index + 4 > text.Length) throw new FormatException("JSON: \\u incompleto");
                        builder.Append((char)Convert.ToInt32(text.Substring(index, 4), 16));
                        index += 4;
                        break;
                    default: throw new FormatException("JSON: escape sconosciuto \\" + escape);
                }
            }
            throw new FormatException("JSON: stringa non chiusa");
        }

        private static object ParseNumber(string text, ref int index)
        {
            int start = index;
            while (index < text.Length && "+-0123456789.eE".IndexOf(text[index]) >= 0) index++;
            if (index == start) throw new FormatException("JSON: numero non valido");
            double value;
            if (!double.TryParse(text.Substring(start, index - start), NumberStyles.Float,
                    CultureInfo.InvariantCulture, out value))
                throw new FormatException("JSON: numero non valido");
            return value;
        }
    }
}
