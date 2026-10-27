using System.IO;
using System.Reflection;
using System.Text.Json.Nodes;
using System.Threading;
using ClaudeSwitcher.App.Models;
using ClaudeSwitcher.App.Services;
using ClaudeSwitcher.App.ViewModels;
using Xunit;

namespace ClaudeSwitcher.App.Tests;

[CollectionDefinition("WPF core integration", DisableParallelization = true)]
public sealed class WpfCoreIntegrationCollection
{
}

[Collection("WPF core integration")]
public sealed class MainWindowRefreshTests
{
    [Fact]
    public async Task FailedCheckDetailPartialRetainsFourteenRowsAndStatusWithoutLaunch()
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            MainWindow? window = null;
            try
            {
                var operationId = CoreResultParserTests.TestOperationId;
                var idleStatus = CoreResultParser.Parse(
                    CoreResultParserTests.StatusJson(current: "A"),
                    0,
                    CoreCommand.Status,
                    operationId);
                var failedCheckJson = JsonNode.Parse(
                    CoreResultParserTests.DetailJson("dns", "fail", blocking: true, canLaunch: false))!.AsObject();
                failedCheckJson["success"] = false;
                failedCheckJson["code"] = "blocked";
                failedCheckJson["message"] = "安全检查未通过";
                var failure = Assert.Throws<CoreProtocolException>(() =>
                    CoreResultParser.Parse(
                        failedCheckJson.ToJsonString(),
                        1,
                        CoreCommand.CheckDetail,
                        operationId));

                window = new MainWindow();
                Assert.False(window.IsLoaded);
                Assert.False(window.IsVisible);

                var stateField = typeof(MainWindow).GetField("_state", BindingFlags.Instance | BindingFlags.NonPublic);
                Assert.NotNull(stateField);
                stateField.SetValue(window, MainWindowState.Initial.Apply(statusResult: null, status: idleStatus));

                var applyFailure = typeof(MainWindow).GetMethod(
                    "ApplyRefreshFailure",
                    BindingFlags.Instance | BindingFlags.NonPublic);
                Assert.NotNull(applyFailure);
                applyFailure.Invoke(window, [idleStatus, failure]);

                var state = Assert.IsType<MainWindowState>(stateField.GetValue(window));
                Assert.Equal(CoreResultParser.RequiredCheckIds, state.Checks.Select(row => row.Id));
                Assert.Equal(UiStatus.Blocked, state.Status);
                Assert.Equal("A", state.CurrentAccount);
                Assert.False(state.CanSwitch);
                Assert.False(state.CanLaunch);
                Assert.Equal(CheckVisualState.Failed, state.Checks[7].VisualState);
                Assert.True(state.Checks[7].Blocking);
                Assert.False(window.IsLoaded);
                Assert.False(window.IsVisible);
                completion.SetResult();
            }
            catch (Exception exception)
            {
                completion.SetException(exception);
            }
            finally
            {
                window?.Close();
            }
        }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        await completion.Task.WaitAsync(TimeSpan.FromSeconds(15));
    }
}

[CollectionDefinition("Repository core integration", DisableParallelization = true)]
public sealed class RepositoryCoreIntegrationCollection
{
}

[Collection("Repository core integration")]
public sealed class RepositoryCoreIntegrationTests
{
    [Fact]
    public async Task FailedCheckDetailUsesRepositoryDispatcherThroughWindowsPowerShell51()
    {
        using var fixture = new RepositoryCoreFixture();
        var operationId = Guid.Parse("4d830879-6682-4a1b-9a42-55e3faa98684");
        var client = fixture.CreateClient();

        var error = await Assert.ThrowsAsync<CoreProtocolException>(() =>
            client.RunAsync(CoreCommand.CheckDetail, null, operationId, CancellationToken.None));

        Assert.Equal(CoreProtocolError.ProcessFailed, error.Error);
        Assert.Equal(1, error.ExitCode);
        var partial = Assert.IsType<CoreResult>(error.PartialResult);
        Assert.False(partial.Success);
        Assert.False(partial.CanLaunch);
        Assert.Equal(CoreResultParser.RequiredCheckIds, partial.Checks.Select(check => check.Id));
        Assert.Equal(CheckStatus.Fail, partial.Checks[7].Status);
        Assert.True(partial.Checks[7].Blocking);
    }

