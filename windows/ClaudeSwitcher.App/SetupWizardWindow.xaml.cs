using System.IO;
using System.Security.Principal;
using System.Windows;
using System.Windows.Controls;
using ClaudeSwitcher.App.Models;
using ClaudeSwitcher.App.Services;

namespace ClaudeSwitcher.App;

public partial class SetupWizardWindow : Window
{
    private static readonly TimeSpan WaitPollInterval = TimeSpan.FromSeconds(1);
    private const int MaxWaitPollsAfterSoftTimeout = 30;
    private readonly SetupClient _client;
    private SetupWizardState _state;
    private bool _initialized;
    private bool _waitingForApply;
    private int _waitPollCount;
    private int _applyInvocationCount;

    public SetupWizardWindow()
        : this(CreateClient(), IsElevated())
    {
    }

    internal SetupWizardWindow(SetupClient client, bool elevated)
    {
        InitializeComponent();
        _client = client;
        _state = elevated
            ? SetupWizardState.Editing("auto", string.Empty).AsElevated()
            : SetupWizardState.Editing("auto", string.Empty);
        _initialized = true;
        ProxyModeCombo.ItemsSource = SetupProtocolParser.ProxyModes;
        ProxyModeCombo.SelectedItem = _state.ProxyMode;
        ProxyGroupText.Text = _state.ProxyGroup;
        Closing += Window_Closing;
        RenderState();
    }

    public bool SetupCompleted { get; private set; }

    public SetupWizardState State => _state;

    public bool SetupMayStillBeRunning => _state.Phase == SetupWizardPhase.Detached;

    internal SetupClient SetupClient => _client;

    internal Task<SetupApplyRunResult> WaitForPendingApplyAsync() => _client.WaitForApplyAsync(Timeout.InfiniteTimeSpan);

    internal int WaitPollCountForTest => _waitPollCount;

    internal int ApplyInvocationCountForTest => _applyInvocationCount;

    internal void DetachForTest() => Detach();

    internal void ApplyResultForTest(SetupApplyRunResult result) => HandleApplyResult(result);

    private static SetupClient CreateClient()
    {
        var installer = Path.Combine(AppContext.BaseDirectory, "scripts", "install.ps1");
        var powerShell = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe");
        return new SetupClient(installer, powerShell);
    }

    private static bool IsElevated()
    {
        using var identity = WindowsIdentity.GetCurrent();
        var principal = new WindowsPrincipal(identity);
        return principal.IsInRole(WindowsBuiltInRole.Administrator);
    }

    private async void Preview_Click(object sender, RoutedEventArgs e)
    {
        if (!_state.CanPreview || _waitingForApply)
        {
            return;
        }

        var selectedMode = ProxyModeCombo.SelectedItem as string ?? string.Empty;
        var selectedGroup = string.Equals(selectedMode, "clash-verge", StringComparison.Ordinal)
            ? ProxyGroupText.Text
            : string.Empty;
        _state = _state.WithSelection(selectedMode, selectedGroup).Previewing();
        RenderState();
        try
        {
            var preview = await _client.PreviewAsync(_state.ProxyMode, _state.ProxyGroup, CancellationToken.None);
            _state = _state.Reviewed(preview);
        }
        catch (SetupClientException exception)
        {
            _state = _state.Terminal(SetupWizardPhase.Failed, Describe(exception));
        }
        catch (Exception exception) when (exception is ArgumentException or OperationCanceledException)
        {
            _state = _state.Terminal(SetupWizardPhase.Failed, exception.Message);
        }
        finally
        {
            RenderState();
        }
    }

    private async void Apply_Click(object sender, RoutedEventArgs e)
    {
        if (!_state.CanApply || _state.Preview is not { } reviewedPreview || _waitingForApply)
        {
            return;
        }

        _applyInvocationCount++;
        _state = _state.Applying();
        RenderState();
        try
        {
            var result = await _client.ApplyAsync(reviewedPreview, CancellationToken.None);
            if (result.Outcome == SetupApplyOutcome.StillRunning)
            {
                _state = _state.StillRunning();
                RenderState();
                await WaitForApplyAsync();
                return;
            }

            HandleApplyResult(result);
        }
        catch (SetupClientException exception)
        {
            _state = _state.Terminal(SetupWizardPhase.Failed, Describe(exception));
        }
        catch (Exception exception) when (exception is ArgumentException or InvalidOperationException)
        {
            _state = _state.Terminal(SetupWizardPhase.Failed, exception.Message);
        }
        finally
        {
            if (!_waitingForApply)
            {
                RenderState();
            }
        }
    }

    private async Task WaitForApplyAsync(Func<Task<SetupApplyRunResult>>? pendingForTest = null)
    {
        _waitingForApply = true;
        _waitPollCount = 0;
        RenderState();
        try
        {
            while (_waitPollCount < MaxWaitPollsAfterSoftTimeout)
            {
                try
                {
                    var pending = pendingForTest is null
                        ? _client.WaitForApplyAsync(WaitPollInterval)
                        : pendingForTest().WaitAsync(WaitPollInterval);
                    var result = await pending;
                    HandleApplyResult(result);
                    return;
                }
                catch (TimeoutException)
                {
                    _waitPollCount++;
                    if (_waitPollCount < MaxWaitPollsAfterSoftTimeout)
                    {
                        _state = _state.Waiting(
                            $"配置仍在运行，正在等待安装器完成…（已等待 {_waitPollCount} 秒，最多再等 {MaxWaitPollsAfterSoftTimeout - _waitPollCount} 秒）");
                        RenderState();
                    }
                }
            }

            Detach();
        }
        catch (SetupClientException exception)
        {
            _state = _state.Terminal(SetupWizardPhase.Failed, Describe(exception));
        }
        catch (Exception)
        {
            Detach();
        }
        finally
        {
            _waitingForApply = false;
            RenderState();
        }
    }

