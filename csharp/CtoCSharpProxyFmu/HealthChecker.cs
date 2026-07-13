using System.Net.Sockets;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CtoCSharpProxyFmu;

public sealed class HealthChecker
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    private readonly IHttpClientFactory _httpClientFactory;
    private readonly ConfigService _configService;

    public HealthChecker(IHttpClientFactory httpClientFactory, ConfigService configService)
    {
        _httpClientFactory = httpClientFactory;
        _configService = configService;
    }

    public async Task<HealthReport> CheckAsync(CancellationToken cancellationToken)
    {
        var config = _configService.Current;
        var kkt = await CheckKktAsync(config, cancellationToken);
        var fmu = await CheckFmuAsync(config, cancellationToken);

        return new HealthReport
        {
            Result = 1,
            Description = "OK",
            Service = "cto_csharp_proxyfmu",
            Status = "up",
            Version = GetAssemblyVersion(),
            Kkt = kkt,
            Fmu = fmu
        };
    }

    private async Task<KktHealth> CheckKktAsync(Config config, CancellationToken cancellationToken)
    {
        var url = $"http://{config.KktHost}:{config.KktPort}/health";
        try
        {
            var client = _httpClientFactory.CreateClient("health");
            using var response = await client.GetAsync(url, cancellationToken);
            var body = await response.Content.ReadAsStringAsync(cancellationToken);

            if (!response.IsSuccessStatusCode)
            {
                return new KktHealth
                {
                    Reachable = false,
                    Status = "down",
                    Host = config.KktHost,
                    Port = config.KktPort,
                    Error = $"HTTP {(int)response.StatusCode}"
                };
            }

            var parsed = string.IsNullOrWhiteSpace(body)
                ? null
                : JsonSerializer.Deserialize<DelphiHealthResponse>(body, JsonOptions);

            return new KktHealth
            {
                Reachable = true,
                Status = parsed?.Status ?? "up",
                Host = config.KktHost,
                Port = config.KktPort,
                Version = parsed?.Version
            };
        }
        catch (Exception ex)
        {
            return new KktHealth
            {
                Reachable = false,
                Status = "down",
                Host = config.KktHost,
                Port = config.KktPort,
                Error = ex.Message
            };
        }
    }

    private static async Task<FmuHealth> CheckFmuAsync(Config config, CancellationToken cancellationToken)
    {
        try
        {
            using var tcp = new TcpClient();
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(3));

            await tcp.ConnectAsync(config.TargetHost, config.TargetPort, timeout.Token);

            return new FmuHealth
            {
                Reachable = true,
                Status = "up",
                Host = config.TargetHost,
                Port = config.TargetPort
            };
        }
        catch (Exception ex)
        {
            return new FmuHealth
            {
                Reachable = false,
                Status = "down",
                Host = config.TargetHost,
                Port = config.TargetPort,
                Error = ex.Message
            };
        }
    }

    private static string GetAssemblyVersion()
    {
        return Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "0.0.0.0";
    }

    private sealed class DelphiHealthResponse
    {
        [JsonPropertyName("status")]
        public string? Status { get; set; }

        [JsonPropertyName("version")]
        public string? Version { get; set; }
    }
}

public sealed class HealthReport
{
    [JsonPropertyName("result")]
    public int Result { get; set; }

    [JsonPropertyName("description")]
    public string Description { get; set; } = "OK";

    [JsonPropertyName("service")]
    public string Service { get; set; } = "cto_csharp_proxyfmu";

    [JsonPropertyName("status")]
    public string Status { get; set; } = "up";

    [JsonPropertyName("version")]
    public string Version { get; set; } = "0.0.0.0";

    [JsonPropertyName("kkt")]
    public KktHealth Kkt { get; set; } = new();

    [JsonPropertyName("fmu")]
    public FmuHealth Fmu { get; set; } = new();
}

public sealed class KktHealth
{
    [JsonPropertyName("reachable")]
    public bool Reachable { get; set; }

    [JsonPropertyName("status")]
    public string Status { get; set; } = "unknown";

    [JsonPropertyName("host")]
    public string Host { get; set; } = "";

    [JsonPropertyName("port")]
    public int Port { get; set; }

    [JsonPropertyName("version")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Version { get; set; }

    [JsonPropertyName("error")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Error { get; set; }
}

public sealed class FmuHealth
{
    [JsonPropertyName("reachable")]
    public bool Reachable { get; set; }

    [JsonPropertyName("status")]
    public string Status { get; set; } = "unknown";

    [JsonPropertyName("host")]
    public string Host { get; set; } = "";

    [JsonPropertyName("port")]
    public int Port { get; set; }

    [JsonPropertyName("error")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Error { get; set; }
}
