using Microsoft.Extensions.Hosting;
using System.Net.Http;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Diagnostics;
using System.ServiceProcess;
using System.Reflection;
using System.Text;
using System.Net.Http.Headers;
using System.Net.Sockets;

namespace CtoCSharpProxyFmu
{
    public class Config
    {
        [JsonPropertyName("sourcePort")]
        public int SourcePort { get; set; } = 2579;

        [JsonPropertyName("targetPort")]
        public int TargetPort { get; set; } = 2578;

        [JsonPropertyName("targetHost")]
        public string TargetHost { get; set; } = "localhost";
    }

    public class WindowsBackgroundService : BackgroundService
    {
        private readonly ILogger<WindowsBackgroundService> _logger;
        private readonly IConfiguration _configuration;
        private readonly IHostApplicationLifetime _hostLifetime;
        private Config _config;
        private readonly object _configLock = new object();
        private readonly HttpClient _httpClient;

        public WindowsBackgroundService(
            ILogger<WindowsBackgroundService> logger,
            IConfiguration configuration,
            IHostApplicationLifetime hostLifetime)
        {
            _logger = logger;
            _configuration = configuration;
            _hostLifetime = hostLifetime;
            _httpClient = new HttpClient();
            _config = LoadConfig();
        }

        private Config LoadConfig()
        {
            var configPath = GetConfigPath();
            var config = new Config
            {
                SourcePort = 2579,
                TargetPort = 2578,
                TargetHost = "localhost"
            };
            return config;
            if (File.Exists(configPath))
            {
                try
                {
                    var jsonString = File.ReadAllText(configPath);
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

        private void SaveConfig(Config config)
        {
            var configPath = GetConfigPath();
            var jsonString = JsonSerializer.Serialize(config, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(configPath, jsonString);
        }

        private string GetConfigPath()
        {
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            var appDir = Path.Combine(appData, "CTO_CSHARP", "ProxyFMU");
            Directory.CreateDirectory(appDir);
            return Path.Combine(appDir, "ctocsharp_proxyfmu_config.json");
        }

        protected override async Task ExecuteAsync(CancellationToken stoppingToken)
        {
            try
            {
                _logger.LogInformation("Служба начинает запуск...");
                _logger.LogInformation("Конфигурация портов: Source Port: {SourcePort}, Target Port: {TargetPort}", 
                    _config.SourcePort, 
                    _config.TargetPort);
                
                // Проверка доступности порта
                if (!IsPortAvailable(_config.SourcePort))
                {
                    throw new InvalidOperationException($"Порт {_config.SourcePort} уже занят другим процессом");
                }
                
                var builder = WebApplication.CreateBuilder();
                
                // Регистрируем Config в DI
                builder.Services.AddSingleton(_config);
                builder.Services.AddHttpClient();
                
                var app = builder.Build();
                
                // Настраиваем endpoints
                ConfigureEndpoints(app);
                
                // Запускаем веб-сервер на указанном порту
                app.Urls.Add($"http://*:{_config.SourcePort}");
                _logger.LogInformation("Веб-сервер настроен на порт {Port}", _config.SourcePort);
                
                await app.RunAsync(stoppingToken);
                
                _logger.LogInformation("Служба успешно запущена на порту {Port}, перенаправление на {TargetHost}:{TargetPort}", 
                    _config.SourcePort, 
                    _config.TargetHost,
                    _config.TargetPort);
                
                while (!stoppingToken.IsCancellationRequested)
                {
                    await Task.Delay(1000, stoppingToken);
                }
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Критическая ошибка в службе");
                _hostLifetime.StopApplication();
                throw;
            }
        }

        private bool IsPortAvailable(int port)
        {
            try
            {
                using var socket = new TcpListener(System.Net.IPAddress.Loopback, port);
                socket.Start();
                socket.Stop();
                return true;
            }
            catch
            {
                return false;
            }
        }

        private void ConfigureEndpoints(WebApplication app)
        {
            // Конфигурация endpoints
            app.MapPost("/document", async (HttpContext context) =>
            {
                var logger = app.Services.GetRequiredService<ILogger<Program>>();
                var config = app.Services.GetRequiredService<Config>();
                var targetUrl = $"http://{config.TargetHost}:{config.TargetPort}/document";
                var client = app.Services.GetRequiredService<IHttpClientFactory>().CreateClient();

                try
                {
                    var stream = new MemoryStream();
                    await context.Request.Body.CopyToAsync(stream);
                    stream.Position = 0;
                    var requestBody = new StreamReader(stream).ReadToEnd();
                    logger.LogInformation($"Тело запроса: {requestBody}");

                    var content = new StringContent(requestBody, Encoding.UTF8, "application/json");
                    var response = await client.PostAsync(targetUrl, content);

                    context.Response.StatusCode = (int)response.StatusCode;
                    await response.Content.CopyToAsync(context.Response.Body);
                }
                catch (Exception ex)
                {
                    logger.LogError(ex, "Ошибка при обработке запроса");
                    context.Response.StatusCode = StatusCodes.Status500InternalServerError;
                }
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
                    if (newConfig != null)
                    {
                        var configService = app.Services.GetRequiredService<Config>();
                        configService.SourcePort = newConfig.SourcePort;
                        configService.TargetPort = newConfig.TargetPort;
                        configService.TargetHost = newConfig.TargetHost;

                        SaveConfig(newConfig);

                        return Results.Ok("Settings saved. Service will be restarted.");
                    }
                    return Results.BadRequest("Invalid configuration");
                }
                catch (Exception ex)
                {
                    return Results.BadRequest(ex.Message);
                }
            });
        }
    }

    public class Program
    {
        public static async Task Main(string[] args)
        {
            Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

            if (args.Length > 0)
            {
                switch (args[0].ToLower())
                {
                    case "install":
                        await WindowsServiceInstaller.Install();
                        return;
                    case "uninstall":
                        await WindowsServiceInstaller.Uninstall();
                        return;
                    case "start":
                        await WindowsServiceInstaller.Start();
                        return;
                    case "stop":
                        await WindowsServiceInstaller.Stop();
                        return;
                }
            }

            var builder = WebApplication.CreateBuilder(args);
            
            builder.Services.AddSingleton<Config>(_ => new Config 
            {
                SourcePort = 2579,
                TargetPort = 2578,
                TargetHost = "localhost"
            });
            
            builder.Services.AddHostedService<WindowsBackgroundService>();
            builder.Services.AddHttpClient();

            builder.Host.UseWindowsService(options =>
            {
                options.ServiceName = "cto_csharp_proxyfmu";
            });

            builder.Logging.AddEventLog(settings =>
            {
                settings.SourceName = "CTO CSharp ProxyFMU";
            });

            builder.Logging.AddConsole()
                .SetMinimumLevel(LogLevel.Information);

            var app = builder.Build();

            app.UseStaticFiles();
            app.UseDefaultFiles();

            app.MapPost("/document", async (HttpContext context) =>
            {
                var logger = app.Services.GetRequiredService<ILogger<Program>>();
                var config = app.Services.GetRequiredService<Config>();
                var targetUrl = $"http://{config.TargetHost}:{config.TargetPort}/document";
                var client = app.Services.GetRequiredService<IHttpClientFactory>().CreateClient();

                try
                {
                    var stream = new MemoryStream();
                    await context.Request.Body.CopyToAsync(stream);
                    stream.Position = 0;
                    var requestBody = new StreamReader(stream).ReadToEnd();
                    logger.LogInformation($"Тело запроса: {requestBody}");

                    var content = new StringContent(requestBody, Encoding.UTF8, "application/json");
                    var response = await client.PostAsync(targetUrl, content);

                    context.Response.StatusCode = (int)response.StatusCode;
                    await response.Content.CopyToAsync(context.Response.Body);
                }
                catch (Exception ex)
                {
                    logger.LogError(ex, "Ошибка при обработке запроса");
                    context.Response.StatusCode = StatusCodes.Status500InternalServerError;
                }
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
                    if (newConfig != null)
                    {
                        var configService = app.Services.GetRequiredService<Config>();
                        configService.SourcePort = newConfig.SourcePort;
                        configService.TargetPort = newConfig.TargetPort;
                        configService.TargetHost = newConfig.TargetHost;

                        SaveConfig(newConfig);

                        return Results.Ok("Settings saved. Service will be restarted.");
                    }
                    return Results.BadRequest("Invalid configuration");
                }
                catch (Exception ex)
                {
                    return Results.BadRequest(ex.Message);
                }
            });

            await app.RunAsync();
        }

        public static void SaveConfig(Config config)
        {
            var configPath = GetConfigPath();
            var jsonString = JsonSerializer.Serialize(config, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(configPath, jsonString);
        }

        private static string GetConfigPath()
        {
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            var appDir = Path.Combine(appData, "CTO_CSHARP", "ProxyFMU");
            Directory.CreateDirectory(appDir);
            return Path.Combine(appDir, "ctocsharp_proxyfmu_config.json");
        }
    }

    public static class WindowsServiceInstaller
    {
        private const string ServiceName = "cto_csharp_proxyfmu";

        public static async Task Install()
        {
            try 
            {
                var exePath = Process.GetCurrentProcess().MainModule?.FileName;
                
                // Подробное логирование пути к исполняемому файлу
                Console.WriteLine("=== Debug Information ===");
                Console.WriteLine($"Current executable path: {exePath}");
                Console.WriteLine($"File exists: {File.Exists(exePath)}");
                Console.WriteLine($"Current directory: {Environment.CurrentDirectory}");
                
                // Формируем команду
                var command = $"create {ServiceName} binPath=\"{exePath}\" start=auto DisplayName=\"CTO CSharp Proxy FMU Service\" obj=LocalSystem";
                
                // Выводим полную команду
                Console.WriteLine("\n=== Command Information ===");
                Console.WriteLine($"Full command that will be executed: sc {command}");
                Console.WriteLine("===========================\n");
                
                var result = await ProcessHelper.RunCommand("sc", command);
                Console.WriteLine($"Installation result: {result}");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Failed to install service: {ex.Message}");
                Console.WriteLine($"Full error: {ex}");
                throw;
            }
        }

        public static async Task Uninstall()
        {
            using var sc = new ServiceController(ServiceName);
            var command = $"delete {ServiceName}";
            await ProcessHelper.RunCommand("sc", command);
            Console.WriteLine("Service uninstalled successfully");
        }

        public static async Task Start()
        {
            try 
            {
                Console.WriteLine("\n=== Service Start Debug Information ===");
                
                // Получаем информацию о службе
                using var sc = new ServiceController(ServiceName);
                Console.WriteLine($"Service name: {ServiceName}");
                Console.WriteLine($"Service status: {sc.Status}");
                
                // Получаем путь к исполняемому файлу
                var exePath = Assembly.GetExecutingAssembly().Location;
                Console.WriteLine($"Current assembly location: {exePath}");
                
                // Получаем путь через Process
                var processPath = Process.GetCurrentProcess().MainModule?.FileName;
                Console.WriteLine($"Current process path: {processPath}");
                
                // Проверяем существование файлов
                Console.WriteLine($"Assembly file exists: {File.Exists(exePath)}");
                Console.WriteLine($"Process file exists: {processPath != null && File.Exists(processPath)}");
                
                // Получаем текущую директорию
                Console.WriteLine($"Current directory: {Environment.CurrentDirectory}");
                
                // Получаем конфигурацию службы
                var configCommand = $"qc {ServiceName}";
                Console.WriteLine($"\nQuerying service configuration: sc {configCommand}");
                var configResult = await ProcessHelper.RunCommand("sc", configCommand);
                Console.WriteLine($"Service configuration:\n{configResult}");
                
                // Пытаемся запустить службу
                Console.WriteLine("\nTrying to start service...");
                var startCommand = $"start {ServiceName}";
                var result = await ProcessHelper.RunCommand("sc", startCommand);
                Console.WriteLine($"Start command result: {result}");
                
                // Ждем запуска службы
                Console.WriteLine("Waiting for service to start...");
                sc.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(30));
                Console.WriteLine($"Final service status: {sc.Status}");
                
                Console.WriteLine("===================================\n");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"\nFailed to start service: {ex.Message}");
                Console.WriteLine($"Full error details: {ex}");
                throw;
            }
        }

        public static async Task Stop()
        {
            using var sc = new ServiceController(ServiceName);
            var command = $"stop {ServiceName}";
            await ProcessHelper.RunCommand("sc", command);
            Console.WriteLine("Service stopped successfully");
        }
    }

