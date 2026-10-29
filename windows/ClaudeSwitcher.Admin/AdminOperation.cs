namespace ClaudeSwitcher.Admin;

public enum AdminOperation
{
    SetTimeZone,
    DisableIpv6,
    FlushDns,
    RegisterBodyguardTask,
    RemoveBodyguardTask,
    RepairSystem,
    MigrateLegacyBodyguard
}

public static class AdminOperationNames
{
    public static bool TryParse(string? value, out AdminOperation operation)
    {
        operation = value switch
        {
            "set-time-zone" => AdminOperation.SetTimeZone,
            "disable-ipv6" => AdminOperation.DisableIpv6,
            "flush-dns" => AdminOperation.FlushDns,
            "register-bodyguard-task" => AdminOperation.RegisterBodyguardTask,
            "remove-bodyguard-task" => AdminOperation.RemoveBodyguardTask,
            "repair-system" => AdminOperation.RepairSystem,
            "migrate-legacy-bodyguard" => AdminOperation.MigrateLegacyBodyguard,
            _ => default
        };
        return value is "set-time-zone" or "disable-ipv6" or "flush-dns" or "register-bodyguard-task" or "remove-bodyguard-task" or "repair-system" or "migrate-legacy-bodyguard";
    }
}
