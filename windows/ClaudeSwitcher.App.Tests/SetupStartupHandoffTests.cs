using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using ClaudeSwitcher.App.Services;
using Xunit;

namespace ClaudeSwitcher.App.Tests;

[Collection("WPF core integration")]
public sealed class SetupStartupHandoffTests
{
    [Fact]
    public async Task DetachedStartupCreatesGuardedWindowBeforeLoadedCanRefresh()
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            var dispatcher = Dispatcher.CurrentDispatcher;
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(dispatcher));
            MainWindow? window = null;
            try
            {
                var pending = new TaskCompletionSource<SetupApplyRunResult>(TaskCreationOptions.RunContinuationsAsynchronously);
                var constructor = typeof(MainWindow).GetConstructor(
                    BindingFlags.Instance | BindingFlags.NonPublic, null,
                    [typeof(Task<SetupApplyRunResult>)], null);
                Assert.NotNull(constructor);
                window = (MainWindow)constructor.Invoke([pending.Task]);

                Assert.True((bool)typeof(MainWindow).GetField("_setupMutationPending", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(window)!);
                foreach (var name in new[] { "ConfigureButton", "RefreshButton", "FixButton", "SwitchAButton", "SwitchBButton" })
                {
                    Assert.False(Assert.IsType<Button>(window.FindName(name)).IsEnabled);
                }

                // Exercise the Loaded route without showing a window or querying real core state.
                window.RaiseEvent(new RoutedEventArgs(FrameworkElement.LoadedEvent));
                Assert.False(pending.Task.IsCompleted);
                Assert.Contains("配置", Assert.IsType<TextBlock>(window.FindName("BannerText")).Text);
                Assert.False(Assert.IsType<Button>(window.FindName("FixButton")).IsEnabled);
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
        }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        await completion.Task.WaitAsync(TimeSpan.FromSeconds(10));
    }
}
