using System.IO;
using System.Windows;
using System.Windows.Controls;
using ClaudeSwitcher.App.Models;
using ClaudeSwitcher.App.Services;
using ClaudeSwitcher.App.ViewModels;

namespace ClaudeSwitcher.App;

public partial class MainWindow : Window
{
    private readonly MainWindowState _initialState = MainWindowState.Initial;
    private CoreClient _client;
    private MainWindowState _state;
    private bool _busy;
    private bool _setupOpen;
    private bool _setupMutationPending;

    public MainWindow() : this(null)
    {
    }

    internal MainWindow(Task<SetupApplyRunResult>? pendingSetup)
    {
        InitializeComponent();
        _setupMutationPending = pendingSetup is not null;
        _state = pendingSetup is null
            ? _initialState
            : _initialState.Running("配置变更可能仍在运行；正在等待原配置进程的明确结果，暂时禁止其他操作。");
        _client = CreateClient();
        RenderState();
        Loaded += async (_, _) =>
        {
            if (pendingSetup is not null)
            {
                await KeepSetupMutationGuardAsync(pendingSetup);
            }
            else
            {
                await RefreshFromCoreAsync();
            }
        };
    }

    private static CoreClient CreateClient()
    {
        var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
        var powerShell = Path.Combine(system, "WindowsPowerShell", "v1.0", "powershell.exe");
        var core = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude-switcher", "claude-switch.ps1");
        return new CoreClient(core, powerShell);
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e) => await RefreshFromCoreAsync();
    private async void Fix_Click(object sender, RoutedEventArgs e) => await RunFixAsync();
    private async void SwitchA_Click(object sender, RoutedEventArgs e) => await SwitchAsync("A");
    private async void SwitchB_Click(object sender, RoutedEventArgs e) => await SwitchAsync("B");

    private void Configure_Click(object sender, RoutedEventArgs e)
    {
        if (_busy || _setupOpen || _setupMutationPending || !_state.CanConfigure)
        {
            return;
        }

        _setupOpen = true;
        RenderState();
        var wizard = new SetupWizardWindow();
        wizard.Owner = this;
        wizard.Closed += async (_, _) =>
        {
            var completed = wizard.SetupCompleted;
            var detached = wizard.SetupMayStillBeRunning;
            _setupOpen = false;
            if (completed)
            {
                _client = CreateClient();
                _state = MainWindowState.Initial;
                await RefreshFromCoreAsync();
                return;
            }

            if (detached)
            {
                _setupMutationPending = true;
                _state = _state.Running(
                    "配置变更可能仍在运行，且未被终止。主窗口会继续等待该变更给出明确结果；在此期间禁止修复、切换和启动，也不会重复提交配置。");
                RenderState();
                await KeepSetupMutationGuardAsync(wizard.WaitForPendingApplyAsync());
                return;
            }

            RenderState();
        };
        wizard.Show();
    }

    internal async Task KeepSetupMutationGuardAsync(Task<SetupApplyRunResult> pendingApply)
    {
        _setupMutationPending = true;
        _state = _state.Running(
            "配置变更可能仍在运行，且未确认退出。主窗口正在等待该变更给出明确结果；在此期间禁止配置、修复、切换和启动，也不会重复提交配置。");
        RenderState();
        try
        {
            await pendingApply;
            _setupMutationPending = false;
            _client = CreateClient();
            _state = MainWindowState.Initial;
            await RefreshFromCoreAsync();
        }
        catch (Exception)
        {
            _setupMutationPending = true;
            _state = _state.Running(
                "配置变更的观察任务异常结束，进程是否退出仍未确认。为避免并发变更，配置、修复、切换和启动将保持阻断。");
            RenderState();
        }
    }
    private async Task RefreshFromCoreAsync()
    {
        if (_busy || _setupOpen || _setupMutationPending)
        {
            return;
        }

        _busy = true;
        await RefreshCoreAsync();
    }

    private async Task RefreshCoreAsync()
    {
        CoreResult? statusResult = null;
        _state = _state.Running("正在向核心读取事务状态…");
        RenderState();
        try
        {
            var statusRun = await _client.RunAsync(CoreCommand.Status, null, Guid.NewGuid(), CancellationToken.None);
            if (!statusRun.IsCompleted || statusRun.Result is null)
            {
                _state = _state.StatusQueryTimedOut();
                return;
            }

            statusResult = statusRun.Result;
            _state = _initialState.Apply(statusResult: null, statusResult);
            if (_state.Status is UiStatus.RecoveryRequired or UiStatus.Running)
            {
                return;
            }

            _state = _state.Running("正在执行本次 14 项安全检查…");
            RenderState();
            var checkRun = await _client.RunAsync(CoreCommand.CheckDetail, null, Guid.NewGuid(), CancellationToken.None);
            _state = checkRun.Result is null
                ? _state.Fail("检查未返回可验证的结果，请重新检查。")
                : _state.ApplyCheck(checkRun.Result).ApplyStatus(statusResult);
        }
        catch (CoreClientException exception) when (exception.Error == CoreClientError.SetupRequired)
        {
            _state = _state.SetupRequired();
        }
        catch (CoreClientException exception) when (exception.Error == CoreClientError.QueryTimedOut && statusResult is null)
        {
            _state = _state.StatusQueryTimedOut();
        }
        catch (CoreProtocolException exception) when (exception.PartialResult?.Command == CoreCommand.Status)
        {
            _state = _state.ApplyStatus(exception.PartialResult!);
        }
        catch (CoreProtocolException exception) when (exception.PartialResult?.Command == CoreCommand.CheckDetail)
        {
            ApplyRefreshFailure(statusResult!, exception);
        }
        catch (Exception exception) when (exception is CoreProtocolException or CoreClientException)
        {
            _state = _state.Fail(exception.Message);
        }
        finally
        {
            _busy = false;
            RenderState();
        }
    }

