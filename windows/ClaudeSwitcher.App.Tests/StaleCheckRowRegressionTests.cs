using ClaudeSwitcher.App.Models;
using ClaudeSwitcher.App.Services;
using ClaudeSwitcher.App.ViewModels;
using Xunit;

namespace ClaudeSwitcher.App.Tests;

public sealed class StaleCheckRowRegressionTests
{
    private static readonly Guid OperationId = CoreResultParserTests.TestOperationId;

    [Fact]
    public void Running_ReplacesPriorGreenRowsWithPendingRows()
    {
        var state = GreenState().Running("正在读取状态");

        AssertPendingRows(state);
    }

    [Fact]
    public void StatusQueryTimedOut_ReplacesPriorGreenRowsWithPendingRows()
    {
        var state = GreenState().StatusQueryTimedOut();

        AssertPendingRows(state);
    }

    [Theory]
    [InlineData("running", false)]
    [InlineData("recoveryRequired", true)]
    public void ApplyStatus_CurrentTransactionReplacesPriorGreenRowsWithPendingRows(string phase, bool recovery)
    {
        var status = CoreResultParser.Parse(
            CoreResultParserTests.StatusJson("B", phase, recovery, OperationId, phase),
            0,
            CoreCommand.Status,
            OperationId);

        var state = GreenState().ApplyStatus(status);

        AssertPendingRows(state);
    }

    [Theory]
    [InlineData("running", false)]
    [InlineData("recoveryRequired", true)]
    [InlineData("idle", false)]
    public void ApplySwitch_NonCompletedTransactionReplacesPriorGreenRowsWithPendingRows(string phase, bool recovery)
    {
        var error = Assert.Throws<CoreProtocolException>(() => CoreResultParser.Parse(
            CoreResultParserTests.SwitchJson(success: false, phase: phase, recoveryRequired: recovery),
            2,
            CoreCommand.Switch,
            OperationId,
            "B"));

        var state = GreenState().ApplySwitch(error.PartialResult!, "B", freshCheck: null);

        AssertPendingRows(state);
    }

    [Fact]
    public void ApplySwitch_CompletedFreshFailedCheckPreservesFreshRows()
    {
        var completed = CoreResultParser.Parse(
            CoreResultParserTests.SwitchJson(),
            0,
            CoreCommand.Switch,
            OperationId,
            "B");
        var fresh = CoreResultParser.Parse(
            CoreResultParserTests.DetailJson("dns", "fail", blocking: true, canLaunch: false),
            0,
            CoreCommand.CheckDetail,
            OperationId);

        var state = GreenState().ApplySwitch(completed, "B", fresh);

        Assert.Equal(CoreResultParser.RequiredCheckIds, state.Checks.Select(row => row.Id));
        Assert.Equal(CheckVisualState.Failed, state.Checks.Single(row => row.Id == "dns").VisualState);
        Assert.Equal("B", state.CurrentAccount);
        Assert.Equal("completed", state.TransactionPhase);
    }

    [Fact]
    public void ApplySwitch_CompletedFreshSuccessfulCheckPreservesFreshRows()
    {
        var completed = CoreResultParser.Parse(
            CoreResultParserTests.SwitchJson(),
            0,
            CoreCommand.Switch,
            OperationId,
            "B");
        var fresh = CoreResultParser.Parse(
            CoreResultParserTests.DetailJson(),
            0,
            CoreCommand.CheckDetail,
            OperationId);

        var state = GreenState().ApplySwitch(completed, "B", fresh);

        Assert.All(state.Checks, row => Assert.Equal(CheckVisualState.Ok, row.VisualState));
        Assert.Equal("B", state.CurrentAccount);
        Assert.Equal("completed", state.TransactionPhase);
    }

    private static MainWindowState GreenState() =>
        MainWindowState.Initial.ApplyCheck(CoreResultParser.Parse(
            CoreResultParserTests.DetailJson(),
            0,
            CoreCommand.CheckDetail,
            OperationId));

    private static void AssertPendingRows(MainWindowState state)
    {
        Assert.Equal(CoreResultParser.RequiredCheckIds, state.Checks.Select(row => row.Id));
        Assert.All(state.Checks, row =>
        {
            Assert.Equal(CheckVisualState.Pending, row.VisualState);
            Assert.True(row.Blocking);
        });
    }
}
