using System.Text.Json;
using System.Text.Json.Nodes;
using ClaudeSwitcher.App.Models;
using ClaudeSwitcher.App.Services;
using Xunit;

namespace ClaudeSwitcher.App.Tests;

public sealed class CoreResultParserTests
{
    private static readonly Guid OperationId = Guid.Parse("3f6f37b4-7f19-4ca7-9eb1-7b99fbc7982f");

    public static readonly string[] ExpectedCheckIds =
    [
        "proxy_engine", "tun_interface", "egress_country", "ip_consistency", "timezone", "locale", "ipv6", "dns",
        "webrtc", "bodyguard", "routing_rules", "client_language", "asn", "ecosystem"
    ];

    [Fact]
    public void Parse_AcceptsCompleteCheckDetailResult()
    {
        var result = CoreResultParser.Parse(DetailJson(), 0, CoreCommand.CheckDetail, OperationId);

        Assert.Equal(CoreCommand.CheckDetail, result.Command);
        Assert.True(result.Success);
        Assert.True(result.CanLaunch);
        Assert.Equal(ExpectedCheckIds, result.Checks.Select(check => check.Id));
        Assert.All(result.Checks, check => Assert.Equal(CheckStatus.Ok, check.Status));
    }

    [Theory]
    [InlineData("ip_consistency")]
    [InlineData("asn")]
    public void Parse_AllowsOnlyNonBlockingWarningIds(string warningId)
    {
        var json = DetailJson(warningId);

        var result = CoreResultParser.Parse(json, 0, CoreCommand.CheckDetail, OperationId);

        Assert.True(result.CanLaunch);
        var warning = Assert.Single(result.Checks, check => check.Status == CheckStatus.Warn);
        Assert.Equal(warningId, warning.Id);
        Assert.False(warning.Blocking);
    }

    [Theory]
    [InlineData("proxy_engine")]
    [InlineData("tun_interface")]
    [InlineData("egress_country")]
    [InlineData("timezone")]
    [InlineData("locale")]
    [InlineData("ipv6")]
    [InlineData("dns")]
    [InlineData("webrtc")]
    [InlineData("bodyguard")]
    [InlineData("routing_rules")]
    [InlineData("client_language")]
    [InlineData("ecosystem")]
    public void Parse_BlocksWarningOutsideAllowlist(string warningId)
    {
        var result = CoreResultParser.Parse(DetailJson(warningId, blocking: true, canLaunch: false), 0, CoreCommand.CheckDetail, OperationId);

        Assert.False(result.CanLaunch);
        Assert.True(result.Checks.Single(check => check.Id == warningId).Blocking);
    }

    [Theory]
    [InlineData("fail")]
    [InlineData("unknown")]
    public void Parse_BlocksFailAndUnknown(string status)
    {
        var result = CoreResultParser.Parse(DetailJson("dns", status, blocking: true, canLaunch: false), 0, CoreCommand.CheckDetail, OperationId);

        Assert.False(result.CanLaunch);
        Assert.Equal(status == "fail" ? CheckStatus.Fail : CheckStatus.Unknown, result.Checks[7].Status);
    }

    [Fact]
    public void Parse_RejectsUnblockedFailure()
    {
        var error = Assert.Throws<CoreProtocolException>(() =>
            CoreResultParser.Parse(DetailJson("dns", "fail", blocking: false, canLaunch: true), 0, CoreCommand.CheckDetail, OperationId));

        Assert.Equal(CoreProtocolError.CheckBlockingMismatch, error.Error);
    }

    [Fact]
    public void Parse_RejectsMissingCheck()
    {
        var root = ParseObject(DetailJson());
        root["checks"]!.AsArray().RemoveAt(7);

        var error = Assert.Throws<CoreProtocolException>(() =>
            CoreResultParser.Parse(root.ToJsonString(), 0, CoreCommand.CheckDetail, OperationId));

        Assert.Equal(CoreProtocolError.CheckSetMismatch, error.Error);
    }

