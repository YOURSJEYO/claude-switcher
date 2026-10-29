using System.Diagnostics;
using System.IO;
using System.Text;
using ClaudeSwitcher.App.Models;
using ClaudeSwitcher.App.Services;
using Xunit;

namespace ClaudeSwitcher.App.Tests;

public sealed class CoreClientTests
{
    private static readonly Guid OperationId = CoreResultParserTests.TestOperationId;

    [Theory]
    [InlineData("A")]
    [InlineData("B")]
    public async Task RunAsync_SendsOnlyAllowlistedSwitchTarget(string target)
    {
        using var fixture = new CoreFixture();
        fixture.WriteSuccess(CoreCommand.Switch, target);

        var result = await fixture.Client.RunAsync(CoreCommand.Switch, target, OperationId, CancellationToken.None);

        Assert.True(result.Result!.IsCompletedSwitch);
        var invocation = Assert.Single(fixture.Invocations);
        Assert.Equal(
            [
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                fixture.CorePath,
                "switch",
                target,
                "-Json",
                "-OperationId",
                OperationId.ToString("D")
            ],
            invocation.Arguments);
        Assert.DoesNotContain(invocation.Arguments, argument => argument.Contains("cmd.exe", StringComparison.OrdinalIgnoreCase));
        Assert.EndsWith("powershell.exe", fixture.Client.PowerShellPath, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(Path.GetFullPath(fixture.CorePath), fixture.Client.CorePath);
    }

    [Theory]
    [InlineData("C")]
    [InlineData("a")]
    [InlineData("")]
    [InlineData(null)]
    public async Task RunAsync_RejectsInvalidSwitchTargetsWithoutStartingProcess(string? target)
    {
        using var fixture = new CoreFixture();
        fixture.WriteSuccess(CoreCommand.Switch, "A");

        var error = await Assert.ThrowsAsync<CoreProtocolException>(() =>
            fixture.Client.RunAsync(CoreCommand.Switch, target, OperationId, CancellationToken.None));

        Assert.Equal(CoreProtocolError.InvalidTarget, error.Error);
        Assert.Empty(fixture.Invocations);
    }

    [Fact]
    public async Task RunAsync_ReportsSetupRequiredWhenCoreIsMissing()
    {
        using var fixture = new CoreFixture(createCore: false);

        var error = await Assert.ThrowsAsync<CoreClientException>(() =>
            fixture.Client.RunAsync(CoreCommand.CheckDetail, null, OperationId, CancellationToken.None));

        Assert.Equal(CoreClientError.SetupRequired, error.Error);
        Assert.Empty(fixture.Invocations);
    }

    [Fact]
    public async Task RunAsync_ReportsSetupRequiredWhenPowerShellHostIsMissing()
    {
        using var fixture = new CoreFixture();
        var client = fixture.CreateClient(powerShellPath: Path.Combine(fixture.Root, "missing-powershell.exe"));

        var error = await Assert.ThrowsAsync<CoreClientException>(() =>
            client.RunAsync(CoreCommand.Status, null, OperationId, CancellationToken.None));

        Assert.Equal(CoreClientError.SetupRequired, error.Error);
        Assert.Empty(fixture.Invocations);
    }

    [Theory]
    [InlineData("current=none hasA=0 hasB=0\r\n")]
    [InlineData("current=A hasA=1 hasB=0\r\n")]
    [InlineData("current=B hasA=1 hasB=1\n")]
    [InlineData("current=A hasA=0 hasB=1")]
    public async Task RunAsync_LegacyTextStatusRequiresSetupInsteadOfJsonParsing(string output)
    {
        using var fixture = new CoreFixture();
        fixture.WriteRaw(output, exitCode: 0);

        var error = await Assert.ThrowsAsync<CoreClientException>(() =>
            fixture.Client.RunAsync(CoreCommand.Status, null, OperationId, CancellationToken.None));

        Assert.Equal(CoreClientError.SetupRequired, error.Error);
        Assert.Contains("旧版脚本核心", error.Message, StringComparison.Ordinal);
        Assert.Single(fixture.Invocations);
        Assert.False(fixture.LastProcessKilled);
        Assert.Equal(CoreProtocolError.InvalidJson, Assert.Throws<CoreProtocolException>(() =>
            CoreResultParser.Parse(output, 0, CoreCommand.Status, OperationId)).Error);
    }

    [Theory]
    [InlineData("warning\r\ncurrent=A hasA=1 hasB=1\r\n")]
    [InlineData("current=A hasA=1 hasB=1\r\n{}")]
    [InlineData("current=A hasA=1 hasB=1\r\ncurrent=A hasA=1 hasB=1\r\n")]
    [InlineData("current=C hasA=1 hasB=1\r\n")]
    [InlineData("current=A hasA=true hasB=1\r\n")]
    [InlineData("not json")]
    public async Task RunAsync_DoesNotMistakeOtherInvalidStatusOutputForLegacyCore(string output)
    {
        using var fixture = new CoreFixture();
        fixture.WriteRaw(output, exitCode: 0);

        var error = await Assert.ThrowsAsync<CoreProtocolException>(() =>
            fixture.Client.RunAsync(CoreCommand.Status, null, OperationId, CancellationToken.None));

        Assert.Equal(CoreProtocolError.InvalidJson, error.Error);
        Assert.Null(error.PartialResult);
    }

    [Fact]
    public async Task RunAsync_NonZeroLegacyTextStatusRemainsAProcessFailure()
    {
        using var fixture = new CoreFixture();
        fixture.WriteRaw("current=A hasA=1 hasB=1\r\n", exitCode: 7);

        var error = await Assert.ThrowsAsync<CoreProtocolException>(() =>
            fixture.Client.RunAsync(CoreCommand.Status, null, OperationId, CancellationToken.None));

        Assert.Equal(CoreProtocolError.ProcessFailed, error.Error);
        Assert.Equal(7, error.ExitCode);
    }

    [Theory]
    [InlineData(CoreCommand.CheckDetail, null)]
    [InlineData(CoreCommand.Fix, null)]
    [InlineData(CoreCommand.Switch, "A")]
    public async Task RunAsync_LegacyDetectionIsRestrictedToReadOnlyStatus(CoreCommand command, string? target)
    {
        using var fixture = new CoreFixture();
        fixture.WriteRaw("current=A hasA=1 hasB=1\r\n", exitCode: 0);

        var error = await Assert.ThrowsAsync<CoreProtocolException>(() =>
            fixture.Client.RunAsync(command, target, OperationId, CancellationToken.None));

        Assert.Equal(CoreProtocolError.InvalidJson, error.Error);
        Assert.Null(error.PartialResult);
    }

    [Fact]
    public async Task RunAsync_DecodesUtf8ChineseOutput()
    {
        using var fixture = new CoreFixture();
        fixture.WriteSuccess(CoreCommand.CheckDetail, null, message: "中文消息");

        var result = await fixture.Client.RunAsync(CoreCommand.CheckDetail, null, OperationId, CancellationToken.None);

        Assert.Equal("中文消息", result.Result!.Message);
    }

    [Fact]
    public async Task RunAsync_RejectsOutputBeyondLimit()
    {
        using var fixture = new CoreFixture();
        fixture.WriteRaw(new string('x', 2048), exitCode: 0);
        var client = fixture.CreateClient(maxOutputBytes: 1024);

        var error = await Assert.ThrowsAsync<CoreClientException>(() =>
            client.RunAsync(CoreCommand.CheckDetail, null, OperationId, CancellationToken.None));

        Assert.Equal(CoreClientError.OutputTooLarge, error.Error);
    }

    [Theory]
    [InlineData(CoreCommand.Switch, "B")]
    [InlineData(CoreCommand.Fix, null)]
    [InlineData(CoreCommand.CheckDetail, null)]
    public async Task RunAsync_PipeFillingOutputDrainsBothStreamsBeforeReportingLimit(CoreCommand command, string? target)
    {
        using var fixture = new CoreFixture();
        fixture.WritePipeFillingScript();
        var client = fixture.CreateClient(
            queryTimeout: TimeSpan.FromSeconds(12),
            switchSoftTimeout: TimeSpan.FromSeconds(12),
            fixSoftTimeout: TimeSpan.FromSeconds(12));
        var stopwatch = Stopwatch.StartNew();

        var error = await Assert.ThrowsAsync<CoreClientException>(() =>
            client.RunAsync(command, target, OperationId, CancellationToken.None)
                .WaitAsync(TimeSpan.FromSeconds(15)));

        Assert.Equal(CoreClientError.OutputTooLarge, error.Error);
        Assert.True(File.Exists(fixture.Marker("core-finished")), "Both 2 MiB streams must finish before the output-limit error is reported.");
        Assert.False(fixture.LastProcessKilled);
        Assert.True(stopwatch.Elapsed < TimeSpan.FromSeconds(15));
    }

    [Fact]
    public async Task RunAsync_PreservesNonZeroExitCodeForParserFailure()
    {
        using var fixture = new CoreFixture();
        fixture.WriteRaw("{}", exitCode: 7);

        var error = await Assert.ThrowsAsync<CoreProtocolException>(() =>
            fixture.Client.RunAsync(CoreCommand.CheckDetail, null, OperationId, CancellationToken.None));

        Assert.Equal(CoreProtocolError.ProcessFailed, error.Error);
        Assert.Equal(7, error.ExitCode);
    }

    [Fact]
    public async Task RunAsync_QueryCancellationKillsOnlyThatQueryProcess()
    {
        using var fixture = new CoreFixture();
        fixture.WriteSleepingScript();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(150));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            fixture.Client.RunAsync(CoreCommand.CheckDetail, null, OperationId, cancellation.Token));

