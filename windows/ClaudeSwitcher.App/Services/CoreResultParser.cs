using System.Text.Json;
using System.Text.RegularExpressions;
using System.Net;
using System.Net.Sockets;
using ClaudeSwitcher.App.Models;

namespace ClaudeSwitcher.App.Services;

public enum CoreProtocolError
{
    EmptyOutput,
    InvalidJson,
    ProcessFailed,
    SchemaMismatch,
    CommandMismatch,
    OperationMismatch,
    CheckSetMismatch,
    UnknownCheckStatus,
    CheckBlockingMismatch,
    CanLaunchMismatch,
    InvalidField,
    InvalidTarget
}

public sealed class CoreProtocolException : Exception
{
    public CoreProtocolException(
        CoreProtocolError error,
        string message,
        int? exitCode = null,
        CoreResult? partialResult = null)
        : base(message)
    {
        Error = error;
        ExitCode = exitCode;
        PartialResult = partialResult;
    }

    public CoreProtocolError Error { get; }
    public int? ExitCode { get; }
    public CoreResult? PartialResult { get; }
}

public static partial class CoreResultParser
{
    public const int SupportedSchemaVersion = 1;

    public static readonly string[] RequiredCheckIds =
    [
        "proxy_engine",
        "tun_interface",
        "egress_country",
        "ip_consistency",
        "timezone",
        "locale",
        "ipv6",
        "dns",
        "webrtc",
        "bodyguard",
        "routing_rules",
        "client_language",
        "asn",
        "ecosystem"
    ];

    private static readonly HashSet<string> NonBlockingWarningIds =
        new(["ip_consistency", "asn"], StringComparer.Ordinal);

