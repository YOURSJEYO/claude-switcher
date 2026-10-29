using System.Security.Principal;
using System.Text.RegularExpressions;
using System.Xml;
using Microsoft.Win32;

namespace ClaudeSwitcher.Admin;

public sealed record LegacyBodyguardTaskValidation(bool IsValid, string Error, string? ScriptPath)
{
    public static LegacyBodyguardTaskValidation Success(string scriptPath) => new(true, string.Empty, scriptPath);
    public static LegacyBodyguardTaskValidation Failure(string error) => new(false, error, null);
}

public static class LegacyBodyguardTaskPolicy
{
    public const string TaskName = "ClaudeBodyguard";

    private const string TaskNamespace = "http://schemas.microsoft.com/windows/2004/02/mit/task";
    private static readonly Regex LegacyArgumentsPattern = new(
        "\\A-NoProfile[\\t ]+-WindowStyle[\\t ]+Hidden[\\t ]+-ExecutionPolicy[\\t ]+Bypass[\\t ]+-File[\\t ]+\"(?<path>[^\"\\r\\n]+)\"\\z",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly HashSet<string> RootChildren = new(StringComparer.Ordinal)
    {
        "RegistrationInfo", "Triggers", "Principals", "Settings", "Data", "Actions"
    };

    public static string ResolveUserProfilePath(string userSid)
    {
        if (!AdminRequest.IsUserSid(userSid))
        {
            throw new ArgumentException("A valid non-service user SID is required.", nameof(userSid));
        }

        using var key = Registry.LocalMachine.OpenSubKey(
            @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\" + userSid,
            writable: false);
        var profilePath = key?.GetValue("ProfileImagePath") as string;
        if (string.IsNullOrWhiteSpace(profilePath) || !Path.IsPathFullyQualified(profilePath))
        {
            throw new InvalidOperationException("The target user profile path could not be resolved safely.");
        }

        return Path.GetFullPath(profilePath);
    }

    public static LegacyBodyguardTaskValidation ValidateTaskXml(string xml, string userSid, string profileRoot)
    {
        if (!AdminRequest.IsUserSid(userSid))
        {
            return LegacyBodyguardTaskValidation.Failure("target user SID is invalid");
        }

        if (string.IsNullOrWhiteSpace(xml) || string.IsNullOrWhiteSpace(profileRoot) || !Path.IsPathFullyQualified(profileRoot))
        {
            return LegacyBodyguardTaskValidation.Failure("legacy task XML or user profile path is invalid");
        }

        try
        {
            var fullProfileRoot = Path.GetFullPath(profileRoot);
            var expectedScriptPath = Path.Combine(fullProfileRoot, ".claude-switcher", "claude-bodyguard.ps1");
            var document = LoadXml(xml);
            var root = document.DocumentElement;
            if (root is null || root.LocalName != "Task" || root.NamespaceURI != TaskNamespace)
            {
                return Failure("legacy task root is not the expected Task element");
            }

            if (!ValidateNamespacesAndAttributes(root))
            {
                return Failure("legacy task contains an external namespace or unexpected attribute");
            }

            if (!HasOnlyChildren(root, RootChildren) ||
                !HasUniqueDirectChild(root, "Settings") ||
                !HasUniqueDirectChild(root, "Principals") ||
                !HasUniqueDirectChild(root, "Triggers") ||
                !HasUniqueDirectChild(root, "Actions"))
            {
                return Failure("legacy task has duplicate or unsupported top-level nodes");
            }

            var settings = DirectChild(root, "Settings")!;
            var principals = DirectChild(root, "Principals")!;
            var triggers = DirectChild(root, "Triggers")!;
            var actions = DirectChild(root, "Actions")!;
            if (!HasOnlyChildren(principals, new[] { "Principal" }) ||
                !HasOnlyChildren(triggers, new[] { "LogonTrigger" }) ||
                !HasOnlyChildren(actions, new[] { "Exec" }))
            {
                return Failure("legacy task has duplicate or unsupported principals, triggers, or actions");
            }

            var principal = DirectChild(principals, "Principal");
            var trigger = DirectChild(triggers, "LogonTrigger");
            var action = DirectChild(actions, "Exec");
            if (principal is null || trigger is null || action is null)
            {
                return Failure("legacy task is missing its principal, logon trigger, or action");
            }

            if (!ValidateNamespacesAndAttributes(principal) ||
                !ValidateNamespacesAndAttributes(trigger) ||
                !ValidateNamespacesAndAttributes(actions) ||
                !ValidateNamespacesAndAttributes(action) ||
                !ValidateNamespacesAndAttributes(settings) ||
                !ValidateNamespacesAndAttributes(principals) ||
                !ValidateNamespacesAndAttributes(triggers))
            {
                return Failure("legacy task contains an external namespace or unexpected attribute");
            }

            if (!ValidatePrincipal(principal, userSid) ||
                !ValidateTrigger(trigger, userSid) ||
                !ValidateSettings(settings))
            {
                return Failure("legacy task identity, trigger, or settings do not match the fixed contract");
            }

            var principalId = principal.GetAttribute("id");
            var actionContext = actions.GetAttribute("Context");
            if (string.IsNullOrWhiteSpace(principalId) ||
                (!string.IsNullOrWhiteSpace(actionContext) && actionContext != principalId))
            {
                return Failure("legacy task action context is not bound to its only principal");
            }

            if (!HasOnlyChildren(action, new[] { "Command", "Arguments" }))
            {
                return Failure("legacy task action contains duplicate or unsupported elements");
            }

            var command = DirectChild(action, "Command")?.InnerText.Trim();
            var arguments = DirectChild(action, "Arguments")?.InnerText.Trim();
            var systemPowerShell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell",
                "v1.0",
                "powershell.exe");
            if (!string.Equals(command, "powershell.exe", StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(command, systemPowerShell, StringComparison.OrdinalIgnoreCase))
            {
                return Failure("legacy task action is not Windows PowerShell 5.1");
            }

            var match = arguments is null ? Match.Empty : LegacyArgumentsPattern.Match(arguments);
            if (!match.Success)
            {
                return Failure("legacy task action arguments are not the fixed legacy contract");
            }

            var actionScriptPath = match.Groups["path"].Value;
            if (!Path.IsPathFullyQualified(actionScriptPath) ||
                !string.Equals(Path.GetFullPath(actionScriptPath), Path.GetFullPath(expectedScriptPath), StringComparison.OrdinalIgnoreCase))
            {
                return Failure("legacy task action path is outside the target user profile");
            }

            return LegacyBodyguardTaskValidation.Success(Path.GetFullPath(expectedScriptPath));
        }
        catch (Exception error) when (error is XmlException or IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return LegacyBodyguardTaskValidation.Failure("legacy task XML could not be parsed safely");
        }
    }

    public static void ValidateScriptFile(string scriptPath, string expectedSid, string profileRoot)
    {
        if (!AdminRequest.IsUserSid(expectedSid) || !Path.IsPathFullyQualified(profileRoot) || !Path.IsPathFullyQualified(scriptPath))
        {
            throw new InvalidOperationException("Legacy bodyguard script path or user identity is invalid.");
        }

        var fullProfileRoot = Path.GetFullPath(profileRoot);
        var expectedScriptPath = Path.GetFullPath(Path.Combine(fullProfileRoot, ".claude-switcher", "claude-bodyguard.ps1"));
        var fullScriptPath = Path.GetFullPath(scriptPath);
        if (!string.Equals(fullScriptPath, expectedScriptPath, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Legacy bodyguard script is outside the target user profile.");
        }

        var file = new FileInfo(fullScriptPath);
        if (!file.Exists || (file.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidOperationException("Legacy bodyguard script is missing or is a reparse point.");
        }

        var current = fullScriptPath;
        while (current.StartsWith(fullProfileRoot, StringComparison.OrdinalIgnoreCase))
        {
            FileSystemInfo item = Directory.Exists(current) ? new DirectoryInfo(current) : new FileInfo(current);
            item.Refresh();
            if (!item.Exists || (item.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new InvalidOperationException("Legacy bodyguard script path contains a missing or reparse entry.");
            }

            if (string.Equals(current.TrimEnd(Path.DirectorySeparatorChar), fullProfileRoot.TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase))
            {
                break;
            }

            current = Path.GetDirectoryName(current) ??
                throw new InvalidOperationException("Legacy bodyguard script path escaped the user profile.");
        }

        var owner = file.GetAccessControl().GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
        if (owner is null || !string.Equals(owner.Value, expectedSid, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Legacy bodyguard script is not owned by the target user.");
        }
    }

    private static XmlDocument LoadXml(string xml)
    {
        var document = new XmlDocument { XmlResolver = null };
        using var reader = XmlReader.Create(new StringReader(xml), new XmlReaderSettings
        {
            DtdProcessing = DtdProcessing.Prohibit,
            XmlResolver = null,
            MaxCharactersInDocument = 1024 * 1024,
            MaxCharactersFromEntities = 0
        });
        document.Load(reader);
        return document;
    }

    private static bool ValidateNamespacesAndAttributes(XmlElement element)
    {
        foreach (var node in element.SelectNodes("descendant-or-self::*")!.OfType<XmlElement>())
        {
            if (node.NamespaceURI != TaskNamespace)
            {
                return false;
            }

            foreach (XmlAttribute attribute in node.Attributes)
            {
                if (attribute.NamespaceURI == "http://www.w3.org/2000/xmlns/")
                {
                    if (attribute.Value != TaskNamespace)
                    {
                        return false;
                    }

                    continue;
                }

                if (!string.IsNullOrEmpty(attribute.NamespaceURI))
                {
                    return false;
                }

                var allowed = node.LocalName switch
                {
                    "Task" => attribute.LocalName == "version",
                    "Principal" => attribute.LocalName == "id",
                    "Actions" => attribute.LocalName == "Context",
                    _ => false
                };
                if (!allowed)
                {
                    return false;
                }
            }
        }

        return true;
    }

    private static bool ValidatePrincipal(XmlElement principal, string expectedSid)
    {
        if (!HasOnlyChildren(principal, new[] { "UserId", "LogonType", "RunLevel" }))
        {
            return false;
        }

        var userId = DirectChild(principal, "UserId")?.InnerText.Trim();
        var logonType = DirectChild(principal, "LogonType")?.InnerText.Trim();
        var runLevel = DirectChild(principal, "RunLevel")?.InnerText.Trim();
        return string.Equals(userId, expectedSid, StringComparison.OrdinalIgnoreCase) &&
            (string.Equals(logonType, "InteractiveToken", StringComparison.OrdinalIgnoreCase) ||
             string.Equals(logonType, "Interactive", StringComparison.OrdinalIgnoreCase)) &&
            (string.Equals(runLevel, "LeastPrivilege", StringComparison.OrdinalIgnoreCase) ||
             string.Equals(runLevel, "Limited", StringComparison.OrdinalIgnoreCase));
    }

    private static bool ValidateTrigger(XmlElement trigger, string expectedSid)
    {
        var enabled = DirectChild(trigger, "Enabled")?.InnerText.Trim();
        if (!bool.TryParse(enabled, out var enabledValue) || !enabledValue)
        {
            return false;
        }

        var userNodes = trigger.ChildNodes.OfType<XmlElement>()
            .Where(child => child.NamespaceURI == TaskNamespace && child.LocalName == "UserId")
            .ToArray();
        if (userNodes.Length > 1 ||
            trigger.ChildNodes.OfType<XmlElement>().Any(child =>
                child.NamespaceURI != TaskNamespace || child.LocalName is not ("Enabled" or "UserId")) ||
            trigger.ChildNodes.OfType<XmlElement>().Count(child => child.LocalName == "Enabled") != 1)
        {
            return false;
        }

        return userNodes.Length == 0 ||
            string.Equals(userNodes[0].InnerText.Trim(), expectedSid, StringComparison.OrdinalIgnoreCase);
    }

    private static bool ValidateSettings(XmlElement settings)
    {
        var multipleInstances = DirectChild(settings, "MultipleInstancesPolicy")?.InnerText.Trim();
        var allowDemand = DirectChild(settings, "AllowStartOnDemand")?.InnerText.Trim();
        var executionTimeLimit = DirectChild(settings, "ExecutionTimeLimit")?.InnerText.Trim();
        var enabled = DirectChild(settings, "Enabled")?.InnerText.Trim();
        return string.Equals(multipleInstances, "IgnoreNew", StringComparison.OrdinalIgnoreCase) &&
            bool.TryParse(allowDemand, out var allowDemandValue) && allowDemandValue &&
            string.Equals(executionTimeLimit, "PT0S", StringComparison.OrdinalIgnoreCase) &&
            bool.TryParse(enabled, out var enabledValue) && enabledValue;
    }

    private static bool HasOnlyChildren(XmlElement parent, IEnumerable<string> allowed)
    {
        var allowedNames = allowed.ToHashSet(StringComparer.Ordinal);
        var children = parent.ChildNodes.OfType<XmlElement>().ToArray();
        return children.Length > 0 &&
            children.All(child => child.NamespaceURI == TaskNamespace && allowedNames.Contains(child.LocalName)) &&
            children.Select(child => child.LocalName).Distinct(StringComparer.Ordinal).Count() == children.Length;
    }

    private static bool HasUniqueDirectChild(XmlElement parent, string localName) =>
        parent.ChildNodes.OfType<XmlElement>()
            .Count(child => child.NamespaceURI == TaskNamespace && child.LocalName == localName) == 1;

    private static XmlElement? DirectChild(XmlElement parent, string localName)
    {
        var matches = parent.ChildNodes.OfType<XmlElement>()
            .Where(child => child.NamespaceURI == TaskNamespace && child.LocalName == localName)
            .ToArray();
        return matches.Length == 1 ? matches[0] : null;
    }

    private static LegacyBodyguardTaskValidation Failure(string error) => LegacyBodyguardTaskValidation.Failure(error);
}