        Assert.True(fixture.LastProcessKilled);
        Assert.Empty(fixture.MarkerFiles());
    }

    [Theory]
    [InlineData(CoreCommand.CheckDetail)]
    [InlineData(CoreCommand.Status)]
    public async Task RunAsync_QueryTimeoutKillsOnlyThatQueryProcess(CoreCommand command)
    {
        using var fixture = new CoreFixture();
        fixture.WriteSleepingScript();
        var client = fixture.CreateClient(queryTimeout: TimeSpan.FromMilliseconds(150));

        var error = await Assert.ThrowsAsync<CoreClientException>(() =>
            client.RunAsync(command, null, OperationId, CancellationToken.None));

        Assert.Equal(CoreClientError.QueryTimedOut, error.Error);
        Assert.True(fixture.LastProcessKilled);
        Assert.Empty(fixture.MarkerFiles());
    }

    [Fact]
    public async Task RunAsync_DefaultStatusTimeoutIsTenSeconds()
    {
        using var fixture = new CoreFixture();
        fixture.WriteSleepingScript();
        var killed = false;
        var client = new CoreClient(fixture.CorePath, fixture.PowerShellPath,
            processKilledObserver: () => killed = true);
        // A fallback cancellation keeps a regressed 90-second default bounded and
        // cleans up only this synthetic query process during the RED run.
        using var fallback = new CancellationTokenSource(TimeSpan.FromSeconds(14));
        var stopwatch = Stopwatch.StartNew();

        var error = await Assert.ThrowsAsync<CoreClientException>(() =>
            client.RunAsync(CoreCommand.Status, null, OperationId, fallback.Token));

        Assert.Equal(CoreClientError.QueryTimedOut, error.Error);
        Assert.InRange(stopwatch.Elapsed, TimeSpan.FromSeconds(9), TimeSpan.FromSeconds(14));
        Assert.True(killed);
        Assert.Empty(fixture.MarkerFiles());
    }

    [Fact]
    public async Task RunAsync_SwitchSoftTimeoutDoesNotKillOrAwaitCompletion()
    {
        using var fixture = new CoreFixture();
        fixture.WriteDelayedSuccess(CoreCommand.Switch, "B", milliseconds: 3000);
        var client = fixture.CreateClient(switchSoftTimeout: TimeSpan.FromMilliseconds(150));

        var result = await client.RunAsync(CoreCommand.Switch, "B", OperationId, CancellationToken.None);

        Assert.Equal(CoreClientOutcome.StillRunning, result.Outcome);
        Assert.False(fixture.LastProcessKilled);
        await fixture.WaitForMarkerAsync("core-finished");
        Assert.True(File.Exists(fixture.Marker("core-finished")));
    }

    [Theory]
    [InlineData(CoreCommand.Switch, "B")]
    [InlineData(CoreCommand.Fix, null)]
    public async Task RunAsync_SoftTimeoutKeepsDrainingBothStreamsUntilMutationExits(CoreCommand command, string? target)
    {
        using var fixture = new CoreFixture();
        fixture.WritePipeFillingScript(delayMilliseconds: 1000);
        var client = fixture.CreateClient(
            maxOutputBytes: 1024,
            switchSoftTimeout: TimeSpan.FromMilliseconds(150),
            fixSoftTimeout: TimeSpan.FromMilliseconds(150));

        var result = await client.RunAsync(command, target, OperationId, CancellationToken.None);

        Assert.Equal(CoreClientOutcome.StillRunning, result.Outcome);
        Assert.False(fixture.LastProcessKilled);
        await fixture.WaitForMarkerAsync("core-finished");
        Assert.True(File.Exists(fixture.Marker("core-finished")),
            "Returning StillRunning must not dispose the process pipes or interrupt a committing producer.");
    }

    [Fact]
    public async Task RunAsync_SwitchCancellationDoesNotKillOrAwaitCompletion()
    {
        using var fixture = new CoreFixture();
        fixture.WriteDelayedSuccess(CoreCommand.Switch, "B", milliseconds: 3000);
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(150));

        var result = await fixture.Client.RunAsync(CoreCommand.Switch, "B", OperationId, cancellation.Token);

        Assert.Equal(CoreClientOutcome.StillRunning, result.Outcome);
        Assert.False(fixture.LastProcessKilled);
        await fixture.WaitForMarkerAsync("core-finished");
        Assert.True(File.Exists(fixture.Marker("core-finished")));
    }

    [Fact]
    public async Task RunAsync_FixSoftTimeoutDoesNotKillOrAwaitCompletion()
    {
        using var fixture = new CoreFixture();
        fixture.WriteDelayedSuccess(CoreCommand.Fix, null, milliseconds: 3000);
        var client = fixture.CreateClient(fixSoftTimeout: TimeSpan.FromMilliseconds(150));

        var result = await client.RunAsync(CoreCommand.Fix, null, OperationId, CancellationToken.None);

        Assert.Equal(CoreClientOutcome.StillRunning, result.Outcome);
        Assert.False(fixture.LastProcessKilled);
        await fixture.WaitForMarkerAsync("core-finished");
    }

    private sealed class CoreFixture : IDisposable
    {
        private readonly string _systemPowerShell;
        private readonly List<CoreInvocation> _invocations = [];

        public CoreFixture(bool createCore = true)
        {
            Root = Path.Combine(Path.GetTempPath(), "claude-switcher-client-tests", Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Root);
            PowerShellPath = Path.Combine(Root, "powershell.exe");
            _systemPowerShell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell",
                "v1.0",
                "powershell.exe");
            File.Copy(_systemPowerShell, PowerShellPath);
            CorePath = Path.Combine(Root, "claude-switch.ps1");
            LogPath = Path.Combine(Root, "invocations.jsonl");
            if (createCore)
            {
                File.WriteAllText(CorePath, "# Fake core script is generated per test.", new UTF8Encoding(false));
            }

            Client = CreateClient();
        }

        public string Root { get; }
        public string PowerShellPath { get; }
        public string CorePath { get; }
        public string LogPath { get; }
        public CoreClient Client { get; }
        public IReadOnlyList<CoreInvocation> Invocations => _invocations;
        public bool LastProcessKilled { get; private set; }

        public CoreClient CreateClient(
            string? powerShellPath = null,
            int maxOutputBytes = 1024 * 1024,
            TimeSpan? queryTimeout = null,
            TimeSpan? switchSoftTimeout = null,
            TimeSpan? fixSoftTimeout = null)
        {
            return new CoreClient(
                corePath: CorePath,
                powerShellPath: powerShellPath ?? PowerShellPath,
                maxOutputBytes: maxOutputBytes,
                queryTimeout: queryTimeout ?? TimeSpan.FromSeconds(3),
                switchSoftTimeout: switchSoftTimeout ?? TimeSpan.FromSeconds(3),
                fixSoftTimeout: fixSoftTimeout ?? TimeSpan.FromSeconds(3),
                invocationObserver: invocation => _invocations.Add(invocation),
                processKilledObserver: () => LastProcessKilled = true);
        }

        public void WriteSuccess(CoreCommand command, string? target, string message = "synthetic") =>
            WriteScript(command, target, message, delayMilliseconds: 0, exitCode: 0, completed: true);

        public void WriteDelayedSuccess(CoreCommand command, string? target, int milliseconds) =>
            WriteScript(command, target, "synthetic", milliseconds, exitCode: 0, completed: true);

        public void WriteSleepingScript()
        {
            File.WriteAllText(CorePath, """
                $ErrorActionPreference = 'Stop'
                Start-Sleep -Seconds 30
                """, new UTF8Encoding(false));
        }

        public void WriteRaw(string stdout, int exitCode)
        {
            var encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(stdout));
            File.WriteAllText(CorePath, $$"""
                [Console]::OutputEncoding = [Text.Encoding]::UTF8
                $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{{encoded}}'))
                [Console]::Write($text)
                exit {{exitCode}}
                """, new UTF8Encoding(false));
        }

        public string Marker(string name) => Path.Combine(Root, name + ".marker");

        public void WritePipeFillingScript(int delayMilliseconds = 0)
        {
            // This synthetic producer exits itself on a stalled pipe so the RED run
            // cannot strand a child process. Only a fully drained producer writes the marker.
            File.WriteAllText(CorePath, $$"""
                $ErrorActionPreference = 'Stop'
                [Console]::OutputEncoding = [Text.Encoding]::UTF8
                Start-Sleep -Milliseconds {{delayMilliseconds}}
                Add-Type -TypeDefinition @'
                using System;
                using System.IO;
                using System.Threading;
                using System.Threading.Tasks;

                public static class SyntheticPipeProducer
                {
                    public static void Run(string marker)
                    {
                        var chunk = new string('x', 8192);
                        var stdout = Task.Run(() => Write(Console.Out, chunk));
                        var stderr = Task.Run(() => Write(Console.Error, chunk));
                        if (!Task.WaitAll(new[] { stdout, stderr }, TimeSpan.FromSeconds(5)))
                        {
                            Environment.Exit(91);
                        }

                        Thread.Sleep(250);
                        File.WriteAllText(marker, "both streams drained");
                    }

                    private static void Write(TextWriter writer, string chunk)
                    {
                        for (var index = 0; index < 256; index++)
                        {
                            writer.Write(chunk);
                        }

                        writer.Flush();
                    }
                }
                '@
                [SyntheticPipeProducer]::Run('{{Escape(Marker("core-finished"))}}')
                exit 0
                """, new UTF8Encoding(false));
        }

        public IEnumerable<string> MarkerFiles() => Directory.EnumerateFiles(Root, "*.marker");

        public async Task WaitForMarkerAsync(string name)
        {
            var path = Marker(name);
            var deadline = DateTime.UtcNow.AddSeconds(10);
            while (!File.Exists(path) && DateTime.UtcNow < deadline)
            {
                await Task.Delay(50);
            }
        }

        public void Dispose()
        {
            try
            {
                Directory.Delete(Root, recursive: true);
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }

        private void WriteScript(CoreCommand command, string? target, string message, int delayMilliseconds, int exitCode, bool completed)
        {
            var output = completed && command == CoreCommand.CheckDetail
                ? CoreResultParserTests.DetailJson()
                : command switch
                {
                    CoreCommand.Status => CoreResultParserTests.StatusJson(),
                    CoreCommand.Switch => CoreResultParserTests.SwitchJson(current: target!),
                    CoreCommand.Fix => $$"""{"schemaVersion":1,"operationId":"{{OperationId}}","command":"fix","success":true,"code":"ok","message":"synthetic"}""",
                    _ => throw new ArgumentOutOfRangeException(nameof(command))
                };

            if (command == CoreCommand.CheckDetail)
            {
                output = ReplaceJsonValue(output, "message", message);
            }

            var encodedOutput = Convert.ToBase64String(Encoding.UTF8.GetBytes(output));
            File.WriteAllText(CorePath, $$"""
                $ErrorActionPreference = 'Stop'
                $argsJson = ConvertTo-Json -InputObject @($args) -Compress
                [IO.File]::AppendAllText('{{Escape(LogPath)}}', $argsJson + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
                Start-Sleep -Milliseconds {{delayMilliseconds}}
                [IO.File]::WriteAllText('{{Escape(Marker("core-finished"))}}', 'done')
                [Console]::OutputEncoding = [Text.Encoding]::UTF8
                $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{{encodedOutput}}'))
                [Console]::Write($text)
                exit {{exitCode}}
                """, new UTF8Encoding(false));
        }

        private static string ReplaceJsonValue(string json, string field, string value)
        {
            var node = System.Text.Json.Nodes.JsonNode.Parse(json)!.AsObject();
            node[field] = value;
            return node.ToJsonString();
        }

        private static string Escape(string path) => path.Replace("'", "''", StringComparison.Ordinal);
    }
}
