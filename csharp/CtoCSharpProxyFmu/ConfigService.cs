using System.Text.Json;

namespace CtoCSharpProxyFmu;

public sealed class ConfigService
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    private readonly object _lock = new();
    private Config _config;

    public ConfigService()
    {
        _config = LoadFromDisk();
    }

    public Config Current
    {
        get
        {
            lock (_lock)
            {
                return _config.Clone();
            }
        }
    }

    public void Update(Config newConfig)
    {
        lock (_lock)
        {
            _config = newConfig.Clone();
            SaveToDisk(_config);
        }
    }

    public static string GetConfigPath()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var appDir = Path.Combine(appData, "CTO_CSHARP", "ProxyFMU");
        Directory.CreateDirectory(appDir);
        return Path.Combine(appDir, "ctocsharp_proxyfmu_config.json");
    }

    private static Config LoadFromDisk()
    {
        var defaults = new Config();
        var configPath = GetConfigPath();

        if (!File.Exists(configPath))
        {
            SaveToDisk(defaults);
            return defaults;
        }

        try
        {
            var json = File.ReadAllText(configPath);
            var loaded = JsonSerializer.Deserialize<Config>(json) ?? defaults;
            return Normalize(loaded, defaults);
        }
        catch
        {
            return defaults;
        }
    }

    private static Config Normalize(Config loaded, Config defaults)
    {
        if (loaded.SourcePort <= 0)
        {
            loaded.SourcePort = defaults.SourcePort;
        }

        if (loaded.TargetPort <= 0)
        {
            loaded.TargetPort = defaults.TargetPort;
        }

        if (string.IsNullOrWhiteSpace(loaded.TargetHost))
        {
            loaded.TargetHost = defaults.TargetHost;
        }

        if (loaded.KktPort <= 0)
        {
            loaded.KktPort = defaults.KktPort;
        }

        if (string.IsNullOrWhiteSpace(loaded.KktHost))
        {
            loaded.KktHost = defaults.KktHost;
        }

        return loaded;
    }

    private static void SaveToDisk(Config config)
    {
        var json = JsonSerializer.Serialize(config, JsonOptions);
        File.WriteAllText(GetConfigPath(), json);
    }
}