    [Fact]
    public async Task WarningCheckDetailKeepsOnlyAllowlistedWarningsLaunchable()
    {
        using var fixture = new RepositoryCoreFixture();
        var operationId = Guid.Parse("582bd49f-b3f1-4784-98e5-d5eb53c9b0ea");
        var client = fixture.CreateClient();

        var run = await client.RunAsync(CoreCommand.CheckDetail, null, operationId, CancellationToken.None);

        Assert.True(run.IsCompleted);
        var result = Assert.IsType<CoreResult>(run.Result);
        Assert.True(result.Success);
        Assert.True(result.CanLaunch);
        Assert.Equal(CheckStatus.Warn, result.Checks.Single(check => check.Id == "ip_consistency").Status);
        Assert.All(result.Checks.Where(check => check.Id != "ip_consistency"), check => Assert.Equal(CheckStatus.Ok, check.Status));
    }

    [Fact]
    public async Task IdleStatusHasNoRecoveryOrActiveOperation()
    {
        using var fixture = new RepositoryCoreFixture();
        var operationId = Guid.Parse("9e7ba533-c76d-4c8a-b88e-491e0d0f826c");
        var client = fixture.CreateClient();

        var run = await client.RunAsync(CoreCommand.Status, null, operationId, CancellationToken.None);

        var result = Assert.IsType<CoreResult>(run.Result);
        Assert.True(result.Success);
        Assert.Equal("none", result.Current);
        Assert.Equal(OperationPhase.Idle, result.Phase);
        Assert.False(result.RecoveryRequired);
        Assert.Null(result.ActiveOperationId);
        Assert.Null(result.TransactionPhase);
    }


    [Fact]
    public async Task RecoveryStatusUsesCanonicalUnknownOperationSentinel()
    {
        using var fixture = new RepositoryCoreFixture();
        var operationId = Guid.Parse("6ed21ab8-9e66-44d3-8f43-1d25aa0c8904");
        var client = fixture.CreateClient();

        var error = await Assert.ThrowsAsync<CoreProtocolException>(() =>
            client.RunAsync(CoreCommand.Status, null, operationId, CancellationToken.None));

        Assert.Equal(CoreProtocolError.ProcessFailed, error.Error);
        Assert.Equal(3, error.ExitCode);
        var partial = Assert.IsType<CoreResult>(error.PartialResult);
        Assert.False(partial.Success);
        Assert.Equal("none", partial.Current);
        Assert.Equal(OperationPhase.RecoveryRequired, partial.Phase);
        Assert.True(partial.RecoveryRequired);
        Assert.Equal(Guid.Empty, partial.ActiveOperationId);
        Assert.Equal("unverified", partial.TransactionPhase);
    }
}

internal sealed class RepositoryCoreFixture : IDisposable
{
    private static readonly Guid FailedOperationId = Guid.Parse("4d830879-6682-4a1b-9a42-55e3faa98684");
    private static readonly Guid WarningOperationId = Guid.Parse("582bd49f-b3f1-4784-98e5-d5eb53c9b0ea");
    private static readonly Guid IdleOperationId = Guid.Parse("9e7ba533-c76d-4c8a-b88e-491e0d0f826c");
    private static readonly Guid RecoveryOperationId = Guid.Parse("6ed21ab8-9e66-44d3-8f43-1d25aa0c8904");

    public RepositoryCoreFixture()
    {
        Root = Path.Combine(Path.GetTempPath(), "claude-switcher-core-" + Guid.NewGuid().ToString("N"));
        Profile = Path.Combine(Root, "profile");
        AppData = Path.Combine(Root, "appdata");
        LocalAppData = Path.Combine(Root, "localappdata");
        Directory.CreateDirectory(Profile);
        Directory.CreateDirectory(AppData);
        Directory.CreateDirectory(LocalAppData);
        CorePath = Path.Combine(Root, "core-wrapper.ps1");
        WriteWrapper();
    }

    public string Root { get; }
    public string Profile { get; }
    public string AppData { get; }
    public string LocalAppData { get; }
    public string CorePath { get; }