    public static class ProcessHelper
    {
        public static async Task<string> RunCommand(string command, string arguments)
        {
            Console.WriteLine("\n=== Process Execution Details ===");
            Console.WriteLine($"Command: {command}");
            Console.WriteLine($"Arguments: {arguments}");
            
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = command,
                    Arguments = arguments,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    StandardOutputEncoding = Encoding.GetEncoding(866)
                }
            };

            var output = new StringBuilder();
            var error = new StringBuilder();

            process.OutputDataReceived += (sender, e) => 
            {
                if (e.Data != null) 
                {
                    output.AppendLine(e.Data);
                    Console.WriteLine($"Output: {e.Data}");
                }
            };
            process.ErrorDataReceived += (sender, e) => 
            {
                if (e.Data != null) 
                {
                    error.AppendLine(e.Data);
                    Console.WriteLine($"Error: {e.Data}");
                }
            };

            process.Start();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            await process.WaitForExitAsync();

            Console.WriteLine($"Process exit code: {process.ExitCode}");
            Console.WriteLine("===============================\n");

            if (process.ExitCode != 0)
            {
                throw new Exception(
                    $"Command failed with exit code {process.ExitCode}. " +
                    $"Output: {output} " +
                    $"Error: {error}");
            }

            return output.ToString();
        }
    }
}
