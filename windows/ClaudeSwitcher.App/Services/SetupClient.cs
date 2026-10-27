using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;
using ClaudeSwitcher.App.Models;

namespace ClaudeSwitcher.App.Services;

public enum SetupClientError
{
    Unavailable,
    TimedOut,
    OutputTooLarge,
    StartFailed,
    Protocol,
    Busy
}

public enum SetupApplyOutcome
{
    Completed,
    StillRunning,
    Cancelled,
    PartialFailure
}

public sealed class SetupClientException : Exception
{
    public SetupClientException(SetupClientError error, string message, int? exitCode = null, Exception? innerException = null)
        : base(message, innerException)
    {
        Error = error;
        ExitCode = exitCode;
    }

    public SetupClientError Error { get; }
    public int? ExitCode { get; }
}

public sealed record SetupInvocation(string FileName, IReadOnlyList<string> Arguments);

public sealed record SetupApplyRunResult(
    SetupApplyOutcome Outcome,
    SetupApplyResult? Result,
    int? ExitCode,
    bool Retryable);

public sealed class SetupClient
{
    private static readonly TimeSpan ProcessExitGrace = TimeSpan.FromSeconds(2);

    private readonly object _applyGate = new();
    private Task<SetupApplyRunResult>? _pendingApply;

    public SetupClient(
        string installerPath,
        string powerShellPath,
        int maxOutputBytes = 1024 * 1024,
        TimeSpan? previewTimeout = null,
        TimeSpan? applySoftTimeout = null,
        Action<SetupInvocation>? invocationObserver = null,
        Action? processKilledObserver = null)
    {
        if (maxOutputBytes <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(maxOutputBytes));
        }

