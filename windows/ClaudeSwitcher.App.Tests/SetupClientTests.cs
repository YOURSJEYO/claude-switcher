using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Text;
using ClaudeSwitcher.App.Models;
using ClaudeSwitcher.App.Services;
using Xunit;

namespace ClaudeSwitcher.App.Tests;

public sealed class SetupClientTests
{
    private const string PreviewJson = """{"schemaVersion":1,"success":true,"country":"JP","timeZoneId":"Tokyo Standard Time","culture":"ja-JP","proxyMode":"clash-verge","proxyGroup":"Synthetic Group"}""";
    private const string ApplyJson = """{"schemaVersion":1,"success":true,"stage":"completed","code":"ok","message":"configuration complete"}""";

    [Fact]
    public async Task Preview_NonzeroExitWithSuccessJsonIsRejected()
    {
        using var fixture = new SetupFixture(PreviewJson, exitCode: 3);
        var client = fixture.CreateClient();

        var exception = await Assert.ThrowsAsync<SetupClientException>(() =>
            client.PreviewAsync("clash-verge", "Synthetic Group", CancellationToken.None));

        Assert.Equal(SetupClientError.Protocol, exception.Error);
        Assert.Equal(3, exception.ExitCode);
    }

    [Fact]
    public async Task Preview_AllowsEmptyGroupForNonClashAndRejectsUnsafeOrOverlongGroup()
    {
        using var clashFixture = new SetupFixture(PreviewJson);
        var clashClient = clashFixture.CreateClient();

        await Assert.ThrowsAsync<ArgumentException>(() =>
            clashClient.PreviewAsync("clash-verge", "", CancellationToken.None));
        await Assert.ThrowsAsync<ArgumentException>(() =>
            clashClient.PreviewAsync("clash-verge", new string('g', 129), CancellationToken.None));
        await Assert.ThrowsAsync<ArgumentException>(() =>
            clashClient.PreviewAsync("clash-verge", "group;Write-Host", CancellationToken.None));
        await Assert.ThrowsAsync<ArgumentException>(() =>
            clashClient.PreviewAsync("clash-verge", "group/name", CancellationToken.None));

        using var nonClashFixture = new SetupFixture(
            """{"schemaVersion":1,"success":true,"country":"JP","timeZoneId":"Tokyo Standard Time","culture":"ja-JP","proxyMode":"sing-box","proxyGroup":""}""");
        var nonClash = await nonClashFixture.CreateClient()
            .PreviewAsync("sing-box", "", CancellationToken.None);
        Assert.Equal("JP", nonClash.Country);
        Assert.Equal("", nonClash.ProxyGroup);
    }

    [Fact]
    public async Task Preview_RejectsReturnedProxySelectionThatDiffersFromRequestedSelection()
    {
        using var fixture = new SetupFixture("""{"schemaVersion":1,"success":true,"country":"JP","timeZoneId":"Tokyo Standard Time","culture":"ja-JP","proxyMode":"sing-box","proxyGroup":""}""");
        var client = fixture.CreateClient();

        var exception = await Assert.ThrowsAsync<SetupClientException>(() =>
            client.PreviewAsync("clash-verge", "Synthetic Group", CancellationToken.None));

        Assert.Equal(SetupClientError.Protocol, exception.Error);
    }

    [Fact]
    public async Task Preview_RejectsNonClashSelectionWhenReturnedProxyFieldsDiffer()
    {
        using var fixture = new SetupFixture(PreviewJson);
        var client = fixture.CreateClient();

        var exception = await Assert.ThrowsAsync<SetupClientException>(() =>
            client.PreviewAsync("sing-box", "", CancellationToken.None));

        Assert.Equal(SetupClientError.Protocol, exception.Error);
    }
    [Fact]
    public async Task Preview_UsesFixedInstallerAndSystemPowerShellWithArgumentList()
    {
        using var fixture = new SetupFixture(PreviewJson);
        SetupInvocation? observed = null;
        var client = fixture.CreateClient(invocation => observed = invocation);

        var result = await client.PreviewAsync("clash-verge", "Synthetic Group", CancellationToken.None);

        Assert.Equal("JP", result.Country);
        Assert.NotNull(observed);
        Assert.Equal(fixture.PowerShellPath, observed.FileName);
        Assert.Equal(
            [
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                fixture.InstallerPath,
                "-NonInteractive",
                "-ProxyMode",
                "clash-verge",
                "-ProxyGroup",
                "Synthetic Group",
                "-Preview",
                "-Json"
            ],
            observed.Arguments);
    }