    public static CoreResult Parse(
        string stdout,
        int exitCode,
        CoreCommand expectedCommand,
        Guid expectedOperationId,
        string? target = null)
    {
        ValidateTarget(expectedCommand, target);

        if (string.IsNullOrWhiteSpace(stdout))
        {
            throw new CoreProtocolException(CoreProtocolError.EmptyOutput, "Core returned no protocol output.");
        }

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(stdout, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow
            });
        }
        catch (JsonException)
        {
            throw new CoreProtocolException(CoreProtocolError.InvalidJson, "Core output is not one valid JSON document.");
        }

        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw Invalid("Core result must be a JSON object.");
            }

            var schemaVersion = RequireInt32(root, "schemaVersion");
            if (schemaVersion != SupportedSchemaVersion)
            {
                throw new CoreProtocolException(CoreProtocolError.SchemaMismatch, "Core protocol schema is not supported.");
            }

            var operationIdText = RequireString(root, "operationId");
            if (!Guid.TryParseExact(operationIdText, "D", out var operationId) ||
                operationId != expectedOperationId ||
                !string.Equals(operationIdText, operationId.ToString("D"), StringComparison.Ordinal))
            {
                throw new CoreProtocolException(CoreProtocolError.OperationMismatch, "Core operation ID does not match the request.");
            }

            var commandText = RequireString(root, "command");
            if (!CoreCommandWire.TryParse(commandText, out var command) || command != expectedCommand)
            {
                throw new CoreProtocolException(CoreProtocolError.CommandMismatch, "Core command does not match the request.");
            }

            var success = RequireBoolean(root, "success");
            var code = RequireString(root, "code");
            if (code.Length == 0)
            {
                throw Invalid("Core result code must not be empty.");
            }

            var message = SensitiveDataRedactor.Redact(RequireString(root, "message"));
            IReadOnlyList<CheckResult> checks = Array.Empty<CheckResult>();
            var canLaunch = false;

            if (command == CoreCommand.CheckDetail)
            {
                (checks, canLaunch) = ParseChecks(root, success);
            }

            string? current = null;
            OperationPhase? phase = null;
            bool? recoveryRequired = null;
            Guid? activeOperationId = null;
            string? transactionPhase = null;

            if (command is CoreCommand.Status or CoreCommand.Switch)
            {
                (current, phase, recoveryRequired) = ParseState(root);
                (activeOperationId, transactionPhase) = ParseOperationDetail(root, phase.Value, recoveryRequired.Value);
                if (command == CoreCommand.Switch &&
                    success &&
                    phase == OperationPhase.Completed &&
                    !string.Equals(current, target, StringComparison.Ordinal))
                {
                    throw Invalid("Completed switch must report the requested target as current.");
                }
            }

            var result = new CoreResult(
                schemaVersion,
                operationId,
                command,
                success,
                code,
                message,
                exitCode,
                checks,
                canLaunch,
                current,
                phase,
                recoveryRequired,
                activeOperationId,
                transactionPhase);

            if (exitCode != 0)
            {
                throw new CoreProtocolException(
                    CoreProtocolError.ProcessFailed,
                    $"Core exited with code {exitCode}.",
                    exitCode,
                    success ? null : result);
            }

            return result;
        }
    }

    private static (IReadOnlyList<CheckResult> Checks, bool CanLaunch) ParseChecks(JsonElement root, bool success)
    {
        var checksElement = RequireProperty(root, "checks");
        if (checksElement.ValueKind != JsonValueKind.Array)
        {
            throw Invalid("Core checks must be an array.");
        }

        var canLaunchField = RequireBoolean(root, "canLaunch");
        if (checksElement.GetArrayLength() != RequiredCheckIds.Length)
        {
            throw new CoreProtocolException(CoreProtocolError.CheckSetMismatch, "Core must return exactly 14 checks.");
        }

        var checks = new CheckResult[RequiredCheckIds.Length];
        for (var index = 0; index < checks.Length; index++)
        {
            var item = checksElement[index];
            if (item.ValueKind != JsonValueKind.Object)
            {
                throw Invalid("Each core check must be an object.");
            }

            var id = RequireString(item, "id");
            if (!string.Equals(id, RequiredCheckIds[index], StringComparison.Ordinal))
            {
                throw new CoreProtocolException(CoreProtocolError.CheckSetMismatch, "Core check IDs are missing, duplicated, unknown, or out of order.");
            }

            var name = RequireString(item, "name");
            if (name.Length == 0)
            {
                throw Invalid("Core check name must not be empty.");
            }

            var statusText = RequireString(item, "status");
            var status = statusText switch
            {
                "ok" => CheckStatus.Ok,
                "warn" => CheckStatus.Warn,
                "fail" => CheckStatus.Fail,
                "unknown" => CheckStatus.Unknown,
                _ => throw new CoreProtocolException(CoreProtocolError.UnknownCheckStatus, "Core returned an unknown check status.")
            };

            var blocking = RequireBoolean(item, "blocking");
            var expectedBlocking = status switch
            {
                CheckStatus.Ok => false,
                CheckStatus.Warn => !NonBlockingWarningIds.Contains(id),
                _ => true
            };

            if (blocking != expectedBlocking)
            {
                throw new CoreProtocolException(CoreProtocolError.CheckBlockingMismatch, "Core check blocking flag contradicts its status.");
            }

            var detail = SensitiveDataRedactor.Redact(RequireString(item, "detail"));
            checks[index] = new CheckResult(id, name, status, blocking, detail);
        }

        var expectedCanLaunch = success && checks.All(check => !check.Blocking);
        if (canLaunchField != expectedCanLaunch)
        {
            throw new CoreProtocolException(CoreProtocolError.CanLaunchMismatch, "Core canLaunch contradicts the protocol checks.");
        }

        return (Array.AsReadOnly(checks), canLaunchField);
    }

    private static (string Current, OperationPhase Phase, bool RecoveryRequired) ParseState(JsonElement root)
    {
        var current = RequireString(root, "current");
        if (current is not ("A" or "B" or "none"))
        {
            throw Invalid("Core current account must be A, B, or none.");
        }

        var phaseText = RequireString(root, "phase");
        if (!OperationPhaseWire.TryParse(phaseText, out var phase))
        {
            throw Invalid("Core operation phase is invalid.");
        }

        var recoveryRequired = RequireBoolean(root, "recoveryRequired");
        if ((phase == OperationPhase.RecoveryRequired) != recoveryRequired)
        {
            throw Invalid("Core recoveryRequired contradicts the operation phase.");
        }

        return (current, phase, recoveryRequired);
    }

    private static (Guid? ActiveOperationId, string? TransactionPhase) ParseOperationDetail(
        JsonElement root,
        OperationPhase phase,
        bool recoveryRequired)
    {
        var activeOperationId = OptionalCanonicalGuid(root, "activeOperationId");
        var transactionPhase = OptionalNonEmptyString(root, "transactionPhase");
        var operationOngoing = phase is OperationPhase.Running or OperationPhase.RecoveryRequired || recoveryRequired;

        if (operationOngoing && (activeOperationId is null || transactionPhase is null))
        {
            throw Invalid("Ongoing or recoverable operations require activeOperationId and transactionPhase.");
        }

        if (phase == OperationPhase.Idle && (activeOperationId is not null || transactionPhase is not null))
        {
            throw Invalid("Idle status must not report an active operation.");
        }

        return (activeOperationId, transactionPhase);
    }

    private static Guid? OptionalCanonicalGuid(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        if (value.ValueKind != JsonValueKind.String || value.GetString() is not { } text ||
            !Guid.TryParseExact(text, "D", out var guid) ||
            !string.Equals(text, guid.ToString("D"), StringComparison.Ordinal))
        {
            throw Invalid($"Core field {name} must be a canonical GUID or null.");
        }

        return guid;
    }

    private static string? OptionalNonEmptyString(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        if (value.ValueKind != JsonValueKind.String || value.GetString() is not { Length: > 0 } text)
        {
            throw Invalid($"Core field {name} must be a nonempty string or null.");
        }

        return text;
    }

    private static void ValidateTarget(CoreCommand command, string? target)
    {
        if (command == CoreCommand.Switch)
        {
            if (target is not ("A" or "B"))
            {
                throw new CoreProtocolException(CoreProtocolError.InvalidTarget, "Switch target must be A or B.");
            }
        }
        else if (target is not null)
        {
            throw new CoreProtocolException(CoreProtocolError.InvalidTarget, "Only switch accepts a target.");
        }
    }

    private static JsonElement RequireProperty(JsonElement element, string name)
    {
        if (!element.TryGetProperty(name, out var value))
        {
            throw Invalid($"Core result is missing required field {name}.");
        }

        return value;
    }

    private static string RequireString(JsonElement element, string name)
    {
        var value = RequireProperty(element, name);
        if (value.ValueKind != JsonValueKind.String || value.GetString() is not { } text)
        {
            throw Invalid($"Core field {name} must be a string.");
        }

        return text;
    }

    private static bool RequireBoolean(JsonElement element, string name)
    {
        var value = RequireProperty(element, name);
        if (value.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            throw Invalid($"Core field {name} must be a boolean.");
        }

        return value.GetBoolean();
    }

    private static int RequireInt32(JsonElement element, string name)
    {
        var value = RequireProperty(element, name);
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out var number))
        {
            throw Invalid($"Core field {name} must be an integer.");
        }

        return number;
    }

    private static CoreProtocolException Invalid(string message) =>
        new(CoreProtocolError.InvalidField, message);
}

