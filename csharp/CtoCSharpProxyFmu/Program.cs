using System.Net.WebSockets;
using System.Reflection;
using System.Runtime.Versioning;
using System.Text.Json;
using Microsoft.Extensions.FileProviders;

namespace CtoCSharpProxyFmu;

[SupportedOSPlatform("windows")]
public static class Program
{
    public static async Task Main(string[] args)
    {
        if (args.Length > 0)
        {
            switch (args[0].ToLowerInvariant())
            {
                case "install":
                    await WindowsServiceInstaller.InstallAsync();
                    return;
                case "uninstall":
                    await WindowsServiceInstaller.UninstallAsync();
                    return;
                case "start":
                    await WindowsServiceInstaller.StartAsync();
                    return;
                case "stop":
                    await WindowsServiceInstaller.StopAsync();
                    return;
            }
        }

        var configService = new ConfigService();
        var startupConfig = configService.Current;

        var builder = WebApplication.CreateBuilder(args);

        builder.Host.UseWindowsService(options =>
        {
            options.ServiceName = "cto_csharp_proxyfmu";
        });

        builder.Logging.AddEventLog(settings =>
        {
            settings.SourceName = "CTO CSharp ProxyFMU";
        });

        builder.WebHost.UseUrls($"http://*:{startupConfig.SourcePort}");

        builder.Services.AddSingleton(configService);
        builder.Services.AddSingleton<RequestLogHub>();
        builder.Services.AddSingleton<ProxyForwarder>();
        builder.Services.AddSingleton<HealthChecker>();
        builder.Services.AddHttpClient("proxy", client =>
        {
            client.Timeout = TimeSpan.FromMinutes(3);
        });
        builder.Services.AddHttpClient("health", client =>
        {
            client.Timeout = TimeSpan.FromSeconds(3);
        });

        var app = builder.Build();

        app.UseWebSockets();

        var staticPath = ResolveStaticPath();
        if (Directory.Exists(staticPath))
        {
            var fileProvider = new PhysicalFileProvider(staticPath);
            app.UseFileServer(new FileServerOptions
            {
                FileProvider = fileProvider,
                EnableDefaultFiles = true,
                EnableDirectoryBrowsing = false,
                RequestPath = ""
            });
        }

        app.MapGet("/api/settings", (ConfigService config) => Results.Json(config.Current));

        app.MapGet("/health", async (HealthChecker health, CancellationToken cancellationToken) =>
        {
            var report = await health.CheckAsync(cancellationToken);
            return Results.Json(report);
        });

        app.MapPost("/api/settings", async (
            HttpContext context,
            ConfigService configService,
            IHostApplicationLifetime lifetime,
            ILoggerFactory loggerFactory) =>
        {
            var logger = loggerFactory.CreateLogger("ProxySettings");
            try
            {
                var newConfig = await JsonSerializer.DeserializeAsync<Config>(context.Request.Body);
                if (newConfig is null)
                {
                    return Results.BadRequest("Некорректная конфигурация");
                }

                var oldConfig = configService.Current;
                configService.Update(newConfig);

                var portChanged = oldConfig.SourcePort != newConfig.SourcePort;
                var message = portChanged
                    ? "Настройки сохранены. Требуется restart службы."
                    : "Настройки сохранены.";

                _ = Task.Run(async () =>
                {
                    await Task.Delay(1000);
                    try
                    {
                        if (WindowsServiceInstaller.IsRunningAsService())
                        {
                            await WindowsServiceInstaller.RestartAsync();
                        }
                        else
                        {
                            lifetime.StopApplication();
                        }
                    }
                    catch (Exception ex)
                    {
                        logger.LogError(ex, "Не удалось перезапустить службу после сохранения настроек");
                    }
                });

                return Results.Ok(message);
            }
            catch (Exception ex)
            {
                return Results.BadRequest(ex.Message);
            }
        });

        app.Map("/ws", async (HttpContext context, RequestLogHub logHub) =>
        {
            if (!context.WebSockets.IsWebSocketRequest)
            {
                context.Response.StatusCode = StatusCodes.Status400BadRequest;
                return;
            }

            using var socket = await context.WebSockets.AcceptWebSocketAsync();
            await logHub.HandleWebSocketAsync(socket, context.RequestAborted);
        });

        app.MapMethods("/document", ["POST", "OPTIONS"], async (
            HttpContext context,
            ConfigService configService,
            ProxyForwarder forwarder) =>
        {
            if (HttpMethods.IsOptions(context.Request.Method))
            {
                context.Response.StatusCode = StatusCodes.Status204NoContent;
                return;
            }

            var config = configService.Current;
            var targetBase = $"http://{config.TargetHost}:{config.TargetPort}";
            await forwarder.ForwardAsync(
                context,
                targetBase,
                "/document",
                "FMU",
                context.RequestAborted,
                defaultContentType: "application/json; charset=utf-8");
        });

        app.Map("/kkt/{**path}", async (
            HttpContext context,
            string path,
            ConfigService configService,
            ProxyForwarder forwarder) =>
        {
            var config = configService.Current;
            var targetBase = $"http://{config.KktHost}:{config.KktPort}";
            var targetPath = "/" + path;
            await forwarder.ForwardAsync(context, targetBase, targetPath, "KKT", context.RequestAborted);
        });

        app.Lifetime.ApplicationStarted.Register(() =>
        {
            var config = configService.Current;
            var version = GetServiceVersion();
            var logger = app.Services.GetRequiredService<ILoggerFactory>().CreateLogger("ProxyStartup");
            var logHub = app.Services.GetRequiredService<RequestLogHub>();
            logger.LogInformation(
                "Proxy v{Version} запущен на порту {SourcePort}. FMU: {TargetHost}:{TargetPort}. KKT: {KktHost}:{KktPort}",
                version,
                config.SourcePort,
                config.TargetHost,
                config.TargetPort,
                config.KktHost,
                config.KktPort);
            logHub.Log($"Служба v{version} запущена. FMU: {config.TargetHost}:{config.TargetPort}, KKT: {config.KktHost}:{config.KktPort}");
        });

        await app.RunAsync();
    }

    private static string GetServiceVersion()
    {
        var assembly = Assembly.GetExecutingAssembly();
        var informational = assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()
            ?.InformationalVersion;
        if (!string.IsNullOrWhiteSpace(informational))
        {
            // Strip optional "+<commit>" suffix from InformationalVersion
            var plusIndex = informational.IndexOf('+');
            return plusIndex >= 0 ? informational[..plusIndex] : informational;
        }

        return assembly.GetName().Version?.ToString() ?? "0.0.0.0";
    }

    private static string ResolveStaticPath()
    {
        var nextToExe = Path.Combine(AppContext.BaseDirectory, "static");
        if (Directory.Exists(nextToExe))
        {
            return nextToExe;
        }

        var devPath = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "static"));
        if (Directory.Exists(devPath))
        {
            return devPath;
        }

        return nextToExe;
    }
}
