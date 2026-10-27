namespace ClaudeSwitcher.App.Models;

public sealed record AppLaunchArguments(bool SetupMode)
{
    public static AppLaunchArguments Parse(IReadOnlyList<string> arguments)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        return new AppLaunchArguments(
            arguments.Any(argument => string.Equals(argument, "--setup", StringComparison.OrdinalIgnoreCase)));
    }
}
