using System.Diagnostics;
using System.Text;

namespace ClaudeSwitcher.Admin;

public sealed record FixedProcessCall(string FilePath, IReadOnlyList<string> Arguments, TimeSpan Timeout);
public sealed record FixedProcessResult(int ExitCode, string StandardOutput, string StandardError);

public interface IFixedProcessRunner
{
    FixedProcessResult Run(string filePath, IReadOnlyList<string> arguments, TimeSpan timeout);
}

public sealed class FixedProcessRunner : IFixedProcessRunner
{
    private const int MaxOutputCharacters = 1024 * 1024;

    public FixedProcessResult Run(string filePath, IReadOnlyList<string> arguments, TimeSpan timeout)
    {
        if (!Path.IsPathFullyQualified(filePath)) { throw new ArgumentException("A fixed absolute executable is required.", nameof(filePath)); }
        var start = new ProcessStartInfo(filePath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System)
        };
        foreach (var argument in arguments) { start.ArgumentList.Add(argument); }
        start.Environment["PSModulePath"] = Path.Combine(start.WorkingDirectory, "WindowsPowerShell", "v1.0", "Modules");
        start.Environment["PATH"] = start.WorkingDirectory;
        using var process = Process.Start(start) ?? throw new InvalidOperationException("System operation did not start.");
        var stdout = DrainAsync(process.StandardOutput);
        var stderr = DrainAsync(process.StandardError);
        if (!process.WaitForExit(checked((int)timeout.TotalMilliseconds)))
        {
            process.Kill(entireProcessTree: true);
            if (!process.WaitForExit(5000)) { throw new TimeoutException("System operation did not stop."); }
            ObserveDrains(stdout, stderr);
            throw new TimeoutException("System operation timed out.");
        }

        ObserveDrains(stdout, stderr);
        return new FixedProcessResult(process.ExitCode, stdout.GetAwaiter().GetResult(), stderr.GetAwaiter().GetResult());
    }

    private static void ObserveDrains(Task<string> stdout, Task<string> stderr)
    {
        if (!Task.WaitAll([stdout, stderr], 5000)) { throw new TimeoutException("System operation streams did not close."); }
    }

    private static async Task<string> DrainAsync(StreamReader reader)
    {
        var buffer = new char[4096];
        var result = new StringBuilder();
        int count;
        while ((count = await reader.ReadAsync(buffer.AsMemory()).ConfigureAwait(false)) != 0)
        {
            var remaining = MaxOutputCharacters - result.Length;
            if (remaining > 0) { result.Append(buffer, 0, Math.Min(remaining, count)); }
        }

        return result.ToString();
    }
}
