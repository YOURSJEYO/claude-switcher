using System.IO;
using System.Windows.Threading;
using ClaudeSwitcher.App.Models;
using ClaudeSwitcher.App.Services;
using Xunit;

namespace ClaudeSwitcher.App.Tests;

[Collection("WPF core integration")]
public sealed class SetupWizardWindowTests
{
    [Fact]
    public async Task ReviewedStateCapturesNonNullPreviewBeforeApply()
    {
        await OnWizardAsync(window =>
        {
            var preview = new SetupPreview(
                "JP",
                "Tokyo Standard Time",
                "ja-JP",
                "auto",
                string.Empty,
                []);
            var state = SetupWizardState.Editing("auto", string.Empty).Reviewed(preview);
            Assert.NotNull(state.Preview);
            Assert.True(state.CanApply);
            Assert.Same(preview, state.Preview);
            Assert.False(window.IsLoaded);
            Assert.False(window.IsVisible);
            return Task.CompletedTask;
        });
    }

    [Theory]
    [InlineData(SetupApplyOutcome.Cancelled, SetupWizardPhase.Cancelled, false)]
    [InlineData(SetupApplyOutcome.PartialFailure, SetupWizardPhase.PartialFailure, false)]
    [InlineData(SetupApplyOutcome.Completed, SetupWizardPhase.Completed, true)]
    public async Task ApplyOutcomeIsShownWithoutAutoRetryOrAutoClose(
        SetupApplyOutcome outcome,
        SetupWizardPhase expectedPhase,
        bool completed)
    {
        await OnWizardAsync(window =>
        {
            var result = outcome == SetupApplyOutcome.Cancelled
                ? new SetupApplyRunResult(outcome, null, 4, Retryable: true)
                : outcome == SetupApplyOutcome.PartialFailure
                    ? new SetupApplyRunResult(outcome, new SetupApplyResult(false, "timezone", "write-failed", "partial"), 7, Retryable: true)
                    : new SetupApplyRunResult(outcome, new SetupApplyResult(true, "completed", "ok", "complete"), 0, Retryable: false);

            window.ApplyResultForTest(result);

            Assert.Equal(expectedPhase, window.State.Phase);
            Assert.Equal(completed, window.SetupCompleted);
            Assert.False(window.IsLoaded);
            Assert.False(window.IsVisible);
            if (!completed)
            {
                Assert.True(window.State.CanPreview);
                Assert.True(window.State.CanClose);
            }

            return Task.CompletedTask;
        });
    }

    [Fact]
    public async Task WaitAfterSoftTimeoutDetachesAfterBoundedPollsWithoutKillingOrRetrying()
    {
        await OnWizardAsync(async window =>
        {
            var neverCompletes = new TaskCompletionSource<SetupApplyRunResult>(TaskCreationOptions.RunContinuationsAsynchronously);
            window.StartDetachedWaitForTest(neverCompletes.Task);
            await WaitUntilAsync(() => window.State.Phase == SetupWizardPhase.Detached, TimeSpan.FromSeconds(40));

            Assert.True(window.State.CanClose);
            Assert.False(window.State.CanWait);
            Assert.False(window.State.CanApply);
            Assert.Equal(30, window.WaitPollCountForTest);
            Assert.Equal(1, window.ApplyInvocationCountForTest);
        });
    }
    [Fact]
    public async Task DetachedStateRendersCloseEnabledAndBlocksApply()
    {
        await OnWizardAsync(window =>
        {
            window.DetachForTest();

            var close = Assert.IsType<System.Windows.Controls.Button>(window.FindName("CloseButton"));
            var apply = Assert.IsType<System.Windows.Controls.Button>(window.FindName("ApplyButton"));
            Assert.Equal(SetupWizardPhase.Detached, window.State.Phase);
            Assert.True(close.IsEnabled);
            Assert.False(apply.IsEnabled);
            Assert.False(window.State.CanPreview);
            Assert.False(window.State.CanApply);
            return Task.CompletedTask;
        });
    }
    [Fact]
    public async Task WaitUnexpectedFailureDetachesWithoutRetryingOrKilling()
    {
        await OnWizardAsync(async window =>
        {
            var failed = Task.FromException<SetupApplyRunResult>(
                new InvalidOperationException("synthetic observation failure"));
            window.StartDetachedWaitForTest(failed);
            await WaitUntilAsync(
                () => window.State.Phase == SetupWizardPhase.Detached,
                TimeSpan.FromSeconds(5));

            Assert.True(window.State.CanClose);
            Assert.False(window.State.CanWait);
            Assert.False(window.State.CanApply);
            Assert.Equal(1, window.ApplyInvocationCountForTest);
            Assert.Contains("可能仍在运行", window.State.Message, StringComparison.Ordinal);
        });
    }

    private static async Task WaitUntilAsync(Func<bool> condition, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (!condition())
        {
            if (DateTime.UtcNow >= deadline)
            {
                throw new TimeoutException("Condition was not met.");
            }

            await Task.Delay(25);
        }
    }

    private static async Task OnWizardAsync(Func<SetupWizardWindow, Task> action)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            var dispatcher = Dispatcher.CurrentDispatcher;
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(dispatcher));
            dispatcher.InvokeAsync(async () =>
            {
                SetupWizardWindow? window = null;
                try
                {
                    var root = Path.Combine(Path.GetTempPath(), "setup-wizard-window-" + Guid.NewGuid().ToString("N"));
                    Directory.CreateDirectory(root);
                    try
                    {
                        var installer = Path.Combine(root, "install.ps1");
                        File.WriteAllText(installer, "# synthetic, never invoked");
                        var powerShell = Path.Combine(
                            Environment.GetFolderPath(Environment.SpecialFolder.System),
                            "WindowsPowerShell",
                            "v1.0",
                            "powershell.exe");
                        window = new SetupWizardWindow(new SetupClient(installer, powerShell), elevated: false);
                        await action(window);
                    }
                    finally
                    {
                        Directory.Delete(root, recursive: true);
                    }

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
        await completion.Task.WaitAsync(TimeSpan.FromSeconds(45));
    }
}
