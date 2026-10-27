namespace ClaudeSwitcher.Admin;

public static class Program
{
    public static int Main(string[] args)
    {
        var context = new AdminContext(
            new WtsInteractiveIdentityResolver(),
            new ProtectedInstallRootProvider(),
            new SystemOperations());
        return AdminApplication.Run(args, context, Console.Out);
    }
}
