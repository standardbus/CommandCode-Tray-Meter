using System;
using System.IO;
using System.Windows.Forms;

namespace CommandCodeMonitor
{
    /// <summary>
    /// Where a failure goes when it is not part of the normal flow.
    ///
    /// There are two destinations and they answer different questions:
    ///
    /// - `%TEMP%\ccm-diag.log`, the file the executable already writes its
    ///   diagnostics to. It keeps every detail, including the stack, and it is what
    ///   a developer reads afterwards;
    /// - a message box, in the language the interface is speaking, because a
    ///   WinForms unhandled-exception dialog is English, says nothing about what
    ///   the program was doing, and is the thing the user saw instead of their
    ///   settings window.
    ///
    /// Nothing here ever throws: a reporter that fails must not become the failure.
    /// </summary>
    internal static class Diagnostics
    {
        /// <summary>The file the executable writes its own diagnostics to.</summary>
        private const string FileName = "ccm-diag.log";

        private static readonly object Gate = new object();
        /// <summary>True while a report is on screen, so a failing reporter cannot loop.</summary>
        private static bool _reporting;
        private static string _lastReported = "";

        /// <summary>
        /// Append one line to the diagnostics log. The timestamp format is fixed on
        /// purpose: a translated locale would change the field order and break any
        /// grep over past runs.
        /// </summary>
        public static void Log(string message)
        {
            try
            {
                var path = Path.Combine(Path.GetTempPath(), FileName);
                var line = DateTime.Now.ToString("HH:mm:ss.fff") + "  " + message + Environment.NewLine;
                lock (Gate)
                {
                    File.AppendAllText(path, line);
                }
            }
            catch
            {
                // Read-only or full temp directory: the monitor must still monitor.
            }
        }

        /// <summary>
        /// Hand a failure to the user: the log always, and a message box in the
        /// active language.
        /// </summary>
        /// <param name="what">A short, untranslated tag naming where it happened.</param>
        /// <param name="error">The failure, or null.</param>
        public static void Report(string what, Exception error)
        {
            var message = error == null ? "no detail" : error.Message;
            Log(what + ": " + (error == null ? "no detail" : error.ToString()));

            var signature = what + "|" + message;
            lock (Gate)
            {
                // A failure raised again on every paint would otherwise put up a
                // message box for each one; the log keeps every occurrence.
                if (_reporting || signature == _lastReported) return;
                _lastReported = signature;
                _reporting = true;
            }

            try
            {
                MessageBox.Show(Lang.T("error.unexpected", message), Lang.T("log.errorTitle"),
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            catch
            {
                // A reporter that cannot report must not become the failure.
            }
            finally
            {
                lock (Gate) { _reporting = false; }
            }
        }
    }
}
