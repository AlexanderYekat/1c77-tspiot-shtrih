// ============================================================================
// ДОБАВИТЬ/ЗАМЕНИТЬ В proxy-1c-fmuapi.cs
// Смысл: /document по-прежнему прокидывается в fmuapi,
// а /kkt/* прокидывается в локальную Delphi-программу печати.
// ============================================================================

// 1) Расширить Config:
public class Config
{
    [JsonPropertyName("sourcePort")]
    public int SourcePort { get; set; } = 2579;

    [JsonPropertyName("targetPort")]
    public int TargetPort { get; set; } = 2578;

    [JsonPropertyName("targetHost")]
    public string TargetHost { get; set; } = "localhost";

    // Новое: Delphi/KKT bridge на том же ПК, где proxy.
    [JsonPropertyName("kktHost")]
    public string KktHost { get; set; } = "127.0.0.1";

    [JsonPropertyName("kktPort")]
    public int KktPort { get; set; } = 2580;
}

// 2) В LoadConfig() убрать преждевременный return config;
// Сейчас в вашем фрагменте он стоит сразу после default-значений и делает файл настроек бесполезным.
private Config LoadConfig()
{
    var configPath = GetConfigPath();
    var config = new Config
    {
        SourcePort = 2579,
        TargetPort = 2578,
        TargetHost = "localhost",
        KktHost = "127.0.0.1",
        KktPort = 2580
    };

    if (File.Exists(configPath))
    {
        try
        {
            var jsonString = File.ReadAllText(configPath, Encoding.UTF8);
            config = JsonSerializer.Deserialize<Config>(jsonString) ?? config;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error loading config");
        }
    }
    else
    {
        SaveConfig(config);
    }

    return config;
}

// 3) Добавить общий маппер endpoint-ов.
// Его можно положить в этот же namespace CtoCSharpProxyFmu.
public static class ProxyEndpointMapper
{
    public static void MapProxyEndpoints(this WebApplication app)
    {
        app.MapPost("/document", async (HttpContext context) =>
        {
            var config = app.Services.GetRequiredService<Config>();
            var targetUrl = $"http://{config.TargetHost}:{config.TargetPort}/document";
            await ForwardRequest(context, app, targetUrl);
        });

        app.MapGet("/kkt/info", async (HttpContext context) =>
        {
            var config = app.Services.GetRequiredService<Config>();
            var targetUrl = $"http://{config.KktHost}:{config.KktPort}/info";
            await ForwardRequest(context, app, targetUrl);
        });

        app.MapPost("/kkt/print-check", async (HttpContext context) =>
        {
            var config = app.Services.GetRequiredService<Config>();
            var targetUrl = $"http://{config.KktHost}:{config.KktPort}/print-check";
            await ForwardRequest(context, app, targetUrl);
        });

        app.MapPost("/kkt/open-shift", async (HttpContext context) =>
        {
            var config = app.Services.GetRequiredService<Config>();
            var targetUrl = $"http://{config.KktHost}:{config.KktPort}/open-shift";
            await ForwardRequest(context, app, targetUrl);
        });

        app.MapPost("/kkt/close-shift", async (HttpContext context) =>
        {
            var config = app.Services.GetRequiredService<Config>();
            var targetUrl = $"http://{config.KktHost}:{config.KktPort}/close-shift";
            await ForwardRequest(context, app, targetUrl);
        });

        app.MapPost("/kkt/x-report", async (HttpContext context) =>
        {
            var config = app.Services.GetRequiredService<Config>();
            var targetUrl = $"http://{config.KktHost}:{config.KktPort}/x-report";
            await ForwardRequest(context, app, targetUrl);
        });

        app.MapPost("/kkt/cancel-check", async (HttpContext context) =>
        {
            var config = app.Services.GetRequiredService<Config>();
            var targetUrl = $"http://{config.KktHost}:{config.KktPort}/cancel-check";
            await ForwardRequest(context, app, targetUrl);
        });

        app.MapGet("/api/settings", (HttpContext context) =>
        {
            var config = app.Services.GetRequiredService<Config>();
            return Results.Json(config);
        });

        app.MapPost("/api/settings", async (HttpContext context) =>
        {
            try
            {
                var newConfig = await JsonSerializer.DeserializeAsync<Config>(context.Request.Body);
                if (newConfig == null)
                    return Results.BadRequest("Invalid configuration");

                var configService = app.Services.GetRequiredService<Config>();
                configService.SourcePort = newConfig.SourcePort;
                configService.TargetPort = newConfig.TargetPort;
                configService.TargetHost = newConfig.TargetHost;
                configService.KktHost = newConfig.KktHost;
                configService.KktPort = newConfig.KktPort;

                Program.SaveConfig(newConfig);
                return Results.Ok("Settings saved. Restart service to apply sourcePort changes.");
            }
            catch (Exception ex)
            {
                return Results.BadRequest(ex.Message);
            }
        });
    }

    private static async Task ForwardRequest(HttpContext context, WebApplication app, string targetUrl)
    {
        var logger = app.Services.GetRequiredService<ILogger<Program>>();
        var client = app.Services.GetRequiredService<IHttpClientFactory>().CreateClient();
        client.Timeout = TimeSpan.FromSeconds(180);

        try
        {
            var requestBody = string.Empty;
            if (context.Request.ContentLength.GetValueOrDefault() > 0 || context.Request.Method != HttpMethods.Get)
            {
                using var reader = new StreamReader(context.Request.Body, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
                requestBody = await reader.ReadToEndAsync();
            }

            logger.LogInformation("Forward {Method} {Path} -> {TargetUrl}; Body: {Body}",
                context.Request.Method,
                context.Request.Path,
                targetUrl,
                requestBody);

            using var request = new HttpRequestMessage(new HttpMethod(context.Request.Method), targetUrl);
            if (context.Request.Method != HttpMethods.Get)
            {
                request.Content = new StringContent(requestBody, Encoding.UTF8, "application/json");
            }

            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, context.RequestAborted);
            context.Response.StatusCode = (int)response.StatusCode;
            context.Response.ContentType = response.Content.Headers.ContentType?.ToString() ?? "application/json; charset=utf-8";
            await response.Content.CopyToAsync(context.Response.Body);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Ошибка при проксировании запроса в {TargetUrl}", targetUrl);
            context.Response.StatusCode = StatusCodes.Status500InternalServerError;
            context.Response.ContentType = "application/json; charset=utf-8";
            await context.Response.WriteAsync(JsonSerializer.Serialize(new
            {
                result = 0,
                description = ex.Message
            }), Encoding.UTF8);
        }
    }
}

// 4) В двух местах, где сейчас вручную объявлены app.MapPost("/document"), app.MapGet("/api/settings") и т.д.,
// заменить эти блоки одной строкой:
//
//      app.MapProxyEndpoints();
//
// То есть:
// - в WindowsBackgroundService.ConfigureEndpoints(WebApplication app) оставить только app.MapProxyEndpoints();
// - в Program.Main после app.UseDefaultFiles(); тоже вызвать app.MapProxyEndpoints();
//
// 5) В Program.Main при регистрации Config добавить новые поля:
//
// builder.Services.AddSingleton<Config>(_ => new Config
// {
//     SourcePort = 2579,
//     TargetPort = 2578,
//     TargetHost = "localhost",
//     KktHost = "127.0.0.1",
//     KktPort = 2580
// });
// ============================================================================
