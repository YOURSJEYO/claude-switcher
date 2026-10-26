using System.ComponentModel;
using System.IO;
using System.Diagnostics;
using System.Text;
using ClaudeSwitcher.App.Models;

namespace ClaudeSwitcher.App.Services;

public enum CoreClientError
{
    SetupRequired,
    QueryTimedOut,
    OutputTooLarge,
    StartFailed
}

public enum CoreClientOutcome
{
    Completed,
    StillRunning
}

public sealed class CoreClientException : Exception
{
    public CoreClientException(CoreClientError error, string message, int? exitCode = null, Exception? innerException = null)
        : base(message, innerException)
    {
        Error = error;
        ExitCode = exitCode;
    }

    public CoreClientError Error { get; }
    public int? ExitCode { get; }
}

public sealed record CoreClientRunResult(CoreClientOutcome Outcome, CoreResult? Result)
{
    public bool IsCompleted => Outcome == CoreClientOutcome.Completed;
}

public sealed record CoreInvocation(IReadOnlyList<string> Arguments);

public sealed class CoreClient
{
    private static readonly TimeSpan ProcessExitGrace = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan StatusTimeout = TimeSpan.FromSeconds(10);

    public CoreClient(
        string corePath,
        string powerShellPath,
        int maxOutputBytes = 1024 * 1024,
        TimeSpan? queryTimeout = null,
        TimeSpan? switchSoftTimeout = null,
        TimeSpan? fixSoftTimeout = null,
        Action<CoreInvocation>? invocationObserver = null,
        Action? processKilledObserver = null)
    {
        if (maxOutputBytes <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(maxOutputBytes));
        }

