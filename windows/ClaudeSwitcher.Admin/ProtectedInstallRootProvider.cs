namespace ClaudeSwitcher.Admin;

public sealed class ProtectedInstallRootProvider : IInstallRootProvider
{
    private readonly string executablePath;

    public ProtectedInstallRootProvider()
        : this(AssemblyLocation())
    {
    }

    public ProtectedInstallRootProvider(string executablePath)
    {
        this.executablePath = Path.GetFullPath(executablePath);
    }

    public InstallRootResult Resolve(InteractiveIdentity identity)
    {
        ArgumentNullException.ThrowIfNull(identity);
        var helperDirectory = Path.GetDirectoryName(executablePath);
        if (string.IsNullOrWhiteSpace(helperDirectory))
        {
            return InstallRootResult.Failure("helper executable directory could not be derived");
        }

        var root = Path.GetFullPath(Path.Combine(helperDirectory, ".."));
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        if (!IsUnder(root, programFiles) && !IsUnder(root, programFilesX86))
        {
            return InstallRootResult.Failure("helper is not installed under protected Program Files");
        }

        var requiredFiles = new[]
        {
            Path.Combine(helperDirectory, "ClaudeSwitcher.Admin.exe"),
            Path.Combine(root, "scripts", "claude-switch.ps1"),
            Path.Combine(root, "scripts", "claude-bodyguard.ps1")
        };
        if (requiredFiles.Any(path => !File.Exists(path)))
        {
            return InstallRootResult.Failure("protected install payload is incomplete");
        }

        try
        {
            var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            {
                root,
                Path.Combine(root, "scripts"),
                Path.Combine(root, "helpers"),
                Path.Combine(root, "scripts", "claude-switch.ps1"),
                Path.Combine(root, "scripts", "claude-bodyguard.ps1")
            };
            var directories = new Stack<string>();
            directories.Push(helperDirectory);
            while (directories.Count != 0)
            {
                foreach (var dependency in Directory.EnumerateFileSystemEntries(directories.Pop()))
                {
                    var attributes = File.GetAttributes(dependency);
                    if ((attributes & FileAttributes.ReparsePoint) != 0) { return InstallRootResult.Failure("protected helper contains a reparse path"); }
                    paths.Add(dependency);
                    if (paths.Count > 10000) { return InstallRootResult.Failure("protected helper payload exceeds validation limit"); }
                    if ((attributes & FileAttributes.Directory) != 0) { directories.Push(dependency); }
                }
            }

            foreach (var path in paths)
            {
                if (!IsUnder(path, programFiles) && !IsUnder(path, programFilesX86))
                {
                    return InstallRootResult.Failure("protected payload path escapes Program Files");
                }

                if (!ProtectedPathIsTrusted(path, programFiles, programFilesX86))
                {
                    return InstallRootResult.Failure("protected payload ACL or reparse validation failed");
                }
            }
        }
        catch (UnauthorizedAccessException)
        {
            return InstallRootResult.Failure("install root ACL could not be inspected");
        }
        catch (SystemException)
        {
            return InstallRootResult.Failure("install root ACL could not be validated");
        }

        return InstallRootResult.Success(root);
    }

    private static bool ProtectedPathIsTrusted(string path, string programFiles, string programFilesX86)
    {
        var fullPath = Path.GetFullPath(path);
        var boundary = IsUnder(fullPath, programFiles) ? Path.GetFullPath(programFiles) : Path.GetFullPath(programFilesX86);
        var cursor = fullPath;
        while (cursor.Length >= boundary.Length)
        {
            FileSystemInfo item = Directory.Exists(cursor) ? new DirectoryInfo(cursor) : new FileInfo(cursor);
            item.Refresh();
            if (!item.Exists || (item.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                return false;
            }

            var owner = item is DirectoryInfo directory
                ? directory.GetAccessControl().GetOwner(typeof(System.Security.Principal.SecurityIdentifier))
                : ((FileInfo)item).GetAccessControl().GetOwner(typeof(System.Security.Principal.SecurityIdentifier));
            if (!InstallAclPolicy.IsTrustedOwner(owner as System.Security.Principal.SecurityIdentifier
                    ?? throw new InvalidOperationException("protected payload owner SID is unavailable")))
            {
                return false;
            }

            var rules = item is DirectoryInfo securedDirectory
                ? securedDirectory.GetAccessControl().GetAccessRules(includeExplicit: true, includeInherited: true, typeof(System.Security.Principal.SecurityIdentifier))
                : ((FileInfo)item).GetAccessControl().GetAccessRules(includeExplicit: true, includeInherited: true, typeof(System.Security.Principal.SecurityIdentifier));
            foreach (System.Security.AccessControl.FileSystemAccessRule rule in rules)
            {
                if (rule.AccessControlType == System.Security.AccessControl.AccessControlType.Allow &&
                    InstallAclPolicy.IsUnsafeAllow((System.Security.Principal.SecurityIdentifier)rule.IdentityReference,
                        rule.FileSystemRights, rule.PropagationFlags))
                {
                    return false;
                }
            }

            if (cursor.Equals(boundary, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            cursor = Path.GetDirectoryName(cursor) ?? string.Empty;
        }

        return false;
    }

    private static bool IsUnder(string candidate, string root)
    {
        if (string.IsNullOrWhiteSpace(root))
        {
            return false;
        }

        var fullCandidate = Path.GetFullPath(candidate).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        return fullCandidate.Equals(fullRoot, StringComparison.OrdinalIgnoreCase) ||
               fullCandidate.StartsWith(fullRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    private static string AssemblyLocation()
    {
        var location = System.Reflection.Assembly.GetEntryAssembly()?.Location;
        if (string.IsNullOrWhiteSpace(location))
        {
            throw new InvalidOperationException("helper executable location is unavailable");
        }

        return location;
    }
}