    [Fact]
    public async Task Apply_UsesOnlyReviewedValuesAndExplicitJsonContract()
    {
        using var fixture = new SetupFixture(ApplyJson);
        SetupInvocation? observed = null;
        var client = fixture.CreateClient(invocation => observed = invocation);
        var preview = SetupProtocolParser.ParsePreview(PreviewJson);

        var result = await client.ApplyAsync(preview, CancellationToken.None);

        Assert.True(result.Result?.Success);
        Assert.Equal("completed", result.Result?.Stage);
        Assert.NotNull(observed);
        Assert.Equal(
            [
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                fixture.InstallerPath,
                "-NonInteractive",
                "-ProxyMode",
                "clash-verge",
                "-ProxyGroup",
                "Synthetic Group",
                "-Country",
                "JP",
                "-TimeZoneId",
                "Tokyo Standard Time",
                "-Culture",
                "ja-JP",
                "-Json"
            ],
            observed.Arguments);
    }

    [Fact]
    public async Task Preview_DrainsBothSaturatedStreamsConcurrently()
    {
        using var fixture = new SetupFixture(PreviewJson, saturatedOutput: true);
        var client = fixture.CreateClient();

        var result = await client.PreviewAsync("clash-verge", "Synthetic Group", CancellationToken.None);

        Assert.Equal("JP", result.Country);
        Assert.Equal("stdout-complete", File.ReadAllText(fixture.StdoutMarker));
        Assert.Equal("stderr-complete", File.ReadAllText(fixture.StderrMarker));
    }

    [Fact]
    public async Task Preview_TimeoutKillsQueryProcess()
    {
        using var fixture = new SetupFixture("""{"schemaVersion":1,"success":true,"country":"JP","timeZoneId":"Tokyo Standard Time","culture":"ja-JP","proxyMode":"clash-verge","proxyGroup":"Synthetic Group"}""", sleepMilliseconds: 10000);
        var killed = 0;
        var client = fixture.CreateClient(previewTimeout: TimeSpan.FromMilliseconds(200), processKilled: () => Interlocked.Increment(ref killed));

        await Assert.ThrowsAsync<SetupClientException>(() =>
            client.PreviewAsync("clash-verge", "Synthetic Group", CancellationToken.None));

        Assert.Equal(1, killed);
    }

            [Fact]
    public async Task Apply_ConcurrentCallsStartOnlyOneMutationAndSecondReportsBusy()
    {
        using var fixture = new SetupFixture(ApplyJson, sleepMilliseconds: 300);
        var firstObserverEntered = new ManualResetEventSlim();
        var releaseFirstObserver = new ManualResetEventSlim();
        var started = 0;
        var client = fixture.CreateClient(_ =>
        {
            var count = Interlocked.Increment(ref started);
            if (count == 1)
            {
                firstObserverEntered.Set();
                releaseFirstObserver.Wait(TimeSpan.FromSeconds(2));
            }
            else
            {
                releaseFirstObserver.Set();
            }
        });
        var preview = SetupProtocolParser.ParsePreview(PreviewJson);

        var first = Task.Run(() => client.ApplyAsync(preview, CancellationToken.None));
        Assert.True(firstObserverEntered.Wait(TimeSpan.FromSeconds(2)));
        var second = client.ApplyAsync(preview, CancellationToken.None);

        var exception = await Assert.ThrowsAsync<SetupClientException>(() => second);
        releaseFirstObserver.Set();
        var completed = await first;

        Assert.Equal(SetupClientError.Busy, exception.Error);
        Assert.Equal(1, Volatile.Read(ref started));
        Assert.Equal(SetupApplyOutcome.Completed, completed.Outcome);
    }
[Fact]
    public async Task Apply_SoftTimeoutRetainsObserverAndDrainsOutputAfterMutationCompletes()
    {
        using var fixture = new SetupFixture(ApplyJson, sleepMilliseconds: 600, saturatedOutput: true);
        var killed = 0;
        var client = fixture.CreateClient(applySoftTimeout: TimeSpan.FromMilliseconds(100), processKilled: () => Interlocked.Increment(ref killed));
        var preview = SetupProtocolParser.ParsePreview(PreviewJson);

        var pending = await client.ApplyAsync(preview, CancellationToken.None);

        Assert.Equal(SetupApplyOutcome.StillRunning, pending.Outcome);
        Assert.Null(pending.Result);
        Assert.Equal(0, killed);
        var completed = await client.WaitForApplyAsync(TimeSpan.FromSeconds(10));
        Assert.Equal(SetupApplyOutcome.Completed, completed.Outcome);
        Assert.True(completed.Result?.Success);
        Assert.Equal("stdout-complete", File.ReadAllText(fixture.StdoutMarker));
        Assert.Equal("stderr-complete", File.ReadAllText(fixture.StderrMarker));
        Assert.Equal(0, killed);
    }

