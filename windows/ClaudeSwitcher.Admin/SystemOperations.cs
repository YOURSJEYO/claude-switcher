using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security;

namespace ClaudeSwitcher.Admin;

public sealed class SystemOperations : ISystemOperations
{
    private readonly IFixedProcessRunner processRunner;

    public SystemOperations() : this(new FixedProcessRunner()) { }
    public SystemOperations(IFixedProcessRunner processRunner) => this.processRunner = processRunner;

    public void SetTimeZone(string timeZoneId)
    {
        if (!AdminRequest.IsSafeWindowsTimeZone(timeZoneId))
        {
            throw new ArgumentException("Unknown Windows time zone.", nameof(timeZoneId));
        }

        RunFixedProcess(Path.Combine(SystemDirectory, "tzutil.exe"), new[] { "/s", timeZoneId });
    }

    public void DisableIpv6()
    {
        var modulePath = Path.Combine(SystemDirectory, "WindowsPowerShell", "v1.0", "Modules", "NetAdapter", "NetAdapter.psd1").Replace("'", "''", StringComparison.Ordinal);
        var command = "$ErrorActionPreference='Stop'; Import-Module '" + modulePath + "' -Force; NetAdapter\\Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction Stop | Where-Object { $_.Enabled } | NetAdapter\\Disable-NetAdapterBinding -Confirm:$false -ErrorAction Stop";
        RunFixedProcess(
            Path.Combine(SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"),
            new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command });
    }

    public void FlushDns()
    {
        if (!DnsFlushResolverCache())
        {
            throw new InvalidOperationException("Windows did not flush the DNS resolver cache.");
        }
    }

    public void EnsureBodyguardTask(BodyguardTaskPaths paths, string userSid, int sessionId)
    {
        ArgumentNullException.ThrowIfNull(paths);
        if (!AdminRequest.IsUserSid(userSid))
        {
            throw new ArgumentException("A valid user SID is required.", nameof(userSid));
        }

        if (sessionId <= 0) { throw new ArgumentException("Interactive session is required.", nameof(sessionId)); }
        dynamic service = ConnectScheduler();
        dynamic folder = service.GetFolder("\\");
        dynamic? existingTask = FindTask(folder, paths.TaskName);
        var existing = existingTask is null
            ? new ExistingBodyguardTask(false, null, null, null)
            : BodyguardTaskPolicy.ParseTaskXml((string)existingTask.Xml, paths.TaskName);
        switch (BodyguardTaskPolicy.Evaluate(paths, userSid, existing))
        {
            case BodyguardTaskDecision.NoChange:
                if ((int)existingTask!.State != 4) { existingTask.RunEx(null, 4, sessionId, null); }
                return;
            case BodyguardTaskDecision.Reject:
                throw new InvalidOperationException("An existing task is not owned by this product and user.");
            case BodyguardTaskDecision.Create:
                var xml = BuildBodyguardTaskXml(paths, userSid);
                // TASK_CREATE=2, TASK_LOGON_INTERACTIVE_TOKEN=3. Never overwrite an existing task.
                dynamic registered = folder.RegisterTask(paths.TaskName, xml, 2, userSid, null, 3,
                    "D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;" + userSid + ")");
                registered.RunEx(null, 4, sessionId, null);
                return;
            default:
                throw new InvalidOperationException("Unexpected task ownership decision.");
        }
    }

    public void RemoveBodyguardTask(BodyguardTaskPaths paths, string userSid)
    {
        ArgumentNullException.ThrowIfNull(paths);
        if (!AdminRequest.IsUserSid(userSid))
        {
            throw new ArgumentException("A valid user SID is required.", nameof(userSid));
        }

        dynamic service = ConnectScheduler();
        dynamic folder = service.GetFolder("\\");
        dynamic? task = FindTask(folder, paths.TaskName);
        var existing = task is null
            ? new ExistingBodyguardTask(false, null, null, null)
            : BodyguardTaskPolicy.ParseTaskXml((string)task.Xml, paths.TaskName);
        switch (BodyguardTaskPolicy.EvaluateRemoval(paths, userSid, existing))
        {
            case BodyguardTaskDecision.NoChange:
                return;
            case BodyguardTaskDecision.Reject:
                throw new InvalidOperationException("Refusing to remove a task not owned by this product and user.");
            case BodyguardTaskDecision.Remove:
                task!.Stop(0);
                folder.DeleteTask(paths.TaskName, 0);
                return;
            default:
                throw new InvalidOperationException("Unexpected task ownership decision.");
        }
    }

    public static string BuildBodyguardTaskXml(BodyguardTaskPaths paths, string userSid)
    {
        if (!AdminRequest.IsUserSid(userSid)) { throw new ArgumentException("User SID is invalid.", nameof(userSid)); }
        return $"""
            <?xml version="1.0" encoding="UTF-16"?>
            <Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
              <RegistrationInfo><Author>ClaudeSwitcher</Author><Description>ClaudeSwitcher bodyguard</Description></RegistrationInfo>
              <Triggers><LogonTrigger><Enabled>true</Enabled><UserId>{userSid}</UserId></LogonTrigger></Triggers>
              <Principals><Principal id="Author"><UserId>{userSid}</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
              <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><AllowStartOnDemand>true</AllowStartOnDemand><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Enabled>true</Enabled></Settings>
              <Actions Context="Author"><Exec><Command>{SecurityElement.Escape(paths.PowerShellPath)}</Command><Arguments>{SecurityElement.Escape(paths.ActionArguments)}</Arguments></Exec></Actions>
            </Task>
            """;
    }

    private static object ConnectScheduler()
    {
        var type = Type.GetTypeFromProgID("Schedule.Service") ?? throw new InvalidOperationException("Task Scheduler is unavailable.");
        dynamic service = Activator.CreateInstance(type) ?? throw new InvalidOperationException("Task Scheduler is unavailable.");
        service.Connect();
        return service;
    }

    private static object? FindTask(dynamic folder, string taskName)
    {
        try { return folder.GetTask(taskName); }
        catch (COMException error) when (error.HResult == unchecked((int)0x80070002)) { return null; }
    }

    private static string SystemDirectory => Environment.GetFolderPath(Environment.SpecialFolder.System);

    private void RunFixedProcess(string filePath, IReadOnlyList<string> arguments)
    {
        var result = processRunner.Run(filePath, arguments, TimeSpan.FromSeconds(90));
        if (result.ExitCode != 0) { throw new InvalidOperationException("A fixed system operation failed."); }
    }

    [DllImport("dnsapi.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DnsFlushResolverCache();
}
