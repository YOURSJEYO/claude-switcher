namespace ClaudeSwitcher.Admin;

public sealed record InteractiveIdentity(string UserSid, int SessionId);

public sealed record InteractiveIdentityResult(InteractiveIdentity? Identity, string Error)
{
    public bool IsSuccess => Identity is not null;

    public static InteractiveIdentityResult Success(string userSid, int sessionId) =>
        new(new InteractiveIdentity(userSid, sessionId), string.Empty);

    public static InteractiveIdentityResult Failure(string error) => new(null, error);
}

public interface IInteractiveIdentityResolver
{
    InteractiveIdentityResult Resolve(int? requestedSessionId);
}
public static class WtsSessionPolicy
{
    private const int ActiveConnectionState = 0;

    public static bool IsActiveConnectionState(int? connectionState) =>
        connectionState == ActiveConnectionState;

    public static bool IsSupportedTokenSession(int tokenSessionId, int requestedSessionId, string? sid) =>
        tokenSessionId == requestedSessionId && AdminRequest.IsUserSid(sid);


    public static string? SelectUnambiguousUserSid(IEnumerable<string> candidates) =>
        SelectUnambiguousUserSid(candidates, out _);

    public static string? SelectUnambiguousUserSid(IEnumerable<string> candidates, out bool ambiguous)
    {
        ArgumentNullException.ThrowIfNull(candidates);
        var supported = candidates
            .Where(AdminRequest.IsUserSid)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(2)
            .ToArray();
        ambiguous = supported.Length > 1;
        return supported.Length == 1 ? supported[0] : null;
    }
}
