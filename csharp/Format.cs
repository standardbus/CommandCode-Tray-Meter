using System;
using System.Globalization;

namespace CommandCodeMonitor
{
    /// <summary>
    /// Presentation formatting, mirroring the Node implementation so both
    /// produce identical strings. Raw API values carry nine decimals and must
    /// never reach the panel unchanged.
    ///
    /// Numbers and calendar names follow the active language: `it` renders `8,45`
    /// and `set`, `zh` renders `9月`. Clock times stay 24-hour in every language,
    /// because the Node implementation pads the parts itself and the two must not
    /// drift.
    /// </summary>
    internal static class Format
    {
        /// <summary>The single separator used in every label.</summary>
        public const string MidDot = " \u00B7 ";

        /// <summary>`"37%"`, `"-"` when there is no number. Percentages are integers in every language.</summary>
        public static string Percent(double value)
        {
            if (double.IsNaN(value)) return "-";
            return Math.Round(value).ToString("0", CultureInfo.InvariantCulture) + "%";
        }

        /// <summary>`"2"`, `"2,5"`, `"8,45"` - two decimals at most, in the active culture.</summary>
        public static string Amount(double value)
        {
            if (double.IsNaN(value) || double.IsInfinity(value)) return "-";
            var rounded = Math.Round(value * 100) / 100;
            return rounded.ToString("0.##", Lang.Culture);
        }

        /// <summary>`"2 / 14"` - the used-against-cap pair under each bar.</summary>
        public static string UsagePair(double used, double cap)
        {
            return Amount(used) + " / " + Amount(cap);
        }

        /// <summary>
        /// `"564,0 M"`, `"1,84 Mld"` - hundreds of millions are unreadable in full.
        /// The suffix is a translated unit, not an English letter.
        /// </summary>
        public static string TokenCount(double value)
        {
            if (double.IsNaN(value) || value < 0) return "-";
            if (value >= 1e9) return (value / 1e9).ToString("0.00", Lang.Culture) + " " + Lang.T("units.billion");
            if (value >= 1e6) return (value / 1e6).ToString("0.0", Lang.Culture) + " " + Lang.T("units.million");
            if (value >= 1e3) return (value / 1e3).ToString("0.0", Lang.Culture) + " " + Lang.T("units.thousand");
            return value.ToString("0", Lang.Culture);
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

        /// <summary>`"3h 12m"`, `"2g 4h"`, `"45m"`, `"&lt;1m"`.</summary>
        public static string Delta(TimeSpan span)
        {
            if (span.TotalMilliseconds <= 0) return Lang.T("format.lessThanMinute");
            var totalMinutes = (long)Math.Floor(span.TotalMinutes);
            var days = totalMinutes / 1440;
            var hours = totalMinutes % 1440 / 60;
            var minutes = totalMinutes % 60;
            if (days > 0)
            {
                return hours > 0
                    ? days + Lang.T("format.days") + " " + hours + Lang.T("format.hours")
                    : days + Lang.T("format.days");
            }
            if (hours > 0)
            {
                return minutes > 0
                    ? hours + Lang.T("format.hours") + " " + minutes + Lang.T("format.minutes")
                    : hours + Lang.T("format.hours");
            }
            if (totalMinutes > 0) return totalMinutes + Lang.T("format.minutes");
            return Lang.T("format.lessThanMinute");
        }

        /// <summary>
        /// Compact absolute reset time: `"20:00"`, `"tomorrow 20:00"`, `"Mon 20:00"`,
        /// `"12 Sep 09:30"`. Month and weekday names come from the language's
        /// culture, never from an array baked into this file.
        /// </summary>
        public static string ResetAt(DateTime utc, DateTime nowUtc)
        {
            var local = utc.ToLocalTime();
            var today = nowUtc.ToLocalTime().Date;
            var clock = local.ToString("HH:mm", CultureInfo.InvariantCulture);
            var dayDiff = (local.Date - today).Days;
            if (dayDiff <= 0) return clock;
            if (dayDiff == 1) return Lang.T("format.tomorrow") + " " + clock;
            var culture = Lang.Culture;
            if (dayDiff < 7)
                return culture.DateTimeFormat.GetAbbreviatedDayName(local.DayOfWeek) + " " + clock;
            // `format.monthDay` is ordered by the language: English puts the day
            // first, Chinese the month first.
            return Lang.T("format.monthDay", local.Day, culture.DateTimeFormat.GetAbbreviatedMonthName(local.Month))
                   + " " + clock;
        }

        /// <summary>Wall-clock stamp for the footer: `"20:14:07"`.</summary>
        public static string Clock(DateTime utc)
        {
            return utc.ToLocalTime().ToString("HH:mm:ss", CultureInfo.InvariantCulture);
        }
    }
}
