using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.Principal;

namespace ClaudeSwitcher.Admin;

public sealed class WtsInteractiveIdentityResolver : IInteractiveIdentityResolver
{
    private const int WtsConnectState = 8;
    private const uint ProcessQueryLimitedInformation = 0x1000;
    private const int TokenSessionId = 12;

    public InteractiveIdentityResult Resolve(int? requestedSessionId)
    {
        if (!IsElevated())
        {
            return InteractiveIdentityResult.Failure("the admin helper is not running elevated");
        }

        var sessionId = requestedSessionId ?? GetActiveConsoleSessionId();
        if (sessionId <= 0 || sessionId == int.MaxValue)
        {
            return InteractiveIdentityResult.Failure("no interactive Windows session was found");
        }

        var connectionState = QuerySessionConnectState((uint)sessionId);
        if (!WtsSessionPolicy.IsActiveConnectionState(connectionState))
        {
            return InteractiveIdentityResult.Failure("the requested Windows session is not active");
        }

        if (TryGetSessionTokenIdentity(sessionId, out var tokenSid))
        {
            return InteractiveIdentityResult.Success(tokenSid, sessionId);
        }

        if (TryGetProcessTokenIdentity(sessionId, out var processSid))
        {
            return InteractiveIdentityResult.Success(processSid, sessionId);
        }

        return InteractiveIdentityResult.Failure("the interactive user identity could not be verified through an active WTS session token");
    }

    private static bool IsElevated()
    {
        using var identity = WindowsIdentity.GetCurrent();
        var principal = new WindowsPrincipal(identity);
        return principal.IsInRole(WindowsBuiltInRole.Administrator);
    }

    private static int GetActiveConsoleSessionId()
    {
        var sessionId = WTSGetActiveConsoleSessionId();
        return sessionId == uint.MaxValue ? 0 : unchecked((int)sessionId);
    }

    private static int? QuerySessionConnectState(uint sessionId)
    {
        if (!WTSQuerySessionInformation(IntPtr.Zero, sessionId, WtsConnectState, out var buffer, out var bytesReturned) ||
            bytesReturned < sizeof(int))
        {
            return null;
        }

        try
        {
            return Marshal.ReadInt32(buffer);
        }
        finally
        {
            WTSFreeMemory(buffer);
        }
    }

    private static bool TryGetSessionTokenIdentity(int sessionId, out string sid)
    {
        sid = string.Empty;
        if (!WTSQueryUserToken((uint)sessionId, out var token))
        {
            return false;
        }

        try
        {
            return TryReadTokenIdentity(token, sessionId, out sid);
        }
        finally
        {
            _ = CloseHandle(token);
        }
    }

    private static bool TryGetProcessTokenIdentity(int sessionId, out string sid)
    {
        sid = string.Empty;
        var candidates = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            foreach (var process in Process.GetProcesses())
            {
                try
                {
                    if (ProcessIdToSessionId((uint)process.Id, out var processSessionId) &&
                        processSessionId == (uint)sessionId)
                    {
                        var processHandle = OpenProcess(ProcessQueryLimitedInformation, false, (uint)process.Id);
                        if (processHandle == IntPtr.Zero)
                        {
                            continue;
                        }

                        try
                        {
                            if (OpenProcessToken(processHandle, 0x0008, out var token))
                            {
                                try
                                {
                                    if (TryReadTokenIdentity(token, sessionId, out var candidateSid))
                                    {
                                        candidates.Add(candidateSid);
                                    }
                                }
                                finally
                                {
                                    _ = CloseHandle(token);
                                }
                            }
                        }
                        finally
                        {
                            _ = CloseHandle(processHandle);
                        }
                    }
                }
                catch (Exception error) when (error is InvalidOperationException or SystemException)
                {
                    // Processes can exit or deny token access while the session is being inspected.
                }
                finally
                {
                    process.Dispose();
                }
            }
        }
        catch (Exception error) when (error is InvalidOperationException or SystemException)
        {
            return false;
        }

        sid = WtsSessionPolicy.SelectUnambiguousUserSid(candidates) ?? string.Empty;
        return sid.Length != 0;
    }

    private static bool TryReadTokenIdentity(IntPtr token, int requestedSessionId, out string sid)
    {
        sid = string.Empty;
        var sessionBuffer = Marshal.AllocHGlobal(sizeof(int));
        try
        {
            if (!GetTokenInformation(token, TokenSessionId, sessionBuffer, sizeof(int), out var returnedLength) ||
                returnedLength < sizeof(int))
            {
                return false;
            }

            var tokenSessionId = Marshal.ReadInt32(sessionBuffer);
            try
            {
                using var identity = new WindowsIdentity(token);
                var candidateSid = identity.User?.Value;
                if (!WtsSessionPolicy.IsSupportedTokenSession(tokenSessionId, requestedSessionId, candidateSid))
                {
                    return false;
                }

                sid = candidateSid!;
                return true;
            }
            catch (Exception error) when (error is ArgumentException or UnauthorizedAccessException or SecurityException or SystemException)
            {
                return false;
            }
        }
        finally
        {
            Marshal.FreeHGlobal(sessionBuffer);
        }
    }

    [DllImport("kernel32.dll")]
    private static extern uint WTSGetActiveConsoleSessionId();

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ProcessIdToSessionId(uint processId, out uint sessionId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint desiredAccess, [MarshalAs(UnmanagedType.Bool)] bool inheritHandle, uint processId);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetTokenInformation(
        IntPtr tokenHandle,
        int tokenInformationClass,
        IntPtr tokenInformation,
        int tokenInformationLength,
        out int returnLength);

    [DllImport("wtsapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WTSQueryUserToken(uint sessionId, out IntPtr token);

    [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WTSQuerySessionInformation(
        IntPtr serverHandle,
        uint sessionId,
        int infoClass,
        out IntPtr buffer,
        out int bytesReturned);

    [DllImport("wtsapi32.dll")]
    private static extern void WTSFreeMemory(IntPtr memory);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);
}