    [Fact]
    public async Task Apply_SecondCallAfterSoftTimeoutReportsBusyWithoutKillingPendingMutation()
    {
        using var fixture = new SetupFixture(ApplyJson, sleepMilliseconds: 700);
        var killed = 0;
        var started = 0;
        var client = fixture.CreateClient(
            invocationObserver: _ => Interlocked.Increment(ref started),
            applySoftTimeout: TimeSpan.FromMilliseconds(100),
            processKilled: () => Interlocked.Increment(ref killed));
        var preview = SetupProtocolParser.ParsePreview(PreviewJson);

        var pending = await client.ApplyAsync(preview, CancellationToken.None);
        var exception = await Assert.ThrowsAsync<SetupClientException>(() =>
            client.ApplyAsync(preview, CancellationToken.None));

        Assert.Equal(SetupApplyOutcome.StillRunning, pending.Outcome);
        Assert.Equal(SetupClientError.Busy, exception.Error);
        Assert.Equal(1, Volatile.Read(ref started));
        Assert.Equal(0, Volatile.Read(ref killed));

        var completed = await client.WaitForApplyAsync(TimeSpan.FromSeconds(10));
        Assert.Equal(SetupApplyOutcome.Completed, completed.Outcome);
        Assert.Equal(0, Volatile.Read(ref killed));
    }
    [Fact]
    public async Task Apply_ExitFourReportsUacCancelledAndRetryable()
    {
        using var fixture = new SetupFixture(
            """{"schemaVersion":1,"success":false,"stage":"elevation","code":"uac-cancelled","message":"UAC was cancelled"}""",
            exitCode: 4);
        var client = fixture.CreateClient();
        var preview = SetupProtocolParser.ParsePreview(PreviewJson);

        var result = await client.ApplyAsync(preview, CancellationToken.None);

        Assert.Equal(SetupApplyOutcome.Cancelled, result.Outcome);
        Assert.Equal(4, result.ExitCode);
        Assert.True(result.Retryable);
        Assert.Equal("uac-cancelled", result.Result?.Code);
    }

    [Fact]
    public async Task Apply_NonzeroPartialFailurePreservesStageCodeAndMessage()
    {
        using var fixture = new SetupFixture(
            """{"schemaVersion":1,"success":false,"stage":"timezone","code":"timezone-write-failed","message":"partial system configuration failed"}""",
            exitCode: 7);
        var client = fixture.CreateClient();
        var preview = SetupProtocolParser.ParsePreview(PreviewJson);

        var result = await client.ApplyAsync(preview, CancellationToken.None);

        Assert.Equal(SetupApplyOutcome.PartialFailure, result.Outcome);
        Assert.Equal(7, result.ExitCode);
        Assert.True(result.Retryable);
        Assert.Equal("timezone", result.Result?.Stage);
        Assert.Equal("timezone-write-failed", result.Result?.Code);
        Assert.Equal("partial system configuration failed", result.Result?.Message);
    }

