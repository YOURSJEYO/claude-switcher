using ClaudeSwitcher.App.Models;
using Xunit;

namespace ClaudeSwitcher.App.Tests;

public sealed class AppLaunchArgumentsTests
{
    [Theory]
    [InlineData("--setup")]
    [InlineData("--SETUP")]
    public void Parse_RecognizesSetupMode(string argument)
    {
        var launch = AppLaunchArguments.Parse([argument]);

        Assert.True(launch.SetupMode);
    }

    [Fact]
    public void Parse_DefaultsToNormalLaunch()
    {
        Assert.False(AppLaunchArguments.Parse([]).SetupMode);
        Assert.False(AppLaunchArguments.Parse(["--other"]).SetupMode);
    }
}
