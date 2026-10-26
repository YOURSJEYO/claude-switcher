namespace ClaudeSwitcher.App.Models;

public enum CheckStatus
{
    Ok,
    Warn,
    Fail,
    Unknown
}

public sealed record CheckResult(
    string Id,
    string Name,
    CheckStatus Status,
    bool Blocking,
    string Detail)
{
    public bool IsWarning => Status == CheckStatus.Warn;
    public bool IsGreen => Status == CheckStatus.Ok;
}