public static partial class SensitiveDataRedactor
{
    private const string Replacement = "[redacted]";

    public static string Redact(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return value;
        }

        var redacted = CredentialsInUrlRegex().Replace(value, "$1" + Replacement + "@");
        redacted = KeyValueSecretRegex().Replace(redacted, "$1=" + Replacement);
        redacted = BearerTokenRegex().Replace(redacted, "Bearer " + Replacement);
        redacted = Ipv6CandidateRegex().Replace(redacted, RedactIpv6Candidate);
        redacted = Ipv4Regex().Replace(redacted, Replacement);
        redacted = EmailRegex().Replace(redacted, Replacement);
        return redacted;
    }

    [GeneratedRegex(@"(?i)\b(https?|socks5h?)://[^/\s:@]+:[^/\s@]+@")]
    private static partial Regex CredentialsInUrlRegex();

    [GeneratedRegex(@"(?i)\b(password|passwd|pwd|token|secret|api[_-]?key|authorization)\s*=\s*[^\s,;]+")]
    private static partial Regex KeyValueSecretRegex();

    [GeneratedRegex(@"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+")]
    private static partial Regex BearerTokenRegex();

    [GeneratedRegex(@"\b(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}(?:/\d{1,2})?\b")]
    private static partial Regex Ipv4Regex();

    [GeneratedRegex(@"(?<![0-9A-Za-z:])[0-9A-Za-z:.]*:[0-9A-Za-z:.]*(?![0-9A-Za-z:])")]
    private static partial Regex Ipv6CandidateRegex();

    private static string RedactIpv6Candidate(Match match)
    {
        var token = match.Value;
        var addressLength = token.Length;
        while (addressLength > 0 && token[addressLength - 1] is '.' or ',')
        {
            addressLength--;
        }

        var candidate = token[..addressLength];
        if (!IPAddress.TryParse(candidate, out var address) ||
            address.AddressFamily != AddressFamily.InterNetworkV6 ||
            !IsPlausibleIpv6(candidate))
        {
            return token;
        }

        return Replacement + token[addressLength..];
    }

    private static bool IsPlausibleIpv6(string candidate)
    {
        if (candidate.Contains("::", StringComparison.Ordinal))
        {
            return true;
        }

        var groups = candidate.Split(':');
        var groupCount = groups.Length + (groups[^1].Contains('.', StringComparison.Ordinal) ? 1 : 0);
        return groupCount == 8;
    }

    [GeneratedRegex(@"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", RegexOptions.IgnoreCase)]
    private static partial Regex EmailRegex();
}