    [Fact]
    public void Parse_RejectsDuplicateCheck()
    {
        var root = ParseObject(DetailJson());
        var checks = root["checks"]!.AsArray();
        checks.Add(checks[0]!.DeepClone());

        var error = Assert.Throws<CoreProtocolException>(() =>
            CoreResultParser.Parse(root.ToJsonString(), 0, CoreCommand.CheckDetail, OperationId));

        Assert.Equal(CoreProtocolError.CheckSetMismatch, error.Error);
    }

    [Fact]
    public void Parse_RejectsUnknownCheck()
    {
        var root = ParseObject(DetailJson());
        var checks = root["checks"]!.AsArray();
        var extra = checks[0]!.DeepClone();
        extra["id"] = "unexpected";
        extra["name"] = "unexpected";
        checks.Add(extra);

        var error = Assert.Throws<CoreProtocolException>(() =>
            CoreResultParser.Parse(root.ToJsonString(), 0, CoreCommand.CheckDetail, OperationId));

        Assert.Equal(CoreProtocolError.CheckSetMismatch, error.Error);
    }

    [Fact]
    public void Parse_RejectsCheckOrderMismatch()
    {
        var root = ParseObject(DetailJson());
        var checks = root["checks"]!.AsArray();
        var first = checks[0]!.DeepClone();
        var second = checks[1]!.DeepClone();
        checks.Clear();
        checks.Add(second);
        checks.Add(first);
        for (var index = 2; index < ExpectedCheckIds.Length; index++)
        {
            checks.Add(ParseObject(DetailJson())["checks"]![index]!.DeepClone());
        }

        var error = Assert.Throws<CoreProtocolException>(() =>
            CoreResultParser.Parse(root.ToJsonString(), 0, CoreCommand.CheckDetail, OperationId));

        Assert.Equal(CoreProtocolError.CheckSetMismatch, error.Error);
    }

    [Fact]
    public void Parse_RejectsSchemaMismatch()
    {
        var root = ParseObject(DetailJson());
        root["schemaVersion"] = 2;

        var error = Assert.Throws<CoreProtocolException>(() =>
            CoreResultParser.Parse(root.ToJsonString(), 0, CoreCommand.CheckDetail, OperationId));

        Assert.Equal(CoreProtocolError.SchemaMismatch, error.Error);
    }

    [Fact]
    public void Parse_RejectsCommandMismatch()
    {
        var root = ParseObject(DetailJson());
        root["command"] = "status";

        var error = Assert.Throws<CoreProtocolException>(() =>
            CoreResultParser.Parse(root.ToJsonString(), 0, CoreCommand.CheckDetail, OperationId));

        Assert.Equal(CoreProtocolError.CommandMismatch, error.Error);
    }

    [Fact]
    public void Parse_RejectsOperationMismatch()
    {
        var root = ParseObject(DetailJson());
        root["operationId"] = Guid.NewGuid().ToString();

        var error = Assert.Throws<CoreProtocolException>(() =>
            CoreResultParser.Parse(root.ToJsonString(), 0, CoreCommand.CheckDetail, OperationId));

        Assert.Equal(CoreProtocolError.OperationMismatch, error.Error);
    }

    [Fact]
    public void Parse_RejectsNonCanonicalOperationId()
    {
        var root = ParseObject(DetailJson());
        root["operationId"] = OperationId.ToString().ToUpperInvariant();

        var error = Assert.Throws<CoreProtocolException>(() =>
            CoreResultParser.Parse(root.ToJsonString(), 0, CoreCommand.CheckDetail, OperationId));

        Assert.Equal(CoreProtocolError.OperationMismatch, error.Error);
    }

    [Fact]
    public void Parse_RejectsEmptyStdout()
    {
        var error = Assert.Throws<CoreProtocolException>(() =>
            CoreResultParser.Parse("  ", 0, CoreCommand.CheckDetail, OperationId));

        Assert.Equal(CoreProtocolError.EmptyOutput, error.Error);
    }

    [Fact]
    public void Parse_RejectsNonZeroExit()
    {
        var error = Assert.Throws<CoreProtocolException>(() =>
            CoreResultParser.Parse(DetailJson(), 1, CoreCommand.CheckDetail, OperationId));

        Assert.Equal(CoreProtocolError.ProcessFailed, error.Error);
        Assert.Equal(1, error.ExitCode);
    }

    [Fact]
    public void Parse_RejectsMissingRequiredField()
    {
        var root = ParseObject(DetailJson());
        root.Remove("message");

        var error = Assert.Throws<CoreProtocolException>(() =>
            CoreResultParser.Parse(root.ToJsonString(), 0, CoreCommand.CheckDetail, OperationId));

        Assert.Equal(CoreProtocolError.InvalidField, error.Error);
    }

    [Fact]
    public void Parse_RejectsCanLaunchContradiction()
    {
        var root = ParseObject(DetailJson());
        root["canLaunch"] = false;

        var error = Assert.Throws<CoreProtocolException>(() =>
            CoreResultParser.Parse(root.ToJsonString(), 0, CoreCommand.CheckDetail, OperationId));

        Assert.Equal(CoreProtocolError.CanLaunchMismatch, error.Error);
    }

    [Fact]
    public void Parse_RejectsExtraJsonDocument()
    {
        var error = Assert.Throws<CoreProtocolException>(() =>
            CoreResultParser.Parse(DetailJson() + "{}", 0, CoreCommand.CheckDetail, OperationId));

        Assert.Equal(CoreProtocolError.InvalidJson, error.Error);
    }

    [Fact]
    public void Parse_RedactsCheckDetailAndMessage()
    {
        var root = ParseObject(DetailJson());
        root["message"] = "token=secret-value";
        root["checks"]![2]!["detail"] = "egress 203.0.113.42";

        var result = CoreResultParser.Parse(root.ToJsonString(), 0, CoreCommand.CheckDetail, OperationId);

        Assert.DoesNotContain("203.0.113.42", result.Checks[2].Detail, StringComparison.Ordinal);
        Assert.DoesNotContain("secret-value", result.Message, StringComparison.Ordinal);
        Assert.Contains("[redacted]", result.Checks[2].Detail, StringComparison.Ordinal);
    }

    [Fact]
    public void Parse_AcceptsStatusWithRecoveryRequired()
    {
        var result = CoreResultParser.Parse(
            StatusJson("B", "recoveryRequired", true, Guid.Parse("76edf30d-d528-47dd-81e0-176f5a3cd895"), "restoreNeeded"),
            0,
            CoreCommand.Status,
            OperationId);

        Assert.Equal("B", result.Current);
        Assert.Equal(OperationPhase.RecoveryRequired, result.Phase);
        Assert.True(result.RecoveryRequired);
    }

    [Theory]
    [InlineData("2001:db8::1")]
    [InlineData("::1")]
    [InlineData("::ffff:192.0.2.128")]
    [InlineData("::ffff:c000:280")]
    [InlineData("0:0:0:0:0:ffff:192.0.2.128")]
    public void Parse_RedactsCompressedAndMappedIpv6FromDisplayedFields(string address)
    {
        var root = ParseObject(DetailJson());
        root["message"] = $"egress {address}";
        root["checks"]![2]!["detail"] = $"via {address} port 443";

        var result = CoreResultParser.Parse(root.ToJsonString(), 0, CoreCommand.CheckDetail, OperationId);

        Assert.Equal("egress [redacted]", result.Message);
        Assert.Equal("via [redacted] port 443", result.Checks[2].Detail);
    }

    [Theory]
    [InlineData("egress 2001:db8::1.", "egress [redacted].")]
    [InlineData("clock 12:34:56", "clock 12:34:56")]
    [InlineData("invalid 2001:db8::xyz", "invalid 2001:db8::xyz")]
    public void Redact_Ipv6PreservesPunctuationAndNonAddresses(string input, string expected)
    {
        Assert.Equal(expected, SensitiveDataRedactor.Redact(input));
    }

