using ClaudeSwitcher.App.Models;

namespace ClaudeSwitcher.App.Models;

public enum SetupWizardPhase
{
    Editing,
    Previewing,
    Reviewed,
    Applying,
    StillRunning,
    Detached,
    Completed,
    Failed,
    Cancelled,
    PartialFailure,
    Elevated
}

public sealed record SetupWizardState(
    SetupWizardPhase Phase,
    string ProxyMode,
    string ProxyGroup,
    SetupPreview? Preview,
    string Message)
{
    public bool CanPreview => Phase is SetupWizardPhase.Editing or SetupWizardPhase.Failed or SetupWizardPhase.Cancelled or SetupWizardPhase.PartialFailure;
    public bool CanApply => Phase == SetupWizardPhase.Reviewed;
    public bool CanWait => Phase == SetupWizardPhase.StillRunning;
    public bool CanClose => Phase is SetupWizardPhase.Editing or SetupWizardPhase.Reviewed or SetupWizardPhase.Completed or SetupWizardPhase.Failed or SetupWizardPhase.Cancelled or SetupWizardPhase.PartialFailure or SetupWizardPhase.Elevated or SetupWizardPhase.Detached;

    public static SetupWizardState Editing(string proxyMode, string proxyGroup) =>
        new(SetupWizardPhase.Editing, proxyMode, proxyGroup, null, "选择代理模式和组名，然后点击“预览”。不会自动下载或应用。");

    public SetupWizardState WithSelection(string proxyMode, string proxyGroup) =>
        this with
        {
            Phase = SetupWizardPhase.Editing,
            ProxyMode = proxyMode,
            ProxyGroup = proxyGroup,
            Preview = null,
            Message = "代理选择已更改，请重新预览。"
        };

    public SetupWizardState Previewing() =>
        this with
        {
            Phase = SetupWizardPhase.Previewing,
            Preview = null,
            Message = "正在探测出口地区并生成审核信息…"
        };

    public SetupWizardState Reviewed(SetupPreview preview)
    {
        if (!string.Equals(preview.ProxyMode, ProxyMode, StringComparison.Ordinal) ||
            !string.Equals(preview.ProxyGroup, ProxyGroup, StringComparison.Ordinal))
        {
            return Terminal(SetupWizardPhase.Failed, "预览返回的代理选择与当前选择不一致，请重试。");
        }

        return this with
        {
            Phase = SetupWizardPhase.Reviewed,
            Preview = preview,
            Message = "请核对以下探测结果和系统变更；确认后点击“应用配置”。"
        };
    }

    public SetupWizardState Applying() =>
        this with
        {
            Phase = SetupWizardPhase.Applying,
            Message = "正在应用配置。安装器可能显示一次 UAC 确认；请保持本窗口打开。"
        };

    public SetupWizardState StillRunning() =>
        this with
        {
            Phase = SetupWizardPhase.StillRunning,
            Message = "配置仍在运行。请等待完成；本窗口不会终止安装或重复提交。"
        };

    public SetupWizardState Waiting(string message) =>
        this with
        {
            Phase = SetupWizardPhase.StillRunning,
            Message = message
        };
    public SetupWizardState Detached() =>
        this with
        {
            Phase = SetupWizardPhase.Detached,
            Message = "已停止在向导内等待。配置变更可能仍在运行，且未确认终止；请勿重复应用。关闭向导后，主窗口会继续等待该变更给出明确结果。"
        };

    public SetupWizardState Completed(string message) =>
        this with
        {
            Phase = SetupWizardPhase.Completed,
            Message = message
        };

    public SetupWizardState Terminal(SetupWizardPhase phase, string message)
    {
        if (phase is not (SetupWizardPhase.Failed or SetupWizardPhase.Cancelled or SetupWizardPhase.PartialFailure))
        {
            throw new ArgumentOutOfRangeException(nameof(phase));
        }

        return this with
        {
            Phase = phase,
            Message = message
        };
    }

    public SetupWizardState AsElevated() =>
        this with
        {
            Phase = SetupWizardPhase.Elevated,
            Preview = null,
            Message = "当前应用以管理员身份运行。请关闭本窗口，从普通桌面会话重新启动 Claude 切换器后再配置。"
        };
}
