namespace ClaudeSwitcher.Admin;

public sealed record BodyguardTaskPaths(string RootPath, string ScriptPath, string TaskName)
{
    public string PowerShellPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
    public string ActionArguments => $"-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File \"{ScriptPath}\"";
    public static BodyguardTaskPaths Create(string rootPath, string userSid)
    {
        if (!AdminRequest.IsUserSid(userSid))
        {
            throw new ArgumentException("A valid non-service user SID is required.", nameof(userSid));
        }

        if (string.IsNullOrWhiteSpace(rootPath))
        {
            throw new ArgumentException("A nonempty install root is required.", nameof(rootPath));
        }

        var fullRoot = Path.GetFullPath(rootPath);
        return new BodyguardTaskPaths(
            fullRoot,
            Path.Combine(fullRoot, "scripts", "claude-bodyguard.ps1"),
            "ClaudeSwitcher.Bodyguard." + userSid);
    }
}

public sealed record ExistingBodyguardTask(
    bool Exists,
    string? PrincipalSid,
    string? ActionCommand,
    string? ActionArguments,
    string? TaskName,
    string? LogonType,
    string? RunLevel,
    string? TriggerKind,
    string? TriggerSid,
    bool Enabled,
    bool AllowDemandStart,
    string? ActionContext,
    string? MultipleInstancesPolicy,
    bool DisallowStartIfOnBatteries,
    bool StopIfGoingOnBatteries,
    string? ExecutionTimeLimit)
{
    public ExistingBodyguardTask(bool exists, string? principalSid, string? actionPath, string? taskName)
        : this(exists, principalSid, actionPath, null, taskName, null, null, null, null, false, false, null, null, false, false, null) { }
}

public enum BodyguardTaskDecision
{
    NoChange,
    Create,
    Remove,
    Reject
}

public static class BodyguardTaskPolicy
{
    private const string TaskNamespace = "http://schemas.microsoft.com/windows/2004/02/mit/task";

