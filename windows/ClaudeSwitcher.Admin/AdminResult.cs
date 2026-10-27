namespace ClaudeSwitcher.Admin;

public sealed record AdminResult(AdminExitCode ExitCode, string Error = "")
{
    public bool Success => ExitCode == AdminExitCode.Success;

    public static AdminResult Ok() => new(AdminExitCode.Success);

    public static AdminResult Failure(AdminExitCode code, string error) => new(code, error);
}