    private void ApplyRefreshFailure(CoreResult statusResult, CoreProtocolException exception)
    {
        _state = _state
            .ApplyCheck(exception.PartialResult!)
            .ApplyStatus(statusResult);
    }

    private async Task RunFixAsync()
    {
        if (_busy || _setupOpen || _setupMutationPending || !_state.CanFix)
        {
            return;
        }

        await RunActionAsync(async () =>
        {
            _state = _state.Running("正在请求核心修复环境…");
            RenderState();
            var result = await _client.RunAsync(CoreCommand.Fix, null, Guid.NewGuid(), CancellationToken.None);
            if (!result.IsCompleted)
            {
                _state = _state.Running("修复仍在处理；请刷新以读取核心状态。") with { CanRefresh = true };
                return;
            }

            if (result.Result?.Success != true)
            {
                _state = _state.Fail(result.Result?.Message ?? "核心未确认修复完成。");
                return;
            }

            _state = _initialState;
            await RefreshCoreAsync();
        });
    }

    private async Task SwitchAsync(string target)
    {
        if (_busy || _setupOpen || _setupMutationPending || !_state.CanSwitch || target is not ("A" or "B"))
        {
            return;
        }

        await RunActionAsync(async () =>
        {
            _state = _state.Running($"正在请求核心切换到账号 {target}，启动许可仍由核心当次安检决定…");
            RenderState();
            CoreClientRunResult result;
            try
            {
                result = await _client.RunAsync(CoreCommand.Switch, target, Guid.NewGuid(), CancellationToken.None);
            }
            catch (CoreProtocolException exception) when (exception.PartialResult?.Command == CoreCommand.Switch)
            {
                _state = _state.ApplySwitch(exception.PartialResult!, target, freshCheck: null);
                return;
            }

            if (!result.IsCompleted || result.Result is null)
            {
                _state = _state.Running("切换仍在处理；请刷新以按操作状态确认结果。") with { CanRefresh = true };
                return;
            }

            if (!result.Result.IsCompletedSwitch)
            {
                _state = _state.ApplySwitch(result.Result, target, freshCheck: null);
                return;
            }

            CoreClientRunResult fresh;
            try
            {
                fresh = await _client.RunAsync(CoreCommand.CheckDetail, null, Guid.NewGuid(), CancellationToken.None);
            }
            catch (CoreProtocolException exception) when (exception.PartialResult?.Command == CoreCommand.CheckDetail)
            {
                _state = _state.ApplySwitch(result.Result, target, exception.PartialResult);
                return;
            }
            catch (CoreProtocolException)
            {
                _state = _state.ApplySwitch(result.Result, target, freshCheck: null);
                return;
            }
            catch (CoreClientException exception) when (exception.Error != CoreClientError.SetupRequired)
            {
                _state = _state.ApplySwitch(result.Result, target, freshCheck: null);
                return;
            }
            _state = _state.ApplySwitch(result.Result, target, fresh.Result);
        });
    }

    private async Task RunActionAsync(Func<Task> action)
    {
        _busy = true;
        RenderState();
        try
        {
            await action();
        }
        catch (CoreClientException exception) when (exception.Error == CoreClientError.SetupRequired)
        {
            _state = _state.SetupRequired();
        }
        catch (CoreProtocolException exception) when (exception.PartialResult?.Command == CoreCommand.Fix)
        {
            _state = _state.Fail(exception.PartialResult.Message);
        }
        catch (Exception exception) when (exception is CoreProtocolException or CoreClientException)
        {
            _state = _state.Fail(exception.Message);
        }
        finally
        {
            _busy = false;
            RenderState();
        }
    }

    private void RenderState()
    {
        StatusBadge.Text = _state.StatusText;
        BannerText.Text = _state.Banner;
        CurrentAccountText.Text = _state.CurrentAccount;
        ChecksGrid.ItemsSource = _state.Checks;
        OperationText.Text = _state.ActiveOperationId == "—"
            ? string.Empty
            : $"操作 {_state.ActiveOperationId} · 阶段 {_state.TransactionPhase}";
        ConfigureButton.Visibility = _state.CanConfigure ? Visibility.Visible : Visibility.Collapsed;
        ConfigureButton.IsEnabled = !_busy && !_setupOpen && !_setupMutationPending && _state.CanConfigure;
        RefreshButton.IsEnabled = !_busy && !_setupOpen && !_setupMutationPending && _state.CanRefresh;
        FixButton.IsEnabled = !_busy && !_setupOpen && !_setupMutationPending && _state.CanFix;
        SwitchAButton.IsEnabled = !_busy && !_setupOpen && !_setupMutationPending && _state.CanSwitch;
        SwitchBButton.IsEnabled = !_busy && !_setupOpen && !_setupMutationPending && _state.CanSwitch;
    }
}
