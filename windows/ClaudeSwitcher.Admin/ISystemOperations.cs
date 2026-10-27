namespace ClaudeSwitcher.Admin;

public interface ISystemOperations
{
    void SetTimeZone(string timeZoneId);
    void DisableIpv6();
    void FlushDns();
    void EnsureBodyguardTask(BodyguardTaskPaths paths, string userSid, int sessionId);
    void RemoveBodyguardTask(BodyguardTaskPaths paths, string userSid);
}
