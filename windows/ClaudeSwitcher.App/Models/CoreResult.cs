namespace ClaudeSwitcher.App.Models;

public enum CoreCommand
{
    CheckDetail,
    Status,
    Fix,
    Switch
}

public enum OperationPhase
{
    Idle,
    Running,
    RecoveryRequired,
    Completed
}

public sealed record CoreResult(
    int SchemaVersion,
    Guid OperationId,
    CoreCommand Command,
    bool Success,
    string Code,
    string Message,
    int ExitCode,
    IReadOnlyList<CheckResult> Checks,
    bool CanLaunch,
    string? Current,
    OperationPhase? Phase,
    bool? RecoveryRequired,
    Guid? ActiveOperationId = null,
    string? TransactionPhase = null)
{
    public bool IsCompletedSwitch =>
        ExitCode == 0 &&
        Command == CoreCommand.Switch &&
        Success &&
        Phase == OperationPhase.Completed &&
        RecoveryRequired == false;

    public bool HasWarnings => Checks.Any(check => check.Status == CheckStatus.Warn);
}

public static class CoreCommandWire
{
    public static string ToWire(this CoreCommand command) => command switch
    {
        CoreCommand.CheckDetail => "checkdetail",
        CoreCommand.Status => "status",
        CoreCommand.Fix => "fix",
        CoreCommand.Switch => "switch",
        _ => throw new ArgumentOutOfRangeException(nameof(command), command, null)
    };

    public static bool TryParse(string value, out CoreCommand command)
    {
        command = value switch
        {
            "checkdetail" => CoreCommand.CheckDetail,
            "status" => CoreCommand.Status,
            "fix" => CoreCommand.Fix,
            "switch" => CoreCommand.Switch,
            _ => default
        };

        return value is "checkdetail" or "status" or "fix" or "switch";
    }
}

public static class OperationPhaseWire
{
    public static string ToWire(this OperationPhase phase) => phase switch
    {
        OperationPhase.Idle => "idle",
        OperationPhase.Running => "running",
        OperationPhase.RecoveryRequired => "recoveryRequired",
        OperationPhase.Completed => "completed",
        _ => throw new ArgumentOutOfRangeException(nameof(phase), phase, null)
    };

    public static bool TryParse(string value, out OperationPhase phase)
    {
        phase = value switch
        {
            "idle" => OperationPhase.Idle,
            "running" => OperationPhase.Running,
            "recoveryRequired" => OperationPhase.RecoveryRequired,
            "completed" => OperationPhase.Completed,
            _ => default
        };

        return value is "idle" or "running" or "recoveryRequired" or "completed";
    }
}