        InstallerPath = Path.GetFullPath(installerPath);
        PowerShellPath = Path.GetFullPath(powerShellPath);
        MaxOutputBytes = maxOutputBytes;
        PreviewTimeout = RequirePositive(previewTimeout ?? TimeSpan.FromSeconds(90), nameof(previewTimeout));
        ApplySoftTimeout = RequirePositive(applySoftTimeout ?? TimeSpan.FromMinutes(10), nameof(applySoftTimeout));
        InvocationObserver = invocationObserver;
        ProcessKilledObserver = processKilledObserver;
    }

    public string InstallerPath { get; }
    public string PowerShellPath { get; }
    public int MaxOutputBytes { get; }
    public TimeSpan PreviewTimeout { get; }
    public TimeSpan ApplySoftTimeout { get; }
    private Action<SetupInvocation>? InvocationObserver { get; }
    private Action? ProcessKilledObserver { get; }

    public async Task<SetupPreview> PreviewAsync(
        string proxyMode,
        string proxyGroup,
        CancellationToken cancellationToken)
    {
        ValidateProxySelection(proxyMode, proxyGroup);
        EnsureAvailable();
        cancellationToken.ThrowIfCancellationRequested();

        var arguments = new List<string>
        {
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            InstallerPath,
            "-NonInteractive",
            "-ProxyMode",
            proxyMode,
            "-ProxyGroup",
            proxyGroup,
            "-Preview",
            "-Json"
        };
        InvocationObserver?.Invoke(new SetupInvocation(PowerShellPath, arguments.AsReadOnly()));

        using var process = StartProcess(arguments);
        var stdout = new BoundedTextBuffer(MaxOutputBytes);
        var stderr = new BoundedTextBuffer(MaxOutputBytes);
        var stdoutTask = ReadBoundedAsync(process.StandardOutput, stdout);
        var stderrTask = ReadBoundedAsync(process.StandardError, stderr);
        var operation = WaitForExitAndDrainAsync(process, stdoutTask, stderrTask);

        try
        {
            await operation.WaitAsync(PreviewTimeout, cancellationToken).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            await KillQueryAsync(process, operation).ConfigureAwait(false);
            throw new SetupClientException(SetupClientError.TimedOut, "The setup preview timed out.");
        }
        catch (OperationCanceledException)
        {
            await KillQueryAsync(process, operation).ConfigureAwait(false);
            throw;
        }

        EnsureWithinOutputLimit(stdout, stderr);
        if (process.ExitCode != 0)
        {
            throw new SetupClientException(
                SetupClientError.Protocol,
                $"The setup preview exited with code {process.ExitCode}.",
                process.ExitCode);
        }

        SetupPreview preview;
        try
        {
            preview = SetupProtocolParser.ParsePreview(stdout.ToString());
        }
        catch (SetupProtocolException exception)
        {
            throw new SetupClientException(
                SetupClientError.Protocol,
                "The setup preview returned an invalid protocol result.",
                process.ExitCode,
                exception);
        }

        if (!string.Equals(preview.ProxyMode, proxyMode, StringComparison.Ordinal) ||
            !string.Equals(preview.ProxyGroup, proxyGroup, StringComparison.Ordinal))
        {
            throw new SetupClientException(
                SetupClientError.Protocol,
                "The setup preview returned a different proxy selection than requested.",
                process.ExitCode);
        }

        return preview;
    }

    public async Task<SetupApplyRunResult> ApplyAsync(SetupPreview reviewed, CancellationToken cancellationToken)
    {
        ValidateReviewedPreview(reviewed);
        EnsureAvailable();
        cancellationToken.ThrowIfCancellationRequested();

        var arguments = new List<string>
        {
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            InstallerPath,
            "-NonInteractive",
            "-ProxyMode",
            reviewed.ProxyMode,
            "-ProxyGroup",
            reviewed.ProxyGroup,
            "-Country",
            reviewed.Country,
            "-TimeZoneId",
            reviewed.TimeZoneId,
            "-Culture",
            reviewed.Culture,
            "-Json"
        };

        Task<SetupApplyRunResult> operation;
        lock (_applyGate)
        {
            if (_pendingApply is { IsCompleted: false })
            {
                throw new SetupClientException(SetupClientError.Busy, "A setup apply operation is already running.");
            }

            InvocationObserver?.Invoke(new SetupInvocation(PowerShellPath, arguments.AsReadOnly()));
            var process = StartProcess(arguments);
            operation = RunApplyProcessAsync(process);
            _pendingApply = operation;
        }

        try
        {
            return await operation.WaitAsync(ApplySoftTimeout).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            ObserveProcess(operation);
            return new SetupApplyRunResult(SetupApplyOutcome.StillRunning, null, null, Retryable: true);
        }
    }

    public async Task<SetupApplyRunResult> WaitForApplyAsync(TimeSpan timeout)
    {
        Task<SetupApplyRunResult> pending;
        lock (_applyGate)
        {
            pending = _pendingApply ??
                throw new InvalidOperationException("No setup apply operation has been started.");
        }

        return await pending.WaitAsync(timeout).ConfigureAwait(false);
    }

    private async Task<SetupApplyRunResult> RunApplyProcessAsync(Process process)
    {
        using (process)
        {
            var stdout = new BoundedTextBuffer(MaxOutputBytes);
            var stderr = new BoundedTextBuffer(MaxOutputBytes);
            try
            {
                await WaitForExitAndDrainAsync(
                        process,
                        ReadBoundedAsync(process.StandardOutput, stdout),
                        ReadBoundedAsync(process.StandardError, stderr))
                    .ConfigureAwait(false);
                EnsureWithinOutputLimit(stdout, stderr);
            }
            catch (SetupClientException)
            {
                throw;
            }
            catch (Exception exception) when (exception is IOException or InvalidOperationException)
            {
                throw new SetupClientException(
                    SetupClientError.StartFailed,
                    "The setup apply process could not be observed to completion.",
                    innerException: exception);
            }

            var exitCode = process.ExitCode;
            SetupApplyResult? result = null;
            try
            {
                result = SetupProtocolParser.ParseApply(stdout.ToString());
            }
            catch (SetupProtocolException exception)
            {
                if (exitCode == 4)
                {
                    return new SetupApplyRunResult(SetupApplyOutcome.Cancelled, null, exitCode, Retryable: true);
                }

                throw new SetupClientException(
                    SetupClientError.Protocol,
                    exitCode == 0
                        ? "The setup apply returned an invalid protocol result."
                        : $"The setup apply exited with code {exitCode} and an invalid protocol result.",
                    exitCode,
                    exception);
            }

            if (exitCode == 4)
            {
                return new SetupApplyRunResult(SetupApplyOutcome.Cancelled, result, exitCode, Retryable: true);
            }

            if (exitCode != 0 || !result.Success)
            {
                return new SetupApplyRunResult(
                    SetupApplyOutcome.PartialFailure,
                    result,
                    exitCode,
                    Retryable: true);
            }

            return new SetupApplyRunResult(SetupApplyOutcome.Completed, result, exitCode, Retryable: false);
        }
    }

    private void EnsureAvailable()
    {
        if (!File.Exists(InstallerPath))
        {
            throw new SetupClientException(SetupClientError.Unavailable, "The bundled setup installer is not available.");
        }

        if (!File.Exists(PowerShellPath))
        {
            throw new SetupClientException(SetupClientError.Unavailable, "Windows PowerShell 5.1 is not available.");
        }
    }

    private Process StartProcess(IReadOnlyList<string> arguments)
    {
        var process = new Process
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
            }
        };

        foreach (var argument in arguments)
        {
            process.StartInfo.ArgumentList.Add(argument);
        }

        try
        {
            if (!process.Start())
            {
                process.Dispose();
                throw new SetupClientException(SetupClientError.StartFailed, "Failed to start the setup process.");
            }

            return process;
        }
        catch (Exception exception) when (exception is Win32Exception or InvalidOperationException or PlatformNotSupportedException)
        {
            process.Dispose();
            throw new SetupClientException(SetupClientError.StartFailed, "Failed to start the setup process.", innerException: exception);
        }
    }

    private static async Task WaitForExitAndDrainAsync(Process process, Task stdoutTask, Task stderrTask)
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

    private static void EnsureWithinOutputLimit(BoundedTextBuffer stdout, BoundedTextBuffer stderr)
    {
        if (stdout.Exceeded || stderr.Exceeded)
        {
            throw new SetupClientException(SetupClientError.OutputTooLarge, "Setup output exceeded the configured limit.");
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

    private static void ValidateProxySelection(string proxyMode, string proxyGroup)
    {
        if (!SetupProtocolParser.ProxyModes.Contains(proxyMode, StringComparer.Ordinal))
        {
            throw new ArgumentException("The proxy mode is not allowlisted.", nameof(proxyMode));
        }

        if (proxyMode == "clash-verge")
        {
            if (string.IsNullOrWhiteSpace(proxyGroup))
            {
                throw new ArgumentException("The proxy group is required for clash-verge.", nameof(proxyGroup));
            }

            ValidateProxyGroup(proxyGroup);
            return;
        }

        if (proxyGroup.Length != 0)
        {
            throw new ArgumentException("The proxy group must be empty for non-Clash modes.", nameof(proxyGroup));
        }
    }

    private static void ValidateProxyGroup(string proxyGroup)
    {
        if (proxyGroup.Length > 128 ||
            !string.Equals(proxyGroup, proxyGroup.Trim(), StringComparison.Ordinal) ||
            proxyGroup.Any(char.IsControl) ||
            proxyGroup.Contains("..", StringComparison.Ordinal) ||
            proxyGroup.IndexOfAny([';', '`', '$', '"', '\'', '<', '>', '|', '&', '{', '}', '\\', '/']) >= 0)
        {
            throw new ArgumentException("The proxy group is invalid.", nameof(proxyGroup));
        }
    }

    private static void ValidateReviewedPreview(SetupPreview preview)
    {
        ValidateProxySelection(preview.ProxyMode, preview.ProxyGroup);
        if (preview.Country.Length != 2 || preview.Country == "CN" ||
            string.IsNullOrWhiteSpace(preview.TimeZoneId) ||
            string.IsNullOrWhiteSpace(preview.Culture))
        {
            throw new ArgumentException("The reviewed setup preview is invalid.", nameof(preview));
        }
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