    public static BodyguardTaskDecision Evaluate(
        BodyguardTaskPaths expected,
        string expectedSid,
        ExistingBodyguardTask existing)
    {
        if (!existing.Exists)
        {
            return BodyguardTaskDecision.Create;
        }

        if (!string.Equals(existing.TaskName, expected.TaskName, StringComparison.Ordinal) ||
            !string.Equals(existing.PrincipalSid, expectedSid, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(
                existing.ActionCommand,
                expected.PowerShellPath,
                StringComparison.OrdinalIgnoreCase) ||
            existing.ActionArguments != expected.ActionArguments ||
            existing.LogonType != "InteractiveToken" || existing.RunLevel != "LeastPrivilege" ||
            existing.TriggerKind != "LogonTrigger" || existing.TriggerSid != expectedSid ||
            !existing.Enabled || !existing.AllowDemandStart ||
            existing.ActionContext != "Author" ||
            existing.MultipleInstancesPolicy != "IgnoreNew" ||
            existing.DisallowStartIfOnBatteries || existing.StopIfGoingOnBatteries ||
            existing.ExecutionTimeLimit != "PT0S")
        {
            return BodyguardTaskDecision.Reject;
        }

        return BodyguardTaskDecision.NoChange;
    }

    public static BodyguardTaskDecision EvaluateRemoval(
        BodyguardTaskPaths expected,
        string expectedSid,
        ExistingBodyguardTask existing)
    {
        if (!existing.Exists)
        {
            return BodyguardTaskDecision.NoChange;
        }

        return Evaluate(expected, expectedSid, existing) == BodyguardTaskDecision.NoChange
            ? BodyguardTaskDecision.Remove
            : BodyguardTaskDecision.Reject;
    }

    public static ExistingBodyguardTask ParseTaskXml(string xml, string taskName)
    {
        var document = new System.Xml.XmlDocument { XmlResolver = null };
        using var reader = System.Xml.XmlReader.Create(new StringReader(xml), new System.Xml.XmlReaderSettings
        {
            DtdProcessing = System.Xml.DtdProcessing.Prohibit,
            XmlResolver = null,
            MaxCharactersInDocument = 65536
        });
        document.Load(reader);
        var root = document.DocumentElement;
        if (root is null || root.LocalName != "Task" || root.NamespaceURI != TaskNamespace ||
            document.GetElementsByTagName("*").OfType<System.Xml.XmlElement>().Any(element => element.NamespaceURI != TaskNamespace))
        {
            return InvalidTask(taskName);
        }

        var namespaces = new System.Xml.XmlNamespaceManager(document.NameTable);
        namespaces.AddNamespace("t", "http://schemas.microsoft.com/windows/2004/02/mit/task");
        var settings = SingleNode(root, "t:Settings", namespaces);
        var principals = SingleNode(root, "t:Principals", namespaces);
        var principal = SingleNode(root, "t:Principals/t:Principal", namespaces);
        var actions = SingleNode(root, "t:Actions", namespaces);
        var action = SingleNode(root, "t:Actions/t:Exec", namespaces);
        var triggers = SingleNode(root, "t:Triggers", namespaces);
        var trigger = SingleNode(root, "t:Triggers/t:LogonTrigger", namespaces);
        if (root is null || principals is null || principal is null || action is null || trigger is null || actions is null || triggers is null ||
            !OnlyChildren(principals, "Principal") || !OnlyChildren(actions, "Exec") || !OnlyChildren(triggers, "LogonTrigger") ||
            action.LocalName != "Exec" || !OnlyChildren(action, "Command", "Arguments") ||
            trigger.LocalName != "LogonTrigger" || !OnlyChildren(trigger, "Enabled", "UserId") ||
            !OnlyChildren(principal, "UserId", "LogonType", "RunLevel"))
        {
            return InvalidTask(taskName);
        }

        var command = SingleChildText(action, "Command");
        var arguments = SingleChildText(action, "Arguments");
        var actionContext = actions.Attributes?["Context"]?.Value;
        var principalSid = SingleChildText(principal, "UserId");
        var logonType = SingleChildText(principal, "LogonType");
        var runLevel = SingleChildText(principal, "RunLevel");
        var triggerSid = SingleChildText(trigger, "UserId");
        var triggerEnabled = ParseBoolean(SingleChildText(trigger, "Enabled"));
        var enabled = ParseBoolean(SingleChildText(settings, "Enabled"));
        var allowDemand = ParseBoolean(SingleChildText(settings, "AllowStartOnDemand"));
        var disallowStartIfOnBatteries = ParseBoolean(SingleChildText(settings, "DisallowStartIfOnBatteries"));
        var stopIfGoingOnBatteries = ParseBoolean(SingleChildText(settings, "StopIfGoingOnBatteries"));
        var multipleInstances = SingleChildText(settings, "MultipleInstancesPolicy");
        var executionTimeLimit = SingleChildText(settings, "ExecutionTimeLimit");
        return new ExistingBodyguardTask(
            true,
            principalSid,
            command,
            arguments,
            taskName,
            logonType,
            runLevel,
            trigger.LocalName,
            triggerSid,
            enabled && triggerEnabled,
            allowDemand,
            actionContext,
            multipleInstances,
            disallowStartIfOnBatteries,
            stopIfGoingOnBatteries,
            executionTimeLimit);
    }

    private static ExistingBodyguardTask InvalidTask(string taskName) =>
        new(true, null, null, null, taskName, null, null, null, null, false, false, null, null, false, false, null);

    private static System.Xml.XmlElement? SingleNode(System.Xml.XmlNode? parent, string xpath, System.Xml.XmlNamespaceManager namespaces) =>
        parent?.SelectNodes(xpath, namespaces) is { Count: 1 } nodes ? nodes[0] as System.Xml.XmlElement : null;

    private static string? SingleChildText(System.Xml.XmlNode? parent, string localName)
    {
        var children = parent?.ChildNodes.OfType<System.Xml.XmlElement>()
            .Where(child => child.NamespaceURI == TaskNamespace && child.LocalName == localName).ToArray();
        return children is { Length: 1 } ? children[0].InnerText : null;
    }

    private static bool OnlyChildren(System.Xml.XmlElement parent, params string[] allowed)
    {
        var children = parent.ChildNodes.OfType<System.Xml.XmlElement>().ToArray();
        var names = children.Select(child => child.LocalName).ToArray();
        return children.All(child => child.NamespaceURI == TaskNamespace) &&
            names.All(allowed.Contains) && allowed.All(name => names.Count(candidate => candidate == name) == 1);
    }

    private static bool ParseBoolean(string? value) => bool.TryParse(value, out var parsed) && parsed;
}