        CorePath = Path.GetFullPath(corePath);
        PowerShellPath = Path.GetFullPath(powerShellPath);
        MaxOutputBytes = maxOutputBytes;
        QueryTimeout = RequirePositive(queryTimeout ?? TimeSpan.FromSeconds(90), nameof(queryTimeout));
        SwitchSoftTimeout = RequirePositive(switchSoftTimeout ?? TimeSpan.FromSeconds(120), nameof(switchSoftTimeout));
        FixSoftTimeout = RequirePositive(fixSoftTimeout ?? TimeSpan.FromSeconds(180), nameof(fixSoftTimeout));
        InvocationObserver = invocationObserver;
        ProcessKilledObserver = processKilledObserver;
    }

    public string CorePath { get; }
    public string PowerShellPath { get; }
    public int MaxOutputBytes { get; }
    public TimeSpan QueryTimeout { get; }
    public TimeSpan SwitchSoftTimeout { get; }
    public TimeSpan FixSoftTimeout { get; }
    private Action<CoreInvocation>? InvocationObserver { get; }
    private Action? ProcessKilledObserver { get; }

    public async Task<CoreClientRunResult> RunAsync(
        CoreCommand command,
        string? target,
        Guid operationId,
        CancellationToken cancellationToken)
    {
        ValidateTarget(command, target);
        if (operationId == Guid.Empty)
        {
            throw new ArgumentException("Operation ID must not be empty.", nameof(operationId));
        }

        if (!File.Exists(CorePath))
        {
            throw new CoreClientException(CoreClientError.SetupRequired, "The Claude switcher core is not configured.");
        }

        if (!File.Exists(PowerShellPath))
        {
            throw new CoreClientException(CoreClientError.SetupRequired, "Windows PowerShell 5.1 is not available.");
        }

        var arguments = BuildArguments(command, target, operationId);
        InvocationObserver?.Invoke(new CoreInvocation(arguments));

        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = PowerShellPath,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: false),
                StandardErrorEncoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: false)
            },
            EnableRaisingEvents = true
        };

        foreach (var argument in arguments)
        {
            process.StartInfo.ArgumentList.Add(argument);
        }

        try
        {
            if (!process.Start())
            {
                throw new CoreClientException(CoreClientError.StartFailed, "Failed to start the Claude switcher core.");
            }
        }
        catch (Exception exception) when (exception is Win32Exception or InvalidOperationException or PlatformNotSupportedException)
        {
            throw new CoreClientException(CoreClientError.StartFailed, "Failed to start the Claude switcher core.", innerException: exception);
        }

        var stdout = new BoundedTextBuffer(MaxOutputBytes);
        var stderr = new BoundedTextBuffer(MaxOutputBytes);
        var stdoutTask = ReadBoundedAsync(process.StandardOutput, stdout);
        var stderrTask = ReadBoundedAsync(process.StandardError, stderr);
        var operation = WaitForExitAndDrainAsync(process, stdoutTask, stderrTask);

        if (command is CoreCommand.Switch or CoreCommand.Fix)
        {
            var softTimeout = command == CoreCommand.Switch ? SwitchSoftTimeout : FixSoftTimeout;
            using var softTimeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            var completed = await Task.WhenAny(operation, Task.Delay(softTimeout, softTimeoutSource.Token)).ConfigureAwait(false);
            if (completed != operation)
            {
                softTimeoutSource.Cancel();
                ObserveProcess(operation);
                return new CoreClientRunResult(CoreClientOutcome.StillRunning, null);
            }
        }
        else
        {
            var queryTimeout = command == CoreCommand.Status && QueryTimeout > StatusTimeout
                ? StatusTimeout
                : QueryTimeout;
            using var timeoutSource = new CancellationTokenSource(queryTimeout);
            using var linkedSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutSource.Token);
            var completed = await Task.WhenAny(operation, Task.Delay(Timeout.InfiniteTimeSpan, linkedSource.Token)).ConfigureAwait(false);
            if (completed != operation)
            {
                await KillQueryAsync(process, operation).ConfigureAwait(false);
                cancellationToken.ThrowIfCancellationRequested();
                throw new CoreClientException(CoreClientError.QueryTimedOut, "The Claude switcher core query timed out.");
            }

            linkedSource.Cancel();
        }

        await operation.ConfigureAwait(false);

        if (stdout.Exceeded || stderr.Exceeded)
        {
            throw new CoreClientException(CoreClientError.OutputTooLarge, "Core output exceeded the configured limit.");
        }

        var exitCode = process.ExitCode;
        CoreResult parsed;
        try
        {
            parsed = CoreResultParser.Parse(stdout.ToString(), exitCode, command, operationId, target);
        }
        catch (CoreProtocolException exception) when (exitCode != 0 && exception.Error != CoreProtocolError.ProcessFailed)
        {
            throw new CoreProtocolException(
                CoreProtocolError.ProcessFailed,
                $"Core exited with code {exitCode}.",
                exitCode);
        }

        return new CoreClientRunResult(CoreClientOutcome.Completed, parsed);
    }

    private IReadOnlyList<string> BuildArguments(CoreCommand command, string? target, Guid operationId)
    {
        var arguments = new List<string>
        {
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File"
        };

        arguments.Add(CorePath);
        arguments.Add(command.ToWire());

        if (target is not null)
        {
            arguments.Add(target);
        }

        arguments.Add("-Json");
        arguments.Add("-OperationId");
        arguments.Add(operationId.ToString("D"));
        return arguments.AsReadOnly();
    }

    private static void ValidateTarget(CoreCommand command, string? target)
    {
        if (command == CoreCommand.Switch)
        {
            if (target is not ("A" or "B"))
            {
                throw new CoreProtocolException(CoreProtocolError.InvalidTarget, "Switch target must be A or B.");
            }
        }
        else if (target is not null)
        {
            throw new CoreProtocolException(CoreProtocolError.InvalidTarget, "Only switch accepts a target.");
        }
    }

    private static async Task WaitForExitAndDrainAsync(
        Process process,
        Task stdoutTask,
        Task stderrTask)
    {
        await process.WaitForExitAsync().ConfigureAwait(false);
        await Task.WhenAll(stdoutTask, stderrTask).ConfigureAwait(false);
    }

    private static async Task ReadBoundedAsync(StreamReader reader, BoundedTextBuffer buffer)
    {
        var chars = new char[4096];
        while (true)
        {
            var read = await reader.ReadAsync(chars.AsMemory()).ConfigureAwait(false);
            if (read == 0)
            {
                return;
            }

            buffer.Append(chars.AsSpan(0, read));
        }
    }

    private async Task KillQueryAsync(Process process, Task operation)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                ProcessKilledObserver?.Invoke();
            }
        }
        catch (InvalidOperationException)
        {
        }
        catch (Win32Exception)
        {
        }

        try
        {
            await operation.WaitAsync(ProcessExitGrace).ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is TimeoutException or OperationCanceledException)
        {
        }
    }

    private static void ObserveProcess(Task operation)
    {
        _ = operation.ContinueWith(
            static task => _ = task.Exception,
            CancellationToken.None,
            TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    private static TimeSpan RequirePositive(TimeSpan value, string parameterName) =>
        value > TimeSpan.Zero ? value : throw new ArgumentOutOfRangeException(parameterName);

    private sealed class BoundedTextBuffer
    {
        private readonly StringBuilder _builder = new();
        private readonly int _maxBytes;
        private int _bytes;

        public BoundedTextBuffer(int maxBytes)
        {
            _maxBytes = maxBytes;
        }

        public bool Exceeded { get; private set; }

        public void Append(ReadOnlySpan<char> value)
        {
            if (Exceeded)
            {
                return;
            }

            var bytes = Encoding.UTF8.GetByteCount(value);
            if (bytes > _maxBytes - _bytes)
            {
                Exceeded = true;
                return;
            }

            _bytes += bytes;
            _builder.Append(value);
        }

        public override string ToString() => _builder.ToString();
    }

}
