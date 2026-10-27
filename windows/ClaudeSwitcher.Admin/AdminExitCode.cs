namespace ClaudeSwitcher.Admin;

public enum AdminExitCode
{
    Success = 0,
    InvalidArguments = 2,
    IdentityOrSessionMismatch = 3,
    UnsafeInstallRoot = 4,
    OperationFailed = 5
}
