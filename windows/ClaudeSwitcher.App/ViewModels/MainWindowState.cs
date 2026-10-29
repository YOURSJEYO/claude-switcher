using ClaudeSwitcher.App.Models;
using ClaudeSwitcher.App.Services;

namespace ClaudeSwitcher.App.ViewModels;

public enum UiStatus
{
    Checking,
    Ready,
    Blocked,
    Running,
    RecoveryRequired,
    SetupRequired
}

public enum CheckVisualState
{
    Pending,
    Ok,
    Warning,
    Failed,
    Unknown
}

public sealed record CheckRow(
    string Id,
    string Name,
    string Detail,
    CheckVisualState VisualState,
    string Icon,
    string Accent,
    bool Blocking);

public sealed record MainWindowState(
    UiStatus Status,
    string StatusText,
    string Banner,
    IReadOnlyList<CheckRow> Checks,
    string CurrentAccount,
    string ActiveOperationId,
    string TransactionPhase,
    bool CanRefresh,
    bool CanFix,
    bool CanSwitch,
    bool CanLaunch)
{
    private static readonly (string Id, string Name)[] CheckDefinitions =
    [
        ("proxy_engine", "代理内核"),
        ("tun_interface", "TUN 网卡"),
        ("egress_country", "出口地区"),
        ("ip_consistency", "IP 一致"),
        ("timezone", "时区"),
        ("locale", "区域格式"),
        ("ipv6", "IPv6"),
        ("dns", "DNS"),
        ("webrtc", "WebRTC"),
        ("bodyguard", "保镖"),
        ("routing_rules", "规则置顶"),
        ("client_language", "客户端语言"),
        ("asn", "ASN 属性"),
        ("ecosystem", "生态可达")
    ];

    public static MainWindowState Initial { get; } = new(
        UiStatus.Checking,
        "检查中",
        "正在读取核心安全检查结果…",
        CreatePendingRows(),
        "—",
        "—",
        "—",
        false,
        false,
        false,
        false);

    public MainWindowState Running(string message) =>
        this with
        {
            Status = UiStatus.Running,
            StatusText = "处理中",
            Banner = message,
            Checks = CreatePendingRows(),
            CanRefresh = false,
            CanFix = false,
            CanSwitch = false,
            CanLaunch = false
        };

    public bool CanConfigure => Status == UiStatus.SetupRequired || (CanFix && Status is not (UiStatus.Running or UiStatus.RecoveryRequired));

    public MainWindowState SetupRequired(string? reason = null) =>
        this with
        {
            Status = UiStatus.SetupRequired,
            StatusText = "尚未配置",
            Banner = (reason ?? "本机尚未配置 Claude 切换器核心。") + "请点击“配置安装”打开向导；本应用不会自动下载脚本或启动 Claude。",
            CurrentAccount = "—",
            ActiveOperationId = "—",
            TransactionPhase = "—",
            Checks = CreatePendingRows(),
            CanRefresh = false,
            CanFix = false,
            CanSwitch = false,
            CanLaunch = false
        };
    public MainWindowState Apply(CoreResult? statusResult, CoreResult? status)
    {
        var state = statusResult is null ? this : ApplyCheck(statusResult);
        return status is null ? state : state.ApplyStatus(status);
    }

    public MainWindowState ApplyCheck(CoreResult result)
    {
        if (result.Command != CoreCommand.CheckDetail)
        {
            return Blocked("核心返回了错误的检查结果。", "检查协议不匹配，请重新配置。");
        }

        var rows = result.Checks
            .Select(check => ToRow(check))
            .ToArray();

        var hasBlocking = result.Checks.Any(check => check.Blocking);
        var status = result.Success && !hasBlocking ? UiStatus.Ready : UiStatus.Blocked;
        var banner = status == UiStatus.Ready
            ? result.HasWarnings
                ? "环境可用，但存在不阻断启动的警告。"
                : "14 项安全检查已通过。"
            : string.IsNullOrWhiteSpace(result.Message)
                ? "存在阻断项，请修复后重新检查。"
                : result.Message;

        return this with
        {
            Status = status,
            StatusText = status == UiStatus.Ready ? "环境就绪" : "检查未通过",
            Banner = banner,
            Checks = rows,
            CanRefresh = true,
            CanFix = true,
            CanSwitch = status == UiStatus.Ready,
            CanLaunch = result.CanLaunch
        };
    }

    public MainWindowState ApplyStatus(CoreResult result)
    {
        if (result.Command != CoreCommand.Status)
        {
            return Blocked("核心返回了错误的状态结果。", "状态协议不匹配，请重新配置。");
        }

        var current = result.Current ?? "none";
        var recovery = result.Phase == OperationPhase.RecoveryRequired || result.RecoveryRequired == true;
        var active = result.ActiveOperationId?.ToString("D") ?? "—";
        var phase = result.TransactionPhase ?? "—";

        if (recovery)
        {
            return this with
            {
                Status = UiStatus.RecoveryRequired,
                StatusText = "需要恢复",
                Banner = RecoveryGuidance(current, phase),
                CurrentAccount = current == "none" ? "未初始化" : current,
                ActiveOperationId = active,
                TransactionPhase = phase,
                Checks = CreatePendingRows(),
                CanRefresh = true,
                CanFix = false,
                CanSwitch = false,
                CanLaunch = false
            };
        }

        if (result.Phase == OperationPhase.Running)
        {
            return this with
            {
                Status = UiStatus.Running,
                StatusText = "处理中",
                Banner = $"核心事务正在执行（{phase}）。刷新可再次读取状态。",
                CurrentAccount = current == "none" ? "未初始化" : current,
                ActiveOperationId = active,
                TransactionPhase = phase,
                Checks = CreatePendingRows(),
                CanRefresh = true,
                CanFix = false,
                CanSwitch = false,
                CanLaunch = false
            };
        }

        return this with
        {
            CurrentAccount = current == "none" ? "未初始化" : current,
            ActiveOperationId = active,
            TransactionPhase = phase,
            CanRefresh = Status != UiStatus.Running,
            CanFix = Status is UiStatus.Ready or UiStatus.Blocked,
            CanSwitch = Status == UiStatus.Ready,
            CanLaunch = Status == UiStatus.Ready && CanLaunch
        };
    }

    public MainWindowState StatusQueryTimedOut() =>
        this with
        {
            Status = UiStatus.Blocked,
            StatusText = "状态不可用",
            Banner = "状态查询已超时，事务状态未知。请刷新状态后再操作。",
            CurrentAccount = "未知",
            ActiveOperationId = "—",
            TransactionPhase = "—",
            CanRefresh = true,
            CanFix = false,
            Checks = CreatePendingRows(),
            CanLaunch = false
        };

    public MainWindowState ApplySwitch(CoreResult result, string target, CoreResult? freshCheck)
    {
        if (!result.IsCompletedSwitch)
        {
            var recovery = result.Phase == OperationPhase.RecoveryRequired || result.RecoveryRequired == true;
            var observedCurrent = result.Current ?? CurrentAccount;
            var activeOperationId = result.ActiveOperationId?.ToString("D") ?? "—";
            var transactionPhase = result.TransactionPhase ?? result.Phase?.ToWire() ?? "—";
            if (recovery)
            {
                return this with
                {
                    Status = UiStatus.RecoveryRequired,
                    StatusText = "需要恢复",
                    Banner = RecoveryGuidance(observedCurrent, transactionPhase),
                    CurrentAccount = observedCurrent,
                    ActiveOperationId = activeOperationId,
                    TransactionPhase = transactionPhase,
                    Checks = CreatePendingRows(),
                    CanRefresh = true,
                    CanFix = false,
                    CanSwitch = false,
                    CanLaunch = false
                };
            }

            if (result.Phase == OperationPhase.Running)
            {
                return this with
                {
                    Status = UiStatus.Running,
                    StatusText = "处理中",
                    Banner = $"账号切换事务正在执行（阶段 {transactionPhase}），完成状态尚未确认。请刷新状态观察。",
                    CurrentAccount = observedCurrent,
                    Checks = CreatePendingRows(),
                    ActiveOperationId = activeOperationId,
                    TransactionPhase = transactionPhase,
                    CanRefresh = true,
                    CanFix = false,
                    CanSwitch = false,
                    CanLaunch = false
                };
            }

            return this with
            {
                Status = UiStatus.Blocked,
                StatusText = "切换未完成",
                Banner = result.Message,
                CurrentAccount = observedCurrent,
                ActiveOperationId = activeOperationId,
                TransactionPhase = transactionPhase,
                Checks = CreatePendingRows(),
                CanRefresh = true,
                CanFix = false,
                CanSwitch = false,
                CanLaunch = false
            };
        }

        var current = result.Current ?? target;
        if (freshCheck is null)
        {
            return Initial with
            {
                Status = UiStatus.Blocked,
                StatusText = "切换后检查未完成",
                Banner = $"切换已完成，当前账号 {current}；尚未取得当次安全检查结果。请重新检查后再操作。",
                CurrentAccount = current,
                ActiveOperationId = "—",
                TransactionPhase = "completed",
                CanRefresh = true,
                CanFix = false,
                CanSwitch = false,
                CanLaunch = false
            };
        }

        var checkedState = ApplyCheck(freshCheck);
        var ready = checkedState.Status == UiStatus.Ready && freshCheck.CanLaunch;
        return checkedState with
        {
            Status = ready ? UiStatus.Ready : UiStatus.Blocked,
            StatusText = ready ? "已切换" : "切换后检查未通过",
            Banner = $"切换已完成，当前账号 {current}。{checkedState.Banner}",
            CurrentAccount = current,
            ActiveOperationId = "—",
            TransactionPhase = "completed",
            CanRefresh = true,
            CanFix = checkedState.CanFix,
            CanSwitch = ready && checkedState.CanSwitch,
            CanLaunch = ready
        };
    }
    public MainWindowState Fail(string message) =>
        this with
        {
            Status = UiStatus.Blocked,
            StatusText = "操作失败",
            Banner = message,
            CanRefresh = true,
            CanFix = true,
            CanSwitch = false,
            CanLaunch = false
        };

    private MainWindowState Blocked(string statusText, string message) =>
        this with
        {
            Status = UiStatus.Blocked,
            StatusText = statusText,
            Banner = message,
            CanRefresh = true,
            CanFix = true,
            CanSwitch = false,
            CanLaunch = false
        };

    private static string RecoveryGuidance(string current, string phase) =>
        $"检测到未完成事务（账号 {current}，阶段 {phase}）。请勿删除任何未核实的 .new/.previous 恢复材料。先核对并保留 %APPDATA%\\Claude.new、%APPDATA%\\Claude.previous，以及 %USERPROFILE%\\.claude-switcher\\accounts\\A.new、A.previous、B.new、B.previous；确认有效快照后再执行恢复。恢复完成并重新检查前，修复、切换和启动均不可用。";

    private static IReadOnlyList<CheckRow> CreatePendingRows() =>
        CheckDefinitions
            .Select(definition => new CheckRow(
                definition.Id,
                definition.Name,
                "等待检查",
                CheckVisualState.Pending,
                "…",
                "#64748B",
                true))
            .ToArray();

    private static CheckRow ToRow(CheckResult check)
    {
        var name = CheckDefinitions.FirstOrDefault(definition => definition.Id == check.Id).Name ?? check.Name;
        return check.Status switch
        {
            CheckStatus.Ok => new CheckRow(check.Id, name, check.Detail, CheckVisualState.Ok, "✓", "#22C55E", check.Blocking),
            CheckStatus.Warn => new CheckRow(check.Id, name, check.Detail, CheckVisualState.Warning, "!", "#F59E0B", check.Blocking),
            CheckStatus.Fail => new CheckRow(check.Id, name, check.Detail, CheckVisualState.Failed, "×", "#F87171", check.Blocking),
            _ => new CheckRow(check.Id, name, check.Detail, CheckVisualState.Unknown, "?", "#94A3B8", check.Blocking)
        };
    }
}
