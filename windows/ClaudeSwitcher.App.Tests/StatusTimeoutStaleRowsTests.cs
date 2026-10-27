using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Threading;
using ClaudeSwitcher.App.Models;
using ClaudeSwitcher.App.Services;
using ClaudeSwitcher.App.ViewModels;
using Xunit;

namespace ClaudeSwitcher.App.Tests;

[Collection("WPF core integration")]
public sealed class StatusTimeoutStaleRowsTests
{
    [Fact]
    public async Task RefreshTimeout_ClearsPreviouslyGreenRowsInUnshownWindow()
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
                    using var fixture = new TimeoutProducer();
                    window = new MainWindow();
                    SetField(window, "_client", fixture.Client);
                    var previous = CoreResultParser.Parse(
                        CoreResultParserTests.DetailJson(),
                        0,
                        CoreCommand.CheckDetail,
                        CoreResultParserTests.TestOperationId);
                    SetField(window, "_state", MainWindowState.Initial.ApplyCheck(previous));

                    await (Task)typeof(MainWindow)
                        .GetMethod("RefreshFromCoreAsync", BindingFlags.Instance | BindingFlags.NonPublic)!
                        .Invoke(window, null)!;

                    var state = (MainWindowState)typeof(MainWindow)
                        .GetField("_state", BindingFlags.Instance | BindingFlags.NonPublic)!
                        .GetValue(window)!;
                    Assert.Equal(UiStatus.Blocked, state.Status);
                    Assert.Equal("状态不可用", state.StatusText);
                    Assert.Equal(CoreResultParser.RequiredCheckIds, state.Checks.Select(row => row.Id));
                    Assert.All(state.Checks, row => Assert.Equal(CheckVisualState.Pending, row.VisualState));
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
        await completion.Task.WaitAsync(TimeSpan.FromSeconds(20));
    }

    private static void SetField(MainWindow window, string name, object value) =>
        typeof(MainWindow).GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(window, value);

    private sealed class TimeoutProducer : IDisposable
    {
        private readonly string _root = Path.Combine(Path.GetTempPath(), "claude-timeout-row-" + Guid.NewGuid().ToString("N"));

        public TimeoutProducer()
        {
            Directory.CreateDirectory(_root);
            var path = Path.Combine(_root, "producer.ps1");
            File.WriteAllText(path, "$ErrorActionPreference = 'Stop'\nStart-Sleep -Seconds 10\n", new UTF8Encoding(true));
            Client = new CoreClient(
                path,
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
                queryTimeout: TimeSpan.FromMilliseconds(150));
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
}
