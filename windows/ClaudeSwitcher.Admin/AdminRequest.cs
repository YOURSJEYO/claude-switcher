using System.Globalization;
using System.Security.Principal;

namespace ClaudeSwitcher.Admin;

public sealed record AdminRequest(
    AdminOperation Operation,
    string UserSid,
    int? SessionId,
    string? TimeZoneId)
{
    private static readonly HashSet<string> AllowedOptions = new(StringComparer.Ordinal)
    {
        "--operation",
        "--user-sid",
        "--session-id",
        "--time-zone-id"
    };

    public static bool TryParse(IReadOnlyList<string>? args, out AdminRequest? request, out string error)
    {
        request = null;
        error = string.Empty;
        if (args is null || args.Count == 0)
        {
            error = "operation is required";
            return false;
        }

        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var index = 0; index < args.Count; index++)
        {
            var option = args[index];
            if (string.IsNullOrEmpty(option) || !option.StartsWith("--", StringComparison.Ordinal) ||
                !AllowedOptions.Contains(option))
            {
                error = $"unknown option '{option}'";
                return false;
            }

            if (values.ContainsKey(option))
            {
                error = $"duplicate option '{option}'";
                return false;
            }

            if (index + 1 >= args.Count || string.IsNullOrEmpty(args[index + 1]) ||
                args[index + 1].StartsWith("--", StringComparison.Ordinal))
            {
                error = $"option '{option}' requires a value";
                return false;
            }

            values[option] = args[++index];
        }

        if (!values.TryGetValue("--operation", out var operationText) ||
            !AdminOperationNames.TryParse(operationText, out var operation))
        {
            error = "operation is missing or invalid";
            return false;
        }

        if (!values.TryGetValue("--user-sid", out var userSid))
        {
            error = "user-sid is required";
            return false;
        }

        if (!IsUserSid(userSid))
        {
            error = "user-sid must be a non-service Windows user SID";
            return false;
        }

        int? sessionId = null;
        if (values.TryGetValue("--session-id", out var sessionText))
        {
            if (!int.TryParse(sessionText, NumberStyles.None, CultureInfo.InvariantCulture, out var parsedSession) ||
                parsedSession <= 0)
            {
                error = "session-id must be a positive integer";
                return false;
            }

            sessionId = parsedSession;
        }

        if (operation is AdminOperation.RegisterBodyguardTask or AdminOperation.RepairSystem && !sessionId.HasValue)
        {
            error = "session-id is required for register-bodyguard-task and repair-system";
            return false;
        }

        string? timeZoneId = null;
        if (values.TryGetValue("--time-zone-id", out var timeZoneText))
        {
            if (operation is not (AdminOperation.SetTimeZone or AdminOperation.RepairSystem))
            {
                error = "time-zone-id is only valid for set-time-zone and repair-system";
                return false;
            }

            if (!IsSafeWindowsTimeZone(timeZoneText))
            {
                error = "time-zone-id is not a known Windows time zone";
                return false;
            }

            timeZoneId = timeZoneText;
        }

        if (operation == AdminOperation.SetTimeZone && timeZoneId is null)
        {
            error = "time-zone-id is required for set-time-zone";
            return false;
        }

        request = new AdminRequest(operation, userSid, sessionId, timeZoneId);
        return true;
    }

    public static bool IsUserSid(string? value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Any(char.IsControl) ||
            value.Contains(';') || value.Contains('\\') || value.Contains('/') ||
            value.Contains("..", StringComparison.Ordinal))
        {
            return false;
        }

        if (!RegexSidPattern.IsMatch(value))
        {
            return false;
        }

        try
        {
            var sid = new SecurityIdentifier(value);
            return !sid.IsWellKnown(WellKnownSidType.LocalSystemSid) &&
                   !sid.IsWellKnown(WellKnownSidType.NetworkServiceSid) &&
                   !sid.IsWellKnown(WellKnownSidType.LocalServiceSid) &&
                   !sid.IsWellKnown(WellKnownSidType.BuiltinAdministratorsSid) &&
                   !sid.IsWellKnown(WellKnownSidType.BuiltinUsersSid);
        }
        catch (ArgumentException)
        {
            return false;
        }
    }

    public static bool IsSafeWindowsTimeZone(string? value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Any(char.IsControl) ||
            value.Contains(';') || value.Contains('\\') || value.Contains('/') ||
            value.Contains("..", StringComparison.Ordinal))
        {
            return false;
        }

        try
        {
            _ = TimeZoneInfo.FindSystemTimeZoneById(value);
            return true;
        }
        catch (TimeZoneNotFoundException)
        {
            return false;
        }
        catch (InvalidTimeZoneException)
        {
            return false;
        }
    }

    private static readonly System.Text.RegularExpressions.Regex RegexSidPattern =
        new("^S-1-(?:5-21|12-1)(?:-[0-9]+){4}$", System.Text.RegularExpressions.RegexOptions.CultureInvariant);
}
