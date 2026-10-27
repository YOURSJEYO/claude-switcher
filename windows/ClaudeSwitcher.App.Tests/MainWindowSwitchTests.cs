using System.IO;
using System.Reflection;
using System.Text;
using System.Text.Json.Nodes;
using System.Windows.Threading;
using ClaudeSwitcher.App.Models;
using ClaudeSwitcher.App.Services;
using ClaudeSwitcher.App.ViewModels;
using Xunit;

namespace ClaudeSwitcher.App.Tests;

[Collection("WPF core integration")]
public sealed class MainWindowSwitchTests
{
    [Fact]
    public Task SwitchAsync_FailedFreshCheckRetainsFourteenNewRowsAndCompletedTarget() =>
        OnUnshownWindowAsync(async (window, fixture) =>
        {
            var failed = JsonNode.Parse(CoreResultParserTests.DetailJson("dns", "fail", true, false))!.AsObject();
            failed["success"] = false;
            failed["code"] = "blocked";
            failed["message"] = "fresh blocked check";
            fixture.WriteProducer(CoreResultParserTests.SwitchJson(), failed.ToJsonString(), checkExit: 1);

            await InvokeAsync(window, "SwitchAsync", "B");

            var state = State(window);
            Assert.Equal(UiStatus.Blocked, state.Status);
            Assert.Equal("切换后检查未通过", state.StatusText);
            Assert.Equal("B", state.CurrentAccount);
            Assert.Equal("completed", state.TransactionPhase);
            Assert.Equal(CoreResultParser.RequiredCheckIds, state.Checks.Select(row => row.Id));
            Assert.Equal(CheckVisualState.Failed, state.Checks.Single(row => row.Id == "dns").VisualState);
            Assert.Contains("fresh blocked check", state.Banner, StringComparison.Ordinal);
            Assert.True(state.CanRefresh);
            Assert.True(state.CanFix);
            Assert.False(state.CanSwitch);
            Assert.False(state.CanLaunch);
        });

    [Fact]
    public Task SwitchAsync_RunningPartialResultRemainsExplicitlyRunning() =>
        OnUnshownWindowAsync(async (window, fixture) =>
        {
            fixture.WriteProducer(CoreResultParserTests.SwitchJson(success: false, phase: "running", current: "A"), "{}", switchExit: 2);

            await InvokeAsync(window, "SwitchAsync", "B");

            var state = State(window);
            Assert.Equal(UiStatus.Running, state.Status);
            Assert.Equal("A", state.CurrentAccount);
            Assert.NotEqual("—", state.ActiveOperationId);
            Assert.NotEqual("—", state.TransactionPhase);
            Assert.True(state.CanRefresh);
            Assert.False(state.CanFix);
            Assert.False(state.CanSwitch);
            Assert.False(state.CanLaunch);
        });

    [Fact]
    public Task SwitchAsync_MalformedFreshCheckCannotKeepPreviousGreenRows() =>
        OnUnshownWindowAsync(async (window, fixture) =>
        {
            fixture.WriteProducer(CoreResultParserTests.SwitchJson(), "not-json");

            await InvokeAsync(window, "SwitchAsync", "B");

            var state = State(window);
            Assert.Equal("B", state.CurrentAccount);
            Assert.Equal("completed", state.TransactionPhase);
            Assert.All(state.Checks, row => Assert.Equal(CheckVisualState.Pending, row.VisualState));
            Assert.False(state.CanSwitch);
            Assert.False(state.CanLaunch);
        });

