using System;
using System.IO;
using System.Threading;
using System.Windows.Forms;

namespace CommandCodeMonitor
{
    internal static class Program
    {
        /// <summary>
        /// A named mutex is the single-instance guard: two tray icons would mean
        /// two pollers hitting the API and two tooltips fighting for the same
        /// notification-area slot.
        /// </summary>
        private const string MutexName = @"Local\CommandCodeMonitorTray";

        [STAThread]
        private static void Main(string[] args)
        {
            try { NativeMethods.SetProcessDPIAware(); } catch { }

            var configPath = ResolveConfigPath(args);

            // The language comes from the configuration but has to be known before
            // anything is printed, so the file is read once here for its language
            // and once for real below. `--language` wins, which is what lets one run
            // be checked in another language without editing config.json.
            var requested = ValueOf(args, "--language");
            Lang.SetLanguage(!string.IsNullOrEmpty(requested) ? requested : ConfiguredLanguage(configPath));
            if (Lang.FallbackNotice.Length > 0) Console.Error.WriteLine(Lang.FallbackNotice);

            if (HasFlag(args, "--help"))
            {
                PrintHelp();
                return;
            }

            if (HasFlag(args, "--selftest") || HasFlag(args, "--render"))
            {
                Environment.ExitCode = SelfTest.Run(args, configPath);
                return;
            }

            bool owned;
            using (var mutex = new Mutex(true, MutexName, out owned))
            {
                if (!owned) return;

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);

                MonitorConfig config;
                try
                {
                    config = MonitorConfig.Load(configPath);
                }
                catch (ConfigException error)
                {
                    MessageBox.Show(error.Message + "\n\n" + Lang.T("exe.configPath", configPath),
                        Lang.T("log.errorTitle"), MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return;
                }

                using (var main = new MainForm(config))
                {
                    if (HasFlag(args, "--demo")) main.EnableDemo(1500, 9000);
                    Application.Run();
                }

                GC.KeepAlive(mutex);
            }
        }

        /// <summary>
        /// The language configured in config.json, or null when the file cannot be
        /// read: an unreadable configuration is reported later, in English, because
        /// the language it asks for is unknowable by definition.
        /// </summary>
        private static string ConfiguredLanguage(string configPath)
        {
            try { return MonitorConfig.Load(configPath).Language; }
            catch (ConfigException) { return null; }
        }

        /// <summary>The usage text, one language-selected line at a time.</summary>
        private static void PrintHelp()
        {
            Console.WriteLine(Lang.T("exe.helpTitle"));
            Console.WriteLine(Lang.T("exe.helpStart"));
            Console.WriteLine(Lang.T("exe.helpSelftest"));
            Console.WriteLine(Lang.T("exe.helpConfig"));
            Console.WriteLine(Lang.T("exe.helpLanguage"));
            Console.WriteLine(Lang.T("exe.helpRender"));
        }

        /// <summary>
        /// config.json lives next to the executable, so the whole thing stays
        /// portable: copy the folder and it keeps working.
        /// </summary>
        private static string ResolveConfigPath(string[] args)
        {
            var explicitPath = ValueOf(args, "--config");
            if (!string.IsNullOrEmpty(explicitPath))
                return Path.GetFullPath(explicitPath);

            var beside = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "config.json");
            if (File.Exists(beside)) return beside;

            // Fall back to the working directory, which is where a developer runs it.
            var local = Path.Combine(Directory.GetCurrentDirectory(), "config.json");
            if (File.Exists(local)) return local;

            return beside;
        }

        private static bool HasFlag(string[] args, string flag)
        {
            foreach (var arg in args)
                if (string.Equals(arg, flag, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        private static string ValueOf(string[] args, string name)
        {
            for (var index = 0; index < args.Length; index++)
            {
                if (string.Equals(args[index], name, StringComparison.OrdinalIgnoreCase))
                    return index + 1 < args.Length ? args[index + 1] : null;
                if (args[index].StartsWith(name + "=", StringComparison.OrdinalIgnoreCase))
                    return args[index].Substring(name.Length + 1);
            }
            return null;
        }
    }
}
