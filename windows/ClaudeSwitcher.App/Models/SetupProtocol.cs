using System.Globalization;
using System.Text.Json;

namespace ClaudeSwitcher.App.Models;

public sealed record SetupEffect(string Id, string Title, string Description);

public sealed record SetupPreview(
    string Country,
    string TimeZoneId,
    string Culture,
    string ProxyMode,
    string ProxyGroup,
    IReadOnlyList<SetupEffect> ProposedEffects);

public sealed record SetupApplyResult(
    bool Success,
    string Stage,
    string Code,
    string Message);

public sealed class SetupProtocolException : Exception
{
    public SetupProtocolException(string message)
        : base(message)
    {
    }

    public SetupProtocolException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public static class SetupProtocolParser
{
    public static readonly IReadOnlyList<string> ProxyModes =
    [
        "auto",
        "clash-verge",
        "sing-box",
        "clashx",
        "surge",
        "wireguard",
        "other"
    ];

    private static readonly string[] PreviewFields =
    [
        "schemaVersion",
        "success",
        "country",
        "timeZoneId",
        "culture",
        "proxyMode",
        "proxyGroup"
    ];

    private static readonly string[] ApplyFields =
    [
        "schemaVersion",
        "success",
        "stage",
        "code",
        "message"
    ];

    private static readonly IReadOnlyList<SetupEffect> Effects =
    [
        new("time zone", "时区", "将 Windows 系统时区切换为上方已审核的时区。"),
        new("IPv6", "IPv6", "将关闭 IPv6，避免绕过代理泄漏。"),
        new("DNS cache", "DNS 缓存", "将刷新 DNS 缓存，清除旧解析结果。"),
        new("bodyguard task", "保镖任务", "将为当前普通用户注册登录时启动的保镖任务。")
    ];

    private static readonly Lazy<HashSet<string>> KnownCountries = new(CreateKnownCountries);

    public static SetupPreview ParsePreview(string json)
    {
        using var document = ParseDocument(json);
        var root = RequireObject(document.RootElement);
        RequireExactFields(root, PreviewFields);

        RequireSchemaVersion(root);
        if (RequireBoolean(root, "success") is not true)
        {
            throw new SetupProtocolException("The setup preview did not succeed.");
        }

        var country = RequireSafeString(root, "country", 2, 2);
        if (country == "CN" || !KnownCountries.Value.Contains(country))
        {
            throw new SetupProtocolException("The setup preview country is not supported.");
        }

        var timeZoneId = RequireSafeString(root, "timeZoneId", 1, 128);
        try
        {
            _ = TimeZoneInfo.FindSystemTimeZoneById(timeZoneId);
        }
        catch (Exception exception) when (exception is TimeZoneNotFoundException or InvalidTimeZoneException)
        {
            throw new SetupProtocolException("The setup preview time zone is invalid.", exception);
        }

        var culture = RequireSafeString(root, "culture", 1, 64);
        if (!CultureInfo.GetCultures(CultureTypes.AllCultures)
                .Any(candidate => string.Equals(candidate.Name, culture, StringComparison.Ordinal)))
        {
            throw new SetupProtocolException("The setup preview culture is invalid.");
        }

        var proxyMode = RequireSafeString(root, "proxyMode", 1, 32);
        if (!ProxyModes.Contains(proxyMode, StringComparer.Ordinal))
        {
            throw new SetupProtocolException("The setup preview proxy mode is not allowlisted.");
        }

        var proxyGroup = RequireOptionalSafeString(root, "proxyGroup", 128);
        if (proxyMode == "clash-verge")
        {
            if (string.IsNullOrWhiteSpace(proxyGroup))
            {
                throw new SetupProtocolException("The setup preview requires a proxy group for clash-verge.");
            }

            ValidateProxyGroup(proxyGroup);
        }
        else
        {
            if (proxyGroup.Length > 0)
            {
                throw new SetupProtocolException("The setup preview proxy group must be empty for non-Clash modes.");
            }
        }

        return new SetupPreview(country, timeZoneId, culture, proxyMode, proxyGroup, Effects);
    }

    public static SetupApplyResult ParseApply(string json)
    {
        using var document = ParseDocument(json);
        var root = RequireObject(document.RootElement);
        RequireExactFields(root, ApplyFields);

        RequireSchemaVersion(root);
        var success = RequireBoolean(root, "success");
        var stage = RequireSafeString(root, "stage", 1, 64);
        var code = RequireSafeString(root, "code", 1, 64);
        var message = RequireSafeString(root, "message", 1, 4096);

        if (!IsToken(stage) || !IsToken(code))
        {
            throw new SetupProtocolException("The setup result stage or code contains unsupported characters.");
        }

        if (success && (stage != "completed" || code != "ok"))
        {
            throw new SetupProtocolException("A successful setup result must report the completed stage and ok code.");
        }

        return new SetupApplyResult(success, stage, code, message);
    }

    private static JsonDocument ParseDocument(string json)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            throw new SetupProtocolException("The setup protocol result is empty.");
        }