    public CoreClient CreateClient() => new(
        CorePath,
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            "System32",
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe"),
        queryTimeout: TimeSpan.FromSeconds(30));

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

    private void WriteWrapper()
    {
        var repositoryCore = FindRepositoryCore();
        var stateRoot = Path.Combine(Profile, ".claude-switcher");
        var dataRoot = Path.Combine(AppData, "Claude");
        var script = $$"""
            $ErrorActionPreference = 'Stop'
            $requestArgs = @($args)
            $env:USERPROFILE = '{{Escape(Profile)}}'
            $env:APPDATA = '{{Escape(AppData)}}'
            $env:LOCALAPPDATA = '{{Escape(LocalAppData)}}'
            $core = '{{Escape(repositoryCore)}}'
            $stateRoot = '{{Escape(stateRoot)}}'
            $dataRoot = '{{Escape(dataRoot)}}'

            . $core
            $ErrorActionPreference = 'Stop'
            if (-not (Get-Command Invoke-CoreRequest -CommandType Function -ErrorAction SilentlyContinue)) {
                throw 'Repository Invoke-CoreRequest was not loaded.'
            }

            $requestCommand = $requestArgs[0]
            $requestTarget = if ($requestArgs.Count -gt 1 -and $requestArgs[1] -notlike '-*') { $requestArgs[1] } else { $null }
            $requestOperationId = if ($requestArgs -contains '-OperationId') { $requestArgs[[Array]::IndexOf($requestArgs, '-OperationId') + 1] } else { '' }
            $fixture = switch ($requestOperationId) {
                '{{FailedOperationId}}' { 'failed' }
                '{{WarningOperationId}}' { 'warning' }
                '{{IdleOperationId}}' { 'idle' }
                '{{RecoveryOperationId}}' { 'recovery' }
                default { throw 'Unexpected test operation ID.' }
            }
            if ($requestCommand -eq 'checkdetail' -and $fixture -notin @('failed', 'warning')) {
                throw 'Unexpected checkdetail fixture.'
            }
            if ($requestCommand -eq 'status' -and $fixture -notin @('idle', 'recovery')) {
                throw 'Unexpected status fixture.'
            }
            function New-CheckLines {
                param([hashtable]$Overrides = @{})
                $names = @(
                    '代理内核', 'TUN网卡', '出口IP', 'IP一致', '时区', '地区', 'IPv6',
                    'DNS', 'WebRTC', '保镖', '规则置顶', '客户端语言', 'ASN属性', '生态可达性'
                )
                foreach ($name in $names) {
                    $state = if ($Overrides.ContainsKey($name)) { $Overrides[$name] } else { 'ok:fixture' }
                    "$name=$state"
                }
            }

            New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
            if ($fixture -eq 'recovery') {
                [IO.File]::WriteAllText((Join-Path $stateRoot 'transaction.json'), '{bad json')
            } else {
                [IO.File]::Delete((Join-Path $stateRoot 'transaction.json'))
            }

            if ($requestCommand -eq 'checkdetail') {
                function Invoke-CheckDetail {
                    if ($fixture -eq 'failed') {
                        New-CheckLines @{ 'DNS' = 'fail:fixture' }
                    } elseif ($fixture -eq 'warning') {
                        New-CheckLines @{ 'IP一致' = 'warn:fixture' }
                    } else {
                        New-CheckLines
                    }
                }
            }

            $script:ProtocolExitCode = 0
            $result = Invoke-CoreRequest -Command $requestCommand -Target $requestTarget -OperationId $requestOperationId
            ConvertTo-Json -InputObject $result -Compress -Depth 8
            exit $script:ProtocolExitCode
            """;
        File.WriteAllText(CorePath, script, new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
    }

    private static string FindRepositoryCore()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            var candidate = Path.Combine(directory.FullName, "windows", "claude-switch.ps1");
            if (File.Exists(candidate))
            {
                return candidate;
            }

            directory = directory.Parent;
        }

        throw new DirectoryNotFoundException("Could not locate the repository core script.");
    }

    private static string Escape(string value) => value.Replace("'", "''", StringComparison.Ordinal);
}