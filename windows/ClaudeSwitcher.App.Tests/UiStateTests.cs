using ClaudeSwitcher.App.Models;
using ClaudeSwitcher.App.Services;
using ClaudeSwitcher.App.ViewModels;
using Xunit;

namespace ClaudeSwitcher.App.Tests;

public sealed class UiStateTests
{
    private static readonly Guid OperationId = CoreResultParserTests.TestOperationId;

    [Fact]
    public void InitialState_IsCheckingWithAllFourteenRows()
    {
        var state = MainWindowState.Initial;

        Assert.Equal(UiStatus.Checking, state.Status);
        Assert.Equal(14, state.Checks.Count);
        Assert.Equal(CoreResultParser.RequiredCheckIds, state.Checks.Select(check => check.Id));
        Assert.False(state.CanRefresh);
        Assert.False(state.CanFix);
        Assert.False(state.CanSwitch);
        Assert.False(state.CanLaunch);
    }

    [Fact]
    public void Apply_ReadyEnablesOperationsAndHonorsCoreLaunchGate()
    {
        var state = MainWindowState.Initial.Apply(
            CoreResultParser.Parse(CoreResultParserTests.DetailJson(), 0, CoreCommand.CheckDetail, OperationId),
            status: null);

        Assert.Equal(UiStatus.Ready, state.Status);
        Assert.True(state.CanRefresh);
        Assert.True(state.CanFix);
        Assert.True(state.CanSwitch);
        Assert.True(state.CanLaunch);
    }

    [Fact]
    public void Apply_WarningIsNotGreen()
    {
        var result = CoreResultParser.Parse(
            CoreResultParserTests.DetailJson("asn"),
            0,
            CoreCommand.CheckDetail,
            OperationId);

        var state = MainWindowState.Initial.Apply(result, status: null);

        var warning = state.Checks.Single(check => check.Id == "asn");
        Assert.Equal(CheckVisualState.Warning, warning.VisualState);
        Assert.NotEqual("#22C55E", warning.Accent);
        Assert.True(state.CanLaunch);
    }

    [Fact]
    public void Apply_BlockedDisablesMutatingActions()
    {
        var result = CoreResultParser.Parse(
            CoreResultParserTests.DetailJson("dns", "fail", blocking: true, canLaunch: false),
            0,
            CoreCommand.CheckDetail,
            OperationId);

        var state = MainWindowState.Initial.Apply(result, status: null);

        Assert.Equal(UiStatus.Blocked, state.Status);
        Assert.True(state.CanRefresh);
        Assert.True(state.CanFix);
        Assert.False(state.CanSwitch);
        Assert.False(state.CanLaunch);
    }

    [Fact]
    public void Apply_RecoveryStatusOnlyAllowsRefresh()
    {
        var status = CoreResultParser.Parse(
            CoreResultParserTests.StatusJson("B", "recoveryRequired", true, Guid.Parse("76edf30d-d528-47dd-81e0-176f5a3cd895"), "restoreNeeded"),
            0,
            CoreCommand.Status,
            OperationId);

        var state = MainWindowState.Initial.Apply(statusResult: null, status);

        Assert.Equal(UiStatus.RecoveryRequired, state.Status);
        Assert.True(state.CanRefresh);
        Assert.False(state.CanFix);
        Assert.False(state.CanSwitch);
        Assert.False(state.CanLaunch);
        Assert.Contains("恢复", state.Banner, StringComparison.Ordinal);
    }

    [Fact]
    public void Apply_RunningStatusOnlyAllowsStatusRefresh()
    {
        var status = CoreResultParser.Parse(
            CoreResultParserTests.StatusJson("B", "running", false, Guid.Parse("76edf30d-d528-47dd-81e0-176f5a3cd895"), "copyingToB"),
            0,
            CoreCommand.Status,
            OperationId);

        var state = MainWindowState.Initial.Apply(statusResult: null, status);

        Assert.Equal(UiStatus.Running, state.Status);
        Assert.True(state.CanRefresh);
        Assert.False(state.CanFix);
        Assert.False(state.CanSwitch);
        Assert.False(state.CanLaunch);
        Assert.Equal("copyingToB", state.TransactionPhase);
    }

    [Fact]
    public void Apply_SetupRequiredExplainsProvisioningWithoutInstallBehavior()
    {
        var state = MainWindowState.Initial.SetupRequired();

        Assert.Equal(UiStatus.SetupRequired, state.Status);
        Assert.False(state.CanRefresh);
        Assert.False(state.CanFix);
        Assert.False(state.CanSwitch);
        Assert.False(state.CanLaunch);
        Assert.Contains("尚未配置", state.Banner, StringComparison.Ordinal);
    }

    [Fact]
    public void Apply_CompletedSwitchEnablesLaunchOnlyForFreshSuccessfulCheck()
    {
        var check = CoreResultParser.Parse(CoreResultParserTests.DetailJson(), 0, CoreCommand.CheckDetail, OperationId);
        var completed = CoreResultParser.Parse(
            CoreResultParserTests.SwitchJson(current: "B"),
            0,
            CoreCommand.Switch,
            OperationId,
            "B");

        var allowed = MainWindowState.Initial.Apply(check, status: null).ApplySwitch(completed, target: "B", freshCheck: check);
        var stale = MainWindowState.Initial.Apply(check, status: null).ApplySwitch(completed, target: "B", freshCheck: null);

        Assert.True(allowed.CanLaunch);
        Assert.Equal("B", allowed.CurrentAccount);
        Assert.False(stale.CanLaunch);
    }

    [Fact]
    public void Apply_RunningDisablesAllActions()
    {
        var state = MainWindowState.Initial.Running("正在检查");

        Assert.Equal(UiStatus.Running, state.Status);
        Assert.False(state.CanRefresh);
        Assert.False(state.CanFix);
        Assert.False(state.CanSwitch);
        Assert.False(state.CanLaunch);
    }

    [Fact]
    public void ApplySwitch_MissingFreshCheckBlocksDespitePreviousReadyCheck()
    {
        var previous = CoreResultParser.Parse(CoreResultParserTests.DetailJson(), 0, CoreCommand.CheckDetail, OperationId);
        var completed = CoreResultParser.Parse(CoreResultParserTests.SwitchJson(), 0, CoreCommand.Switch, OperationId, "B");

        var state = MainWindowState.Initial.ApplyCheck(previous).ApplySwitch(completed, "B", freshCheck: null);

        Assert.Equal(UiStatus.Blocked, state.Status);
        Assert.False(state.CanSwitch);
        Assert.False(state.CanLaunch);
        Assert.True(state.CanRefresh);
        Assert.Equal("B", state.CurrentAccount);
        Assert.All(state.Checks, check => Assert.Equal(CheckVisualState.Pending, check.VisualState));
    }

    [Fact]
    public void ApplySwitch_BlockedFreshCheckPreservesBlockedState()
    {
        var blocked = CoreResultParser.Parse(
            CoreResultParserTests.DetailJson("dns", "fail", blocking: true, canLaunch: false),
            0, CoreCommand.CheckDetail, OperationId);
        var completed = CoreResultParser.Parse(CoreResultParserTests.SwitchJson(), 0, CoreCommand.Switch, OperationId, "B");

        var state = MainWindowState.Initial.ApplySwitch(completed, "B", blocked);

        Assert.Equal(UiStatus.Blocked, state.Status);
        Assert.False(state.CanSwitch);
        Assert.False(state.CanLaunch);
        Assert.True(state.CanRefresh);
        Assert.True(state.CanFix);
        Assert.Equal("B", state.CurrentAccount);
        Assert.Equal("completed", state.TransactionPhase);
        Assert.Equal(CheckVisualState.Failed, state.Checks.Single(check => check.Id == "dns").VisualState);
        Assert.Contains(MainWindowState.Initial.ApplyCheck(blocked).Banner, state.Banner, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("asn")]
    [InlineData("ip_consistency")]
    public void ApplySwitch_AllowedFreshWarningStaysYellow(string warningId)
    {
        var warning = CoreResultParser.Parse(CoreResultParserTests.DetailJson(warningId), 0, CoreCommand.CheckDetail, OperationId);
        var completed = CoreResultParser.Parse(CoreResultParserTests.SwitchJson(), 0, CoreCommand.Switch, OperationId, "B");

        var state = MainWindowState.Initial.ApplySwitch(completed, "B", warning);

        Assert.Equal(UiStatus.Ready, state.Status);
        Assert.True(state.CanSwitch);
        Assert.True(state.CanLaunch);
        var row = state.Checks.Single(check => check.Id == warningId);
        Assert.Equal(CheckVisualState.Warning, row.VisualState);
        Assert.Equal("#F59E0B", row.Accent);
        Assert.Contains("警告", state.Banner, StringComparison.Ordinal);
    }
}