        try
        {
            return JsonDocument.Parse(json, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow
            });
        }
        catch (JsonException exception)
        {
            throw new SetupProtocolException("The setup protocol result is not valid JSON.", exception);
        }
    }

    private static JsonElement RequireObject(JsonElement root) =>
        root.ValueKind == JsonValueKind.Object
            ? root
            : throw new SetupProtocolException("The setup protocol result must be an object.");

    private static void RequireExactFields(JsonElement root, IReadOnlyCollection<string> expected)
    {
        var names = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in root.EnumerateObject())
        {
            if (!names.Add(property.Name) || !expected.Contains(property.Name, StringComparer.Ordinal))
            {
                throw new SetupProtocolException("The setup protocol result contains duplicate or unexpected fields.");
            }
        }

        if (names.Count != expected.Count)
        {
            throw new SetupProtocolException("The setup protocol result is missing required fields.");
        }
    }

    private static void RequireSchemaVersion(JsonElement root)
    {
        if (!root.TryGetProperty("schemaVersion", out var property) ||
            property.ValueKind != JsonValueKind.Number ||
            !property.TryGetInt32(out var schemaVersion) ||
            schemaVersion != 1)
        {
            throw new SetupProtocolException("The setup protocol schema version is unsupported.");
        }
    }

    private static bool RequireBoolean(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var property) ||
            property.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            throw new SetupProtocolException($"The setup protocol field '{name}' must be a boolean.");
        }

        return property.GetBoolean();
    }

    private static string RequireOptionalSafeString(JsonElement root, string name, int maxLength)
    {
        if (!root.TryGetProperty(name, out var property) || property.ValueKind != JsonValueKind.String)
        {
            throw new SetupProtocolException($"The setup protocol field '{name}' must be a string.");
        }

        var value = property.GetString() ?? string.Empty;
        if (value.Length > maxLength || value.Any(char.IsControl) ||
            !string.Equals(value, value.Trim(), StringComparison.Ordinal))
        {
            throw new SetupProtocolException($"The setup protocol field '{name}' is invalid.");
        }

        return value;
    }

    private static void ValidateProxyGroup(string proxyGroup)
    {
        if (string.IsNullOrWhiteSpace(proxyGroup) ||
            proxyGroup.Length > 128 ||
            proxyGroup.Contains("..", StringComparison.Ordinal) ||
            proxyGroup.Any(character => character is ';' or '`' or '$' or '"' or '\'' or '<' or '>' or '|' or '&' or '{' or '}' or '\\' or '/'))
        {
            throw new SetupProtocolException("The setup preview proxy group is invalid.");
        }
    }

    private static string RequireSafeString(JsonElement root, string name, int minLength, int maxLength)
    {
        if (!root.TryGetProperty(name, out var property) || property.ValueKind != JsonValueKind.String)
        {
            throw new SetupProtocolException($"The setup protocol field '{name}' must be a string.");
        }

        var value = property.GetString();
        if (string.IsNullOrWhiteSpace(value) || value.Length < minLength || value.Length > maxLength ||
            value.Any(char.IsControl))
        {
            throw new SetupProtocolException($"The setup protocol field '{name}' is invalid.");
        }

        return value;
    }

    private static bool IsToken(string value) =>
        value.All(character => char.IsAsciiLetterOrDigit(character) || character is '.' or '_' or '-');

    private static HashSet<string> CreateKnownCountries()
    {
        var countries = new HashSet<string>(StringComparer.Ordinal);
        foreach (var culture in CultureInfo.GetCultures(CultureTypes.SpecificCultures))
        {
            try
            {
                var region = new RegionInfo(culture.Name);
                if (region.TwoLetterISORegionName.Length == 2)
                {
                    countries.Add(region.TwoLetterISORegionName);
                }
            }
            catch (ArgumentException)
            {
            }
        }

        countries.Remove("CN");
        return countries;
    }
}
