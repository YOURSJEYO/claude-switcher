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
