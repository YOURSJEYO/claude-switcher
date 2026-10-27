using System.Security.AccessControl;
using System.Security.Principal;

namespace ClaudeSwitcher.Admin;

public static class InstallAclPolicy
{
    private static readonly HashSet<string> TrustedOwners = new(StringComparer.Ordinal)
    {
        "S-1-5-18",
        "S-1-5-32-544",
        "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"
    };

    public static bool IsTrustedOwner(SecurityIdentifier sid) => TrustedOwners.Contains(sid.Value);

    public static bool IsUnsafeAllow(SecurityIdentifier sid, FileSystemRights rights, PropagationFlags propagation)
    {
        const FileSystemRights mutation = FileSystemRights.WriteData | FileSystemRights.AppendData |
            FileSystemRights.WriteExtendedAttributes | FileSystemRights.WriteAttributes |
            FileSystemRights.Delete | FileSystemRights.DeleteSubdirectoriesAndFiles |
            FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership;
        const uint genericMutation = 0x40000000u | 0x10000000u;
        return (propagation & PropagationFlags.InheritOnly) == 0 && !IsTrustedOwner(sid) &&
               ((rights & mutation) != 0 || (unchecked((uint)rights) & genericMutation) != 0);
    }
}
