namespace ClaudeSwitcher.Admin;

public sealed record InstallRootResult(string? RootPath, string Error)
{
    public bool IsSuccess => RootPath is not null;

    public static InstallRootResult Success(string rootPath) => new(rootPath, string.Empty);

    public static InstallRootResult Failure(string error) => new(null, error);
}

public interface IInstallRootProvider
{
    InstallRootResult Resolve(InteractiveIdentity identity);
}
