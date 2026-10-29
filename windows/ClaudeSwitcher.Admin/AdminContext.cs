namespace ClaudeSwitcher.Admin;

public sealed class AdminContext
{
    private readonly IInteractiveIdentityResolver identityResolver;
    private readonly IInstallRootProvider installRootProvider;
    private readonly ISystemOperations systemOperations;

    public AdminContext(
        IInteractiveIdentityResolver identityResolver,
        IInstallRootProvider installRootProvider,
        ISystemOperations systemOperations)
    {
        this.identityResolver = identityResolver ?? throw new ArgumentNullException(nameof(identityResolver));
        this.installRootProvider = installRootProvider ?? throw new ArgumentNullException(nameof(installRootProvider));
        this.systemOperations = systemOperations ?? throw new ArgumentNullException(nameof(systemOperations));
    }

    public AdminResult Execute(AdminRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);

        var identityResult = identityResolver.Resolve(request.SessionId);
        if (!identityResult.IsSuccess || identityResult.Identity is null)
        {
            return AdminResult.Failure(
                AdminExitCode.IdentityOrSessionMismatch,
                identityResult.Error.Length == 0 ? "interactive user identity could not be verified" : identityResult.Error);
        }

        var identity = identityResult.Identity;
        if (!string.Equals(identity.UserSid, request.UserSid, StringComparison.OrdinalIgnoreCase) ||
            (request.SessionId.HasValue && identity.SessionId != request.SessionId.Value))
        {
            return AdminResult.Failure(
                AdminExitCode.IdentityOrSessionMismatch,
                "requested user SID/session does not match the interactive user session");
        }

        var rootResult = installRootProvider.Resolve(identity);
        if (!rootResult.IsSuccess || rootResult.RootPath is null)
        {
            return AdminResult.Failure(
                AdminExitCode.UnsafeInstallRoot,
                rootResult.Error.Length == 0 ? "install root validation failed" : rootResult.Error);
        }

        var completedStages = new List<string>();
        var currentStage = "setup";
        try
        {
            switch (request.Operation)
            {
                case AdminOperation.RepairSystem:
                    if (request.TimeZoneId is not null)
                    {
                        currentStage = "time-zone";
                        systemOperations.SetTimeZone(request.TimeZoneId);
                        completedStages.Add(currentStage);
                    }
                    currentStage = "ipv6";
                    systemOperations.DisableIpv6();
                    completedStages.Add(currentStage);
                    currentStage = "dns";
                    systemOperations.FlushDns();
                    completedStages.Add(currentStage);
                    currentStage = "bodyguard-task";
                    systemOperations.EnsureBodyguardTask(BodyguardTaskPaths.Create(rootResult.RootPath, request.UserSid), request.UserSid, identity.SessionId);
                    completedStages.Add(currentStage);
                    break;
                case AdminOperation.SetTimeZone:
                    currentStage = "time-zone";
                    systemOperations.SetTimeZone(request.TimeZoneId!);
                    break;
                case AdminOperation.DisableIpv6:
                    currentStage = "ipv6";
                    systemOperations.DisableIpv6();
                    break;
                case AdminOperation.FlushDns:
                    currentStage = "dns";
                    systemOperations.FlushDns();
                    break;
                case AdminOperation.RegisterBodyguardTask:
                    currentStage = "bodyguard-task";
                    var registerPaths = BodyguardTaskPaths.Create(rootResult.RootPath, request.UserSid);
                    systemOperations.EnsureBodyguardTask(registerPaths, request.UserSid, identity.SessionId);
                    break;
                case AdminOperation.RemoveBodyguardTask:
                    currentStage = "remove-bodyguard-task";
                    var removePaths = BodyguardTaskPaths.Create(rootResult.RootPath, request.UserSid);
                    systemOperations.RemoveBodyguardTask(removePaths, request.UserSid);
                    break;
                case AdminOperation.MigrateLegacyBodyguard:
                    currentStage = "migrate-legacy-bodyguard";
                    var migrationPaths = BodyguardTaskPaths.Create(rootResult.RootPath, request.UserSid);
                    systemOperations.MigrateLegacyBodyguardTask(migrationPaths, request.UserSid, identity.SessionId);
                    break;
                default:
                    return AdminResult.Failure(AdminExitCode.InvalidArguments, "unsupported operation");
            }
        }
        catch (Exception)
        {
            var completed = completedStages.Count == 0 ? "none" : string.Join(",", completedStages);
            return AdminResult.Failure(
                AdminExitCode.OperationFailed,
                $"fixed operation failed; failed-stage={currentStage}; completed-stages={completed}; later steps were not run");
        }

        return AdminResult.Ok();
    }
}
