using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using ClaudeSwitcher.App.ViewModels;
using ClaudeSwitcher.App.Models;
using ClaudeSwitcher.App.Services;
using Xunit;

namespace ClaudeSwitcher.App.Tests;

[Collection("WPF core integration")]
public sealed class SetupConfigurationEntryTests
{
    [Fact]
    public void CanConfigureAllowsSetupRequiredAndFixableStatesOnly()
    {
        Assert.True(MainWindowState.Initial.SetupRequired().CanConfigure);
        Assert.True(MainWindowState.Initial.Fail("blocked").CanConfigure);
        var healthy = MainWindowState.Initial with { Status = UiStatus.Ready, CanFix = true };
        Assert.True(healthy.CanConfigure);
        Assert.False(MainWindowState.Initial.Running("running").CanConfigure);
        Assert.False((MainWindowState.Initial with
        {
            Status = UiStatus.RecoveryRequired,
            CanFix = false
        }).CanConfigure);
    }

    [Fact]
    public async Task ConfigureButtonIsAvailableForRetryButNotRunningOrRecovery()
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            var dispatcher = Dispatcher.CurrentDispatcher;
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(dispatcher));
            dispatcher.InvokeAsync(() =>
            {
                MainWindow? window = null;
                try
                {
                    window = new MainWindow();
                    Assert.False(window.IsLoaded);
                    Assert.False(window.IsVisible);
                    var button = Assert.IsType<Button>(window.FindName("ConfigureButton"));

                    SetState(window, MainWindowState.Initial.SetupRequired());
                    Assert.Equal(Visibility.Visible, button.Visibility);
                    Assert.True(button.IsEnabled);

                    SetState(window, MainWindowState.Initial.Fail("partial setup") with { CanFix = true });
                    Assert.Equal(Visibility.Visible, button.Visibility);
                    Assert.True(button.IsEnabled);

                    SetState(window, MainWindowState.Initial.Running("running"));
                    Assert.Equal(Visibility.Collapsed, button.Visibility);
                    Assert.False(button.IsEnabled);

                    SetState(window, MainWindowState.Initial with
                    {
                        Status = UiStatus.RecoveryRequired,
                        CanFix = false
                    });
                    Assert.Equal(Visibility.Collapsed, button.Visibility);
                    Assert.False(button.IsEnabled);
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
        await completion.Task.WaitAsync(TimeSpan.FromSeconds(15));
    }

    [Fact]
    public async Task DetachedSetupKeepsMutationActionsBlockedUntilPendingResultResolves()
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
                    window = new MainWindow();
                    using var fixture = new SyntheticCoreProducer();
                    typeof(MainWindow).GetField("_client", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
                        .SetValue(window, fixture.Client);
                    SetState(window, MainWindowState.Initial.ApplyCheck(CoreResultParser.Parse(CoreResultParserTests.DetailJson(), 0, CoreCommand.CheckDetail, CoreResultParserTests.TestOperationId)));
                    var pending = new TaskCompletionSource<SetupApplyRunResult>(TaskCreationOptions.RunContinuationsAsynchronously);
                    var keepRunning = typeof(MainWindow).GetMethod(
                        "KeepSetupMutationGuardAsync",
                        System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!;
                    var guard = (Task)keepRunning.Invoke(window, [pending.Task])!;

                    Assert.Equal(UiStatus.Running, GetState(window).Status);
                    Assert.False(Button(window, "ConfigureButton").IsEnabled);
                    Assert.False(Button(window, "RefreshButton").IsEnabled);
                    Assert.False(Button(window, "FixButton").IsEnabled);
                    Assert.False(Button(window, "SwitchAButton").IsEnabled);
                    Assert.False(Button(window, "SwitchBButton").IsEnabled);

                    pending.SetResult(new SetupApplyRunResult(
                        SetupApplyOutcome.Completed,
                        new SetupApplyResult(true, "completed", "ok", "complete"),
                        0,
                        Retryable: false));
                    await guard.WaitAsync(TimeSpan.FromSeconds(10));
                    Assert.False((bool)typeof(MainWindow).GetField("_setupMutationPending", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.GetValue(window)!);
                    Assert.True(GetState(window).CanConfigure);
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
        await completion.Task.WaitAsync(TimeSpan.FromSeconds(15));
    }
    [Fact]
    public async Task UnexpectedPendingApplyFailureKeepsMutationActionsBlocked()
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
                    window = new MainWindow();
                    using var fixture = new SyntheticCoreProducer();
                    typeof(MainWindow).GetField("_client", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
                        .SetValue(window, fixture.Client);
                    SetState(window, MainWindowState.Initial.ApplyCheck(CoreResultParser.Parse(CoreResultParserTests.DetailJson(), 0, CoreCommand.CheckDetail, CoreResultParserTests.TestOperationId)));
                    var failed = Task.FromException<SetupApplyRunResult>(
                        new InvalidOperationException("synthetic observation failure"));
                    var keepRunning = typeof(MainWindow).GetMethod(
                        "KeepSetupMutationGuardAsync",
                        System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!;
                    var guard = (Task)keepRunning.Invoke(window, [failed])!;
                    await guard.WaitAsync(TimeSpan.FromSeconds(10));

                    Assert.Equal(UiStatus.Running, GetState(window).Status);
                    Assert.True((bool)typeof(MainWindow).GetField("_setupMutationPending", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.GetValue(window)!);
                    Assert.False(Button(window, "RefreshButton").IsEnabled);
                    Assert.False(Button(window, "FixButton").IsEnabled);
                    Assert.False(Button(window, "SwitchAButton").IsEnabled);
                    Assert.False(Button(window, "SwitchBButton").IsEnabled);
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
        await completion.Task.WaitAsync(TimeSpan.FromSeconds(15));
    }

    private sealed class SyntheticCoreProducer : IDisposable
    {
        private readonly string _root = Path.Combine(Path.GetTempPath(), "claude-setup-guard-" + Guid.NewGuid().ToString("N"));

        public SyntheticCoreProducer()
        {
            Directory.CreateDirectory(_root);
            var path = Path.Combine(_root, "core.ps1");
            var script = "$ErrorActionPreference = 'Stop'`n" +
                "$id = @($args)[[Array]::IndexOf(@($args), '-OperationId') + 1]`n" +
                "if ($args[0] -eq 'status') { $json = '" + CoreResultParserTests.StatusJson().Replace("'", "''", StringComparison.Ordinal) + "' }`n" +
                "elseif ($args[0] -eq 'checkdetail') { $json = '" + CoreResultParserTests.DetailJson().Replace("'", "''", StringComparison.Ordinal) + "' }`n" +
                "else { throw 'Unexpected synthetic command' }`n" +
                "[Console]::Write($json.Replace('" + CoreResultParserTests.TestOperationId.ToString("D") + "', $id))`n";
            File.WriteAllText(path, script, new System.Text.UTF8Encoding(true));
            Client = new CoreClient(
                path,
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"));
        }

        public CoreClient Client { get; }

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
    }
    private static MainWindowState GetState(MainWindow window) =>
        (MainWindowState)typeof(MainWindow).GetField("_state", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.GetValue(window)!;

    private static Button Button(MainWindow window, string name) =>
        (Button)window.FindName(name);
    private static void SetState(MainWindow window, MainWindowState state)
    {
        typeof(MainWindow).GetField("_state", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
            .SetValue(window, state);
        typeof(MainWindow).GetMethod("RenderState", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
            .Invoke(window, null);
    }
}