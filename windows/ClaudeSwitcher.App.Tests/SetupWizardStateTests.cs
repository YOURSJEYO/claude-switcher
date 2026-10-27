using ClaudeSwitcher.App.Models;
using Xunit;

namespace ClaudeSwitcher.App.Tests;

public sealed class SetupWizardStateTests
{
    private static readonly SetupPreview Reviewed = new(
        "JP",
        "Tokyo Standard Time",
        "ja-JP",
        "clash-verge",
        "Synthetic Group",
        []);

    [Fact]
    public void EditingProxySelectionInvalidatesReviewedPreview()
    {
        var state = SetupWizardState.Editing("clash-verge", "")
            .WithSelection("clash-verge", "Synthetic Group")
            .Reviewed(Reviewed)
            .WithSelection("clash-verge", "Other Group");

        Assert.Equal(SetupWizardPhase.Editing, state.Phase);
        Assert.Null(state.Preview);
        Assert.False(state.CanApply);
        Assert.True(state.CanClose);
    }

    [Fact]
    public void ReviewedPreviewEnablesOneExplicitApply()
    {
        var reviewed = SetupWizardState.Editing("clash-verge", "")
            .WithSelection("clash-verge", "Synthetic Group")
            .Reviewed(Reviewed);
        var state = reviewed.Applying();

        Assert.True(reviewed.CanApply);
        Assert.Equal(SetupWizardPhase.Applying, state.Phase);
        Assert.Equal(Reviewed, state.Preview);
        Assert.False(state.CanPreview);
        Assert.False(state.CanApply);
        Assert.False(state.CanClose);
    }

    [Fact]
    public void StillRunningKeepsWindowOpenAndBlocksSecondApply()
    {
        var state = SetupWizardState.Editing("auto", "").Reviewed(new SetupPreview("JP", "Tokyo Standard Time", "ja-JP", "auto", "", [])).StillRunning();

        Assert.Equal(SetupWizardPhase.StillRunning, state.Phase);
        Assert.True(state.CanWait);
        Assert.False(state.CanApply);
        Assert.False(state.CanPreview);
        Assert.False(state.CanClose);
    }

    [Fact]
    public void DetachedStateAllowsCloseAndWarnsThatMutationMayStillBeRunning()
    {
        var state = SetupWizardState.Editing("auto", "")
            .Reviewed(new SetupPreview("JP", "Tokyo Standard Time", "ja-JP", "auto", "", []))
            .StillRunning()
            .Detached();

        Assert.Equal(SetupWizardPhase.Detached, state.Phase);
        Assert.True(state.CanClose);
        Assert.False(state.CanWait);
        Assert.False(state.CanPreview);
        Assert.False(state.CanApply);
        Assert.Contains("可能仍在运行", state.Message, StringComparison.Ordinal);
        Assert.Contains("未确认终止", state.Message, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(SetupWizardPhase.Cancelled)]
    [InlineData(SetupWizardPhase.PartialFailure)]
    [InlineData(SetupWizardPhase.Failed)]
    public void RetryableTerminalStateAllowsPreviewAndClose(SetupWizardPhase phase)
    {
        var state = SetupWizardState.Editing("auto", "")
            .Reviewed(new SetupPreview("JP", "Tokyo Standard Time", "ja-JP", "auto", "", []))
            .Terminal(phase, "synthetic failure");

        Assert.Equal(phase, state.Phase);
        Assert.True(state.CanPreview);
        Assert.True(state.CanClose);
        Assert.False(state.CanApply);
    }

    [Fact]
    public void NonClashReviewedStateClearsGroupWhenSelectionChanges()
    {
        var reviewed = SetupWizardState.Editing("auto", "")
            .Reviewed(new SetupPreview("JP", "Tokyo Standard Time", "ja-JP", "auto", "", []));

        Assert.True(reviewed.CanApply);
        Assert.False(reviewed.WithSelection("clash-verge", "Synthetic Group").CanApply);
    }

    [Fact]
    public void ElevatedProcessDisablesAllSetupActions()
    {
        var state = SetupWizardState.Editing("auto", "").AsElevated();

        Assert.Equal(SetupWizardPhase.Elevated, state.Phase);
        Assert.True(state.CanClose);
        Assert.False(state.CanPreview);
        Assert.False(state.CanApply);
        Assert.Contains("普通桌面", state.Message, StringComparison.Ordinal);
    }
}
