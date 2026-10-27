using ClaudeSwitcher.App.Models;
using Xunit;

namespace ClaudeSwitcher.App.Tests;

public sealed class AppStartupPolicyTests
{
    [Theory]
    [InlineData(false, false, AppStartupDecision.NormalWindow)]
    [InlineData(true, false, AppStartupDecision.SetupWizard)]
    [InlineData(false, true, AppStartupDecision.RefuseElevated)]
    [InlineData(true, true, AppStartupDecision.RefuseElevated)]
    public void Decide_RejectsElevationForEveryLaunchMode(
        bool setupMode,
        bool elevated,
        AppStartupDecision expected)
    {
        Assert.Equal(expected, AppStartupPolicy.Decide(setupMode, elevated));
    }

    [Fact]
    public void ElevatedMessageExplainsOrdinaryDesktopRelaunch()
    {
        Assert.Contains("管理员身份", AppStartupPolicy.ElevatedMessage, StringComparison.Ordinal);
        Assert.Contains("普通桌面", AppStartupPolicy.ElevatedMessage, StringComparison.Ordinal);
    }
}