    [Theory]
    [InlineData("C", "idle")]
    [InlineData("A", "waiting")]
    public void Parse_RejectsInvalidStatusFields(string current, string phase)
    {
        var error = Assert.Throws<CoreProtocolException>(() =>
            CoreResultParser.Parse(StatusJson(current, phase, false), 0, CoreCommand.Status, OperationId));

        Assert.Equal(CoreProtocolError.InvalidField, error.Error);
    }

    [Fact]
    public void Parse_AcceptsSuccessfulCompletedSwitch()
    {
        var result = CoreResultParser.Parse(SwitchJson(), 0, CoreCommand.Switch, OperationId, "B");

        Assert.Equal("B", result.Current);
        Assert.Equal(OperationPhase.Completed, result.Phase);
        Assert.False(result.RecoveryRequired);
        Assert.True(result.IsCompletedSwitch);
    }

    [Theory]
    [InlineData(true, "running", false)]
    [InlineData(false, "completed", false)]
    [InlineData(true, "recoveryRequired", true)]
    public void Parse_DoesNotTreatNonFinalSwitchAsDone(bool success, string phase, bool recoveryRequired)
    {
        var result = CoreResultParser.Parse(
            SwitchJson(success: success, phase: phase, recoveryRequired: recoveryRequired),
            0,
            CoreCommand.Switch,
            OperationId,
            "B");

        Assert.False(result.IsCompletedSwitch);
    }

    [Fact]
    public void Parse_RequiresSwitchRecoveryFields()
    {
        var root = ParseObject(SwitchJson());
        root.Remove("recoveryRequired");

        var error = Assert.Throws<CoreProtocolException>(() =>
            CoreResultParser.Parse(root.ToJsonString(), 0, CoreCommand.Switch, OperationId, "B"));

        Assert.Equal(CoreProtocolError.InvalidField, error.Error);
    }

    [Theory]
    [InlineData("C")]
    [InlineData("a")]
    [InlineData(null)]
    public void Parse_RejectsInvalidSwitchTarget(string? target)
    {
        var error = Assert.Throws<CoreProtocolException>(() =>
            CoreResultParser.Parse(SwitchJson(), 0, CoreCommand.Switch, OperationId, target));

        Assert.Equal(CoreProtocolError.InvalidTarget, error.Error);
    }

    [Fact]
    public void Parse_StatusExposesActiveOperationAndTransactionPhase()
    {
        var activeOperationId = Guid.Parse("76edf30d-d528-47dd-81e0-176f5a3cd895");
        var json = StatusJson("B", "running", false, activeOperationId, "copyingToB");

        var result = CoreResultParser.Parse(json, 0, CoreCommand.Status, OperationId);

        Assert.Equal(activeOperationId, result.ActiveOperationId);
        Assert.Equal("copyingToB", result.TransactionPhase);
        Assert.Equal(OperationPhase.Running, result.Phase);
    }

    [Theory]
    [InlineData("running", null, "copyingToB")]
    [InlineData("running", "76edf30d-d528-47dd-81e0-176f5a3cd895", null)]
    [InlineData("recoveryRequired", null, "restoreNeeded")]
    public void Parse_RejectsIncompleteActiveOperationState(string phase, string? activeOperationId, string? transactionPhase)
    {
        var json = StatusJson(
            "B",
            phase,
            phase == "recoveryRequired",
            activeOperationId is null ? null : Guid.Parse(activeOperationId),
            transactionPhase);

        var error = Assert.Throws<CoreProtocolException>(() =>
            CoreResultParser.Parse(json, 0, CoreCommand.Status, OperationId));

        Assert.Equal(CoreProtocolError.InvalidField, error.Error);
    }

