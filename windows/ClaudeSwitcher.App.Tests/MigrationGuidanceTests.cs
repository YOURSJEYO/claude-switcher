using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Threading;
using ClaudeSwitcher.App.Services;
using ClaudeSwitcher.App.ViewModels;
using Xunit;

namespace ClaudeSwitcher.App.Tests;

[Collection("WPF core integration")]
public sealed class MigrationGuidanceTests
{
    [Fact]
    public async Task Refresh_LegacyCoreRequiresConfigurationWithoutRunningChecksOrMutations()
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            var dispatcher = Dispatcher.CurrentDispatcher;
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(dispatcher));
            dispatcher.InvokeAsync(async () =>
            {
                MainWindow? window = null;
                string? root = null;
                try
                {
                    root = Path.Combine(Path.GetTempPath(), "claude-legacy-core-ui-" + Guid.NewGuid().ToString("N"));
                    Directory.CreateDirectory(root);
                    var corePath = Path.Combine(root, "legacy-core.ps1");
                    var callsPath = Path.Combine(root, "calls.txt");
                    var snapshotPath = Path.Combine(root, "accounts", "A", "snapshot.txt");
                    Directory.CreateDirectory(Path.GetDirectoryName(snapshotPath)!);
                    File.WriteAllText(snapshotPath, "synthetic account snapshot");
                    // Legacy scripts dispatch on $args[0], ignoring the newer -Json switch.
                    File.WriteAllText(corePath, $$"""
                        $ErrorActionPreference = 'Stop'
                        [IO.File]::AppendAllText('{{callsPath.Replace("'", "''", StringComparison.Ordinal)}}', $args[0] + [Environment]::NewLine)
                        switch ($args[0]) {
                            'status' { 'current=A hasA=1 hasB=0' }
                            default { throw 'Legacy checks and mutations must not run' }
                        }
                        """, new UTF8Encoding(true));
                    var originalCore = File.ReadAllBytes(corePath);

                    window = new MainWindow();
                    Assert.False(window.IsLoaded);
                    Assert.False(window.IsVisible);
                    typeof(MainWindow).GetField("_client", BindingFlags.Instance | BindingFlags.NonPublic)!
                        .SetValue(window, new CoreClient(
                            corePath,
                            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe")));

                    await (Task)typeof(MainWindow).GetMethod("RefreshFromCoreAsync", BindingFlags.Instance | BindingFlags.NonPublic)!
                        .Invoke(window, null)!;

                    var state = (MainWindowState)typeof(MainWindow).GetField("_state", BindingFlags.Instance | BindingFlags.NonPublic)!
                        .GetValue(window)!;
                    Assert.Equal(UiStatus.SetupRequired, state.Status);
                    Assert.Contains("旧版脚本核心", state.Banner, StringComparison.Ordinal);
                    Assert.Contains("配置安装", state.Banner, StringComparison.Ordinal);
                    Assert.True(state.CanConfigure);
                    Assert.False(state.CanFix);
                    Assert.False(state.CanSwitch);
                    Assert.False(state.CanLaunch);
                    Assert.All(state.Checks, check => Assert.Equal(CheckVisualState.Pending, check.VisualState));
                    var configure = (System.Windows.Controls.Button)window.FindName("ConfigureButton");
                    Assert.Equal(System.Windows.Visibility.Visible, configure.Visibility);
                    Assert.True(configure.IsEnabled);
                    Assert.False(((System.Windows.Controls.Button)window.FindName("FixButton")).IsEnabled);
                    Assert.False(((System.Windows.Controls.Button)window.FindName("SwitchAButton")).IsEnabled);
                    Assert.Equal(["status"], File.ReadAllLines(callsPath));
                    Assert.Equal(originalCore, File.ReadAllBytes(corePath));
                    Assert.Equal("synthetic account snapshot", File.ReadAllText(snapshotPath));
                    completion.SetResult();
                }
                catch (Exception exception)
                {
                    completion.SetException(exception);
                }
                finally
                {
                    window?.Close();
                    if (root is not null && Directory.Exists(root))
                    {
                        Directory.Delete(root, recursive: true);
                    }

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
    public async Task Fix_MigrationRequiredShowsCoreGuidanceAndConfigurationAction()
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            var dispatcher = Dispatcher.CurrentDispatcher;
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(dispatcher));
            dispatcher.InvokeAsync(async () =>
            {
                MainWindow? window = null;
                string? root = null;
                try
                {
                    root = Path.Combine(Path.GetTempPath(), "claude-migration-ui-" + Guid.NewGuid().ToString("N"));
                    Directory.CreateDirectory(root);
                    var corePath = Path.Combine(root, "migration-core.ps1");
                    File.WriteAllText(corePath, """
                        $ErrorActionPreference = 'Stop'
                        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
                        $idIndex = [Array]::IndexOf($args, '-OperationId')
                        $id = $args[$idIndex + 1]
                        [Console]::Write('{"schemaVersion":1,"operationId":"' + $id + '","command":"fix","success":false,"code":"migration-required","message":"检测到旧版保镖任务，请运行配置向导完成受保护迁移。"}')
                        exit 5
                        """, new UTF8Encoding(true));

                    window = new MainWindow();
                    typeof(MainWindow).GetField("_state", BindingFlags.Instance | BindingFlags.NonPublic)!
                        .SetValue(window, MainWindowState.Initial.Fail("blocked"));
                    typeof(MainWindow).GetField("_client", BindingFlags.Instance | BindingFlags.NonPublic)!
                        .SetValue(window, new CoreClient(
                            corePath,
                            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe")));

                    await (Task)typeof(MainWindow).GetMethod("RunFixAsync", BindingFlags.Instance | BindingFlags.NonPublic)!
                        .Invoke(window, null)!;

                    var state = (MainWindowState)typeof(MainWindow).GetField("_state", BindingFlags.Instance | BindingFlags.NonPublic)!
                        .GetValue(window)!;
                    Assert.Contains("受保护迁移", state.Banner, StringComparison.Ordinal);
                    Assert.True(state.CanConfigure);
                    Assert.False(state.CanLaunch);
                    completion.SetResult();
                }
                catch (Exception exception)
                {
                    completion.SetException(exception);
                }
                finally
                {
                    window?.Close();
                    if (root is not null && Directory.Exists(root))
                    {
                        Directory.Delete(root, recursive: true);
                    }

                    dispatcher.InvokeShutdown();
                }
            });
            Dispatcher.Run();
        }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        await completion.Task.WaitAsync(TimeSpan.FromSeconds(15));
    }
}
