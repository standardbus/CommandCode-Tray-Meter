using System;
using System.Globalization;

namespace CommandCodeMonitor
{
    /// <summary>
    /// Presentation formatting, mirroring the Node implementation so both
    /// produce identical strings. Raw API values carry nine decimals and must
    /// never reach the panel unchanged.
    /// </summary>
    internal static class Format
    {
        private static readonly CultureInfo Italian = CultureInfo.GetCultureInfo("it-IT");
        private static readonly string[] MonthsShort =
            { "gen", "feb", "mar", "apr", "mag", "giu", "lug", "ago", "set", "ott", "nov", "dic" };
        private static readonly string[] DaysShort =
            { "dom", "lun", "mar", "mer", "gio", "ven", "sab" };

        /// <summary>The single separator used in every label.</summary>
        public const string MidDot = " \u00B7 ";

        public static string Percent(double value)
        {
            if (double.IsNaN(value)) return "-";
            return Math.Round(value).ToString("0", CultureInfo.InvariantCulture) + "%";
        }

        /// <summary>`"2"`, `"2,5"`, `"8,45"` - two decimals at most, Italian separator.</summary>
        public static string Amount(double value)
        {
            if (double.IsNaN(value) || double.IsInfinity(value)) return "-";
            var rounded = Math.Round(value * 100) / 100;
            return rounded.ToString("0.##", Italian);
        }

        /// <summary>`"2 / 14"` - the used-against-cap pair under each bar.</summary>
        public static string UsagePair(double used, double cap)
        {
            return Amount(used) + " / " + Amount(cap);
        }

        /// <summary>`"564,0 M"` - hundreds of millions are unreadable in full.</summary>
        public static string TokenCount(double value)
        {
            if (double.IsNaN(value) || value < 0) return "-";
            if (value >= 1e9) return (value / 1e9).ToString("0.00", Italian) + " Mrd";
            if (value >= 1e6) return (value / 1e6).ToString("0.0", Italian) + " M";
            if (value >= 1e3) return (value / 1e3).ToString("0.0", Italian) + " K";
            return value.ToString("0", Italian);
        }

        /// <summary>
        /// `"3120"`. Deliberately ungrouped to match the Node implementation,
        /// which renders run counts the same way; the two must not drift.
        /// </summary>
        public static string Count(double value)
        {
            if (double.IsNaN(value) || value < 0) return "-";
            return Math.Round(value).ToString("0", CultureInfo.InvariantCulture);
        }

        /// <summary>`"3h 12m"`, `"2g 4h"`, `"45m"`, `"ora"`.</summary>
        public static string Delta(TimeSpan span)
        {
            if (span.TotalMilliseconds <= 0) return "ora";
            var totalMinutes = (long)Math.Floor(span.TotalMinutes);
            var days = totalMinutes / 1440;
            var hours = totalMinutes % 1440 / 60;
            var minutes = totalMinutes % 60;
            if (days > 0) return hours > 0 ? days + "g " + hours + "h" : days + "g";
            if (hours > 0) return minutes > 0 ? hours + "h " + minutes + "m" : hours + "h";
            if (totalMinutes > 0) return totalMinutes + "m";
            return "<1m";
        }

        /// <summary>
        /// Compact absolute reset time: `"20:00"`, `"domani 20:00"`, `"lun 20:00"`,
        /// `"12 set 09:30"`.
        /// </summary>
        public static string ResetAt(DateTime utc, DateTime nowUtc)
        {
            var local = utc.ToLocalTime();
            var today = nowUtc.ToLocalTime().Date;
            var clock = local.ToString("HH:mm", CultureInfo.InvariantCulture);
            var dayDiff = (local.Date - today).Days;
            if (dayDiff <= 0) return clock;
            if (dayDiff == 1) return "domani " + clock;
            if (dayDiff < 7) return DaysShort[(int)local.DayOfWeek] + " " + clock;
            return local.Day + " " + MonthsShort[local.Month - 1] + " " + clock;
        }

        /// <summary>Wall-clock stamp for the footer: `"20:14:07"`.</summary>
        public static string Clock(DateTime utc)
        {
            return utc.ToLocalTime().ToString("HH:mm:ss", CultureInfo.InvariantCulture);
        }
    }
}