    [Fact]
    public void Parse_NonZeroFailurePreservesValidatedStatusForUiRecovery()
    {
        var activeOperationId = Guid.Parse("76edf30d-d528-47dd-81e0-176f5a3cd895");
        var root = ParseObject(StatusJson("B", "recoveryRequired", true, activeOperationId, "restoreNeeded"));
        root["success"] = false;
        root["code"] = "transactionRecoveryRequired";

        var error = Assert.Throws<CoreProtocolException>(() =>
            CoreResultParser.Parse(root.ToJsonString(), 5, CoreCommand.Status, OperationId));

        Assert.Equal(CoreProtocolError.ProcessFailed, error.Error);
        Assert.Equal(5, error.ExitCode);
        Assert.NotNull(error.PartialResult);
        Assert.False(error.PartialResult.Success);
        Assert.Equal("B", error.PartialResult.Current);
        Assert.Equal(OperationPhase.RecoveryRequired, error.PartialResult.Phase);
        Assert.Equal(activeOperationId, error.PartialResult.ActiveOperationId);
        Assert.Equal("restoreNeeded", error.PartialResult.TransactionPhase);
    }

    [Fact]
    public void Parse_NonZeroSuccessClaimDoesNotExposeTrustedResult()
    {
        var error = Assert.Throws<CoreProtocolException>(() =>
            CoreResultParser.Parse(StatusJson(), 5, CoreCommand.Status, OperationId));

        Assert.Equal(CoreProtocolError.ProcessFailed, error.Error);
        Assert.Null(error.PartialResult);
    }

    [Fact]
    public void Parse_RejectsTargetForQueryCommand()
    {
        var error = Assert.Throws<CoreProtocolException>(() =>
            CoreResultParser.Parse(DetailJson(), 0, CoreCommand.CheckDetail, OperationId, "A"));

        Assert.Equal(CoreProtocolError.InvalidTarget, error.Error);
    }

    public static string DetailJson(
        string? changedId = null,
        string changedStatus = "warn",
        bool blocking = false,
        bool canLaunch = true)
    {
        var checks = new JsonArray();
        foreach (var id in ExpectedCheckIds)
        {
            var status = id == changedId ? changedStatus : "ok";
            var isBlocking = id == changedId ? blocking : false;
            checks.Add(new JsonObject
            {
                ["id"] = id,
                ["name"] = id,
                ["status"] = status,
                ["blocking"] = isBlocking,
                ["detail"] = $"{id} detail"
            });
        }

        return new JsonObject
        {
            ["schemaVersion"] = 1,
            ["operationId"] = OperationId.ToString(),
            ["command"] = "checkdetail",
            ["success"] = true,
            ["code"] = "ok",
            ["message"] = "synthetic",
            ["checks"] = checks,
            ["canLaunch"] = canLaunch
        }.ToJsonString();
    }

    public static string StatusJson(
        string current = "A",
        string phase = "idle",
        bool recoveryRequired = false,
        Guid? activeOperationId = null,
        string? transactionPhase = null) =>
        new JsonObject
        {
            ["schemaVersion"] = 1,
            ["operationId"] = OperationId.ToString(),
            ["command"] = "status",
            ["success"] = true,
            ["code"] = "ok",
            ["message"] = "synthetic",
            ["current"] = current,
            ["phase"] = phase,
            ["recoveryRequired"] = recoveryRequired,
            ["activeOperationId"] = activeOperationId?.ToString("D"),
            ["transactionPhase"] = transactionPhase
        }.ToJsonString();

    public static string SwitchJson(bool success = true, string phase = "completed", bool recoveryRequired = false, string current = "B")
    {
        var ongoing = phase is "running" or "recoveryRequired" || recoveryRequired;
        return new JsonObject
        {
            ["schemaVersion"] = 1,
            ["operationId"] = OperationId.ToString(),
            ["command"] = "switch",
            ["success"] = success,
            ["code"] = success ? "ok" : "running",
            ["message"] = "synthetic",
            ["current"] = current,
            ["phase"] = phase,
            ["recoveryRequired"] = recoveryRequired,
            ["activeOperationId"] = ongoing ? "76edf30d-d528-47dd-81e0-176f5a3cd895" : null,
            ["transactionPhase"] = ongoing ? phase == "recoveryRequired" ? "restoreNeeded" : "copyingToB" : null
        }.ToJsonString();
    }

    private static JsonObject ParseObject(string json) =>
        JsonNode.Parse(json)?.AsObject() ?? throw new InvalidOperationException("Fixture is not an object.");

    internal static Guid TestOperationId => OperationId;
}