    [Fact]
    public Task RefreshAsync_StatusTimeoutIsUnavailableAndCannotAuthorizeMutation() =>
        OnUnshownWindowAsync(async (window, fixture) =>
        {
            fixture.WriteProducer(CoreResultParserTests.SwitchJson(), "{}");
            SetClient(window, fixture.CreateClient(TimeSpan.FromMilliseconds(150)));

            await InvokeAsync(window, "RefreshFromCoreAsync");

            var state = State(window);
            Assert.Equal(UiStatus.Blocked, state.Status);
            Assert.Equal("状态不可用", state.StatusText);
            Assert.Contains("超时", state.Banner, StringComparison.Ordinal);
            Assert.Equal("—", state.ActiveOperationId);
            Assert.True(state.CanRefresh);
            Assert.False(state.CanFix);
            Assert.False(state.CanSwitch);
            Assert.False(state.CanLaunch);
        });

    private static async Task OnUnshownWindowAsync(Func<MainWindow, SyntheticUiProducer, Task> action)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            var dispatcher = Dispatcher.CurrentDispatcher;
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(dispatcher));
            dispatcher.InvokeAsync(async () =>
            {
                MainWindow? window = null;
                try
                {
                    using var fixture = new SyntheticUiProducer();
                    window = new MainWindow();
                    Assert.False(window.IsLoaded);
                    Assert.False(window.IsVisible);
                    SetClient(window, fixture.CreateClient());
                    var previous = CoreResultParser.Parse(CoreResultParserTests.DetailJson(), 0,
                        CoreCommand.CheckDetail, CoreResultParserTests.TestOperationId);
                    typeof(MainWindow).GetField("_state", BindingFlags.Instance | BindingFlags.NonPublic)!
                        .SetValue(window, MainWindowState.Initial.ApplyCheck(previous) with { CurrentAccount = "A" });

                    await action(window, fixture);

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
                    dispatcher.InvokeShutdown();
                }
            });
            Dispatcher.Run();
        }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        await completion.Task.WaitAsync(TimeSpan.FromSeconds(25));
    }

    private static MainWindowState State(MainWindow window) =>
        (MainWindowState)typeof(MainWindow).GetField("_state", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(window)!;

    private static void SetClient(MainWindow window, CoreClient client) =>
        typeof(MainWindow).GetField("_client", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(window, client);

    private static Task InvokeAsync(MainWindow window, string name, params object[] arguments) =>
        (Task)typeof(MainWindow).GetMethod(name, BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(window, arguments)!;

    private sealed class SyntheticUiProducer : IDisposable
    {
        private readonly string _root = Path.Combine(Path.GetTempPath(), "claude-ui-regression-" + Guid.NewGuid().ToString("N"));
        private string CorePath => Path.Combine(_root, "synthetic-producer.ps1");

        public SyntheticUiProducer() => Directory.CreateDirectory(_root);

        public CoreClient CreateClient(TimeSpan? queryTimeout = null) => new(CorePath,
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
            queryTimeout: queryTimeout ?? TimeSpan.FromSeconds(10));

        public void WriteProducer(string switchJson, string checkJson, int checkExit = 0, int switchExit = 0)
        {
            var script = $$"""
                $ErrorActionPreference = 'Stop'
                [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
                $requestArgs = @($args)
                $id = $requestArgs[[Array]::IndexOf($requestArgs, '-OperationId') + 1]
                if ($requestArgs[0] -eq 'status') { Start-Sleep -Seconds 10; exit 0 }
                if ($requestArgs[0] -eq 'switch') {
                    $json = '{{Escape(switchJson)}}'
                    $exitCode = {{switchExit}}
                } elseif ($requestArgs[0] -eq 'checkdetail') {
                    $json = '{{Escape(checkJson)}}'
                    $exitCode = {{checkExit}}
                } else { throw 'Unexpected synthetic command' }
                [Console]::Write($json.Replace('{{CoreResultParserTests.TestOperationId:D}}', $id))
                exit $exitCode
                """;
            File.WriteAllText(CorePath, script, new UTF8Encoding(true));
        }

        public void Dispose() => Directory.Delete(_root, recursive: true);
        private static string Escape(string value) => value.Replace("'", "''", StringComparison.Ordinal);
    }
}
