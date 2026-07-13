using System.Diagnostics;

namespace CtoCSharpProxyFmu;

public static class WindowsServiceInstaller
{
    private const string ServiceName = "cto_csharp_proxyfmu";

    public static async Task InstallAsync()
    {
        var path = Environment.ProcessPath ?? AssemblyPath();
        var command = $"create {ServiceName} binPath= \"{path}\" start= auto DisplayName= \"CTO CSharp Proxy FMU\"";
        await ProcessHelper.RunAsync("sc.exe", command);
        Console.WriteLine("Служба установлена.");
    }

    public static async Task UninstallAsync()
    {
        await StopAsync();
        await ProcessHelper.RunAsync("sc.exe", $"delete {ServiceName}");
        Console.WriteLine("Служба удалена.");
    }

    public static async Task StartAsync()
    {
        await ProcessHelper.RunAsync("sc.exe", $"start {ServiceName}");
        Console.WriteLine("Служба запущена.");
    }

    public static async Task StopAsync()
    {
        try
        {
            await ProcessHelper.RunAsync("sc.exe", $"stop {ServiceName}");
            Console.WriteLine("Служба остановлена.");
        }
        catch
        {
            Console.WriteLine("Служба не запущена или уже остановлена.");
        }
    }

    public static async Task RestartAsync()
    {
        try
        {
            await ProcessHelper.RunAsync("sc.exe", $"stop {ServiceName}");
            await Task.Delay(1500);
        }
        catch
        {
        }

        await ProcessHelper.RunAsync("sc.exe", $"start {ServiceName}");
    }

    public static bool IsRunningAsService()
    {
        return !Environment.UserInteractive;
    }

    private static string AssemblyPath()
    {
        return Environment.ProcessPath ?? AppContext.BaseDirectory;
    }
}

public static class ProcessHelper
{
    public static async Task RunAsync(string fileName, string arguments)
    {
        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = fileName,
                Arguments = arguments,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            }
        };

        process.Start();
        var stdout = await process.StandardOutput.ReadToEndAsync();
        var stderr = await process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();

        if (process.ExitCode != 0)
        {
            var details = string.IsNullOrWhiteSpace(stderr) ? stdout : stderr;
            throw new InvalidOperationException($"Команда {fileName} {arguments} завершилась с кодом {process.ExitCode}: {details}");
        }
    }
}
