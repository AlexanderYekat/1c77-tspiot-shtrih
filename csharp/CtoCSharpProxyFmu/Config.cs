using System.Text.Json.Serialization;

namespace CtoCSharpProxyFmu;

public class Config
{
    [JsonPropertyName("sourcePort")]
    public int SourcePort { get; set; } = 2579;

    [JsonPropertyName("targetPort")]
    public int TargetPort { get; set; } = 2578;

    [JsonPropertyName("targetHost")]
    public string TargetHost { get; set; } = "localhost";

    [JsonPropertyName("kktPort")]
    public int KktPort { get; set; } = 2580;

    [JsonPropertyName("kktHost")]
    public string KktHost { get; set; } = "localhost";

    public Config Clone() => new()
    {
        SourcePort = SourcePort,
        TargetPort = TargetPort,
        TargetHost = TargetHost,
        KktPort = KktPort,
        KktHost = KktHost
    };
}