    internal void StartDetachedWaitForTest(Task<SetupApplyRunResult> pendingApply)
    {
        _applyInvocationCount = 1;
        _state = _state.StillRunning();
        _ = WaitForApplyAsync(() => pendingApply);
    }


    private void Detach()
    {
        _state = _state.Detached();
    }

    private void HandleApplyResult(SetupApplyRunResult result)
    {
        switch (result.Outcome)
        {
            case SetupApplyOutcome.Completed:
                SetupCompleted = true;
                _state = _state.Completed(result.Result?.Message ?? "配置已完成。");
                break;
            case SetupApplyOutcome.Cancelled:
                _state = _state.Terminal(SetupWizardPhase.Cancelled, "已取消管理员授权，未应用系统配置。可重新预览或关闭后重试。");
                break;
            case SetupApplyOutcome.PartialFailure:
                _state = _state.Terminal(
                    SetupWizardPhase.PartialFailure,
                    result.Result is null
                        ? "安装未完整完成，可重新预览后重试。"
                        : $"{result.Result.Message}（阶段 {result.Result.Stage}，代码 {result.Result.Code}）");
                break;
            case SetupApplyOutcome.StillRunning:
                _state = _state.StillRunning();
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(result));
        }
    }

    private void Selection_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (!_initialized)
        {
            return;
        }

        _state = _state.WithSelection(ProxyModeCombo.SelectedItem as string ?? string.Empty, ProxyGroupText.Text);
        RenderState();
    }

    private void Selection_Changed(object sender, TextChangedEventArgs e)
    {
        if (!_initialized)
        {
            return;
        }

        _state = _state.WithSelection(ProxyModeCombo.SelectedItem as string ?? string.Empty, ProxyGroupText.Text);
        RenderState();
    }

    private void Close_Click(object sender, RoutedEventArgs e)
    {
        if (_state.CanClose && !_waitingForApply)
        {
            Close();
        }
    }

    private void Window_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (!_state.CanClose || _waitingForApply)
        {
            e.Cancel = true;
        }
    }

    private void RenderState()
    {
        PhaseText.Text = _state.Phase switch
        {
            SetupWizardPhase.Editing => "等待预览",
            SetupWizardPhase.Previewing => "正在预览",
            SetupWizardPhase.Reviewed => "等待确认",
            SetupWizardPhase.Applying => "正在应用",
            SetupWizardPhase.StillRunning => "仍在运行",
            SetupWizardPhase.Detached => "已脱离等待",
            SetupWizardPhase.Completed => "配置完成",
            SetupWizardPhase.Cancelled => "已取消",
            SetupWizardPhase.PartialFailure => "部分失败",
            SetupWizardPhase.Failed => "配置失败",
            SetupWizardPhase.Elevated => "需要普通权限",
            _ => "配置"
        };
        MessageText.Text = _state.Message;
        ProxyModeCombo.IsEnabled = _state.Phase is SetupWizardPhase.Editing or SetupWizardPhase.Failed or SetupWizardPhase.Cancelled or SetupWizardPhase.PartialFailure;
        ProxyGroupText.IsEnabled = ProxyModeCombo.IsEnabled;
        PreviewButton.IsEnabled = _state.CanPreview;
        ApplyButton.IsEnabled = _state.CanApply;
        CloseButton.IsEnabled = _state.CanClose && !_waitingForApply;
        var clash = string.Equals(_state.ProxyMode, "clash-verge", StringComparison.Ordinal);
        ProxyHintText.Text = clash
            ? "Clash Verge 需要填写配置中 type: select 的代理组名称（最多 128 个安全字符）。"
            : "非 Clash 模式不需要代理组名，请保持为空。";
        ReviewPanel.Visibility = _state.Preview is null ? Visibility.Collapsed : Visibility.Visible;
        ReviewPlaceholderText.Visibility = _state.Preview is null ? Visibility.Visible : Visibility.Collapsed;
        if (_state.Preview is not null)
        {
            CountryText.Text = _state.Preview.Country;
            TimeZoneText.Text = _state.Preview.TimeZoneId;
            CultureText.Text = _state.Preview.Culture;
            ReviewedProxyText.Text = string.IsNullOrEmpty(_state.Preview.ProxyGroup)
                ? _state.Preview.ProxyMode
                : $"{_state.Preview.ProxyMode} / {_state.Preview.ProxyGroup}";
            EffectsList.ItemsSource = _state.Preview.ProposedEffects;
        }
        else
        {
            EffectsList.ItemsSource = null;
        }
    }

    private static string Describe(SetupClientException exception) =>
        exception.Error switch
        {
            SetupClientError.Unavailable => "配置安装器或 Windows PowerShell 5.1 不可用。" + exception.Message,
            SetupClientError.TimedOut => "预览已超时，请检查网络和安装器后重试。",
            SetupClientError.OutputTooLarge => "安装器输出超过安全限制，请重试。",
            SetupClientError.Busy => "已有配置正在运行，请等待完成。",
            _ => "配置协议或安装器失败。" + exception.Message
        };
}