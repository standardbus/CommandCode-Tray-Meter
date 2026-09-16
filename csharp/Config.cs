using System;
using System.Collections.Generic;
using System.IO;

namespace CommandCodeMonitor
{
    /// <summary>Thrown when a configuration file exists but cannot be understood.</summary>
    internal sealed class ConfigException : Exception
    {
        public ConfigException(string message) : base(message) { }
    }

    /// <summary>
    /// Effective configuration. Mirrors config.json exactly as the Node
    /// implementation documented it, so both share one file and one README.
    /// </summary>
    internal sealed class MonitorConfig
    {
        public const string DefaultBaseUrl = "https://api.commandcode.ai";

        public string ApiKey = "";
        public string BaseUrl = DefaultBaseUrl;
        public string WhoamiPath = "/alpha/whoami";
        public string CreditsPath = "/alpha/billing/credits";
        public string SubscriptionsPath = "/alpha/billing/subscriptions";
        public string UsageSummaryPath = "/alpha/usage/summary";
        public int RefreshSeconds = 120;
        public double WarnThreshold = 60;
        public double CriticalThreshold = 85;
        /// <summary>Which window the tray ring tracks: fiveHour, weekly or monthly.</summary>
        public string IconMetric = "fiveHour";
        public bool Monochrome;
        public bool ShowTooltip = true;
        public List<string> CreditFiles = new List<string>();
        public int RequestTimeoutMs = 8000;
        public string SourcePath = "";

        public static MonitorConfig Load(string path)
        {
            var config = new MonitorConfig();
            config.SourcePath = path;
            config.CreditFiles.Add("~/.commandcode/auth.json");
            config.CreditFiles.Add("~/.pi/agent/auth.json");

            if (path == null || !File.Exists(path)) return config;

            string text;
            try
            {
                text = File.ReadAllText(path);
            }
            catch (Exception error)
            {
                throw new ConfigException("config.json non leggibile: " + error.Message);
            }

            object root;
            try
            {
                root = Json.Parse(text);
            }
            catch (Exception error)
            {
                throw new ConfigException("config.json non e JSON valido: " + error.Message);
            }

            var apiKey = Json.Text(Json.Get(root, "apiKey"));
            if (!string.IsNullOrEmpty(apiKey)) config.ApiKey = apiKey.Trim();

            var endpoints = Json.Get(root, "endpoints");
            config.BaseUrl = ReadString(endpoints, "baseUrl", DefaultBaseUrl).TrimEnd('/');
            if (config.BaseUrl.Length == 0) config.BaseUrl = DefaultBaseUrl;
            config.WhoamiPath = ReadString(endpoints, "whoamiPath", config.WhoamiPath);
            config.CreditsPath = ReadString(endpoints, "creditsPath", config.CreditsPath);
            config.SubscriptionsPath = ReadString(endpoints, "subscriptionsPath", config.SubscriptionsPath);
            config.UsageSummaryPath = ReadString(endpoints, "usageSummaryPath", config.UsageSummaryPath);

            // Below 15s the monitor would hammer the API for no benefit.
            var refresh = Json.Number(Json.Get(root, "refreshSeconds"));
            if (refresh.HasValue && refresh.Value >= 15) config.RefreshSeconds = (int)refresh.Value;

            var thresholds = Json.Get(root, "thresholds");
            var warn = Json.Number(Json.Get(thresholds, "warn"));
            if (warn.HasValue) config.WarnThreshold = Clamp(warn.Value, 0, 100);
            var critical = Json.Number(Json.Get(thresholds, "critical"));
            if (critical.HasValue) config.CriticalThreshold = Clamp(critical.Value, 0, 100);

            var ui = Json.Get(root, "ui");
            var metric = Json.Text(Json.Get(ui, "iconMetric"));
            if (metric == "fiveHour" || metric == "weekly" || metric == "monthly") config.IconMetric = metric;
            var monochrome = Json.Get(ui, "monochrome");
            if (monochrome is bool) config.Monochrome = (bool)monochrome;
            var showTooltip = Json.Get(ui, "showTooltip");
            if (showTooltip is bool) config.ShowTooltip = (bool)showTooltip;

            var creditFiles = Json.Get(root, "creditFiles") as List<object>;
            if (creditFiles != null && creditFiles.Count > 0)
            {
                config.CreditFiles.Clear();
                foreach (var entry in creditFiles)
                {
                    var value = Json.Text(entry);
                    if (!string.IsNullOrEmpty(value)) config.CreditFiles.Add(value);
                }
            }

            var timeout = Json.Number(Json.Get(root, "requestTimeoutMs"));
            if (timeout.HasValue && timeout.Value >= 1000) config.RequestTimeoutMs = (int)timeout.Value;

            return config;
        }

        private static string ReadString(object node, string key, string fallback)
        {
            var value = Json.Text(Json.Get(node, key));
            return string.IsNullOrEmpty(value) ? fallback : value;
        }

        private static double Clamp(double value, double min, double max)
        {
            if (value < min) return min;
            if (value > max) return max;
            return value;
        }
    }
}