    [Fact]
    public async Task Preview_RejectsUnsafeInputBeforeStartingProcess()
    {
        using var fixture = new SetupFixture(PreviewJson);
        var started = 0;
        var client = fixture.CreateClient(_ => Interlocked.Increment(ref started));

        await Assert.ThrowsAsync<ArgumentException>(() =>
            client.PreviewAsync("powershell", "Synthetic Group", CancellationToken.None));
        await Assert.ThrowsAsync<ArgumentException>(() =>
            client.PreviewAsync("clash-verge", "bad\u0001group", CancellationToken.None));

        Assert.Equal(0, started);
    }

    [Fact]
    public async Task MissingInstallerReportsUnavailableWithoutStartingProcess()
    {
        using var fixture = new SetupFixture(PreviewJson);
        File.Delete(fixture.InstallerPath);
        var started = 0;
        var client = fixture.CreateClient(_ => Interlocked.Increment(ref started));

        var exception = await Assert.ThrowsAsync<SetupClientException>(() =>
            client.PreviewAsync("clash-verge", "Synthetic Group", CancellationToken.None));

        Assert.Equal(SetupClientError.Unavailable, exception.Error);
        Assert.Equal(0, started);
    }

    private sealed class SetupFixture : IDisposable
    {
        private readonly string _root = Path.Combine(Path.GetTempPath(), "claude-setup-client-" + Guid.NewGuid().ToString("N"));

        public SetupFixture(string resultJson, int exitCode = 0, int sleepMilliseconds = 0, bool saturatedOutput = false)
        {
            Directory.CreateDirectory(_root);
            InstallerPath = Path.Combine(_root, "install.ps1");
            PowerShellPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
            StdoutMarker = Path.Combine(_root, "stdout.marker");
            StderrMarker = Path.Combine(_root, "stderr.marker");
            var jsonPath = Path.Combine(_root, "result.json");
            File.WriteAllText(jsonPath, resultJson, new UTF8Encoding(false));

            var stdoutBlock = saturatedOutput
                ? "$chunk = [string]::new([char]32, 8192); 1..48 | ForEach-Object { [Console]::Out.Write($chunk) }; [IO.File]::WriteAllText('"+ EscapePowerShell(StdoutMarker) + "', 'stdout-complete')\n"
                : "";
            var stderrBlock = saturatedOutput
                ? "$chunk = 'y' * 8192; 1..48 | ForEach-Object { [Console]::Error.Write($chunk) }; [IO.File]::WriteAllText('" + EscapePowerShell(StderrMarker) + "', 'stderr-complete')\n"
                : "";
            var script = "$ErrorActionPreference = 'Stop'\n" +
                stdoutBlock +
                stderrBlock +
                (sleepMilliseconds > 0 ? "Start-Sleep -Milliseconds " + sleepMilliseconds + "\n" : "") +
                "[Console]::Out.Write([IO.File]::ReadAllText('" + EscapePowerShell(jsonPath) + "'))\n" +
                "exit " + exitCode + "\n";
            File.WriteAllText(InstallerPath, script, new UTF8Encoding(true));
        }

        public string InstallerPath { get; }
        public string PowerShellPath { get; }
        public string StdoutMarker { get; }
        public string StderrMarker { get; }

        public SetupClient CreateClient(
            Action<SetupInvocation>? invocationObserver = null,
            TimeSpan? previewTimeout = null,
            TimeSpan? applySoftTimeout = null,
            Action? processKilled = null) =>
            new(
                InstallerPath,
                PowerShellPath,
                previewTimeout: previewTimeout,
                applySoftTimeout: applySoftTimeout,
                invocationObserver: invocationObserver,
                processKilledObserver: processKilled);

        public void Dispose()
        {
            try
            {
                Directory.Delete(_root, recursive: true);
            }
            catch (IOException)
            {
            }
        }

        private static string EscapePowerShell(string value) => value.Replace("'", "''", StringComparison.Ordinal);
    }
}
