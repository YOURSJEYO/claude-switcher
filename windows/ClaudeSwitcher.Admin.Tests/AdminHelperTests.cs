using System.Reflection;
using ClaudeSwitcher.Admin;
using Xunit;

namespace ClaudeSwitcher.Admin.Tests;

public sealed class AdminHelperTests
{
    [Fact]
    public void Operation_names_are_closed_and_exact()
    {
        Assert.True(AdminOperationNames.TryParse("set-time-zone", out var timeZone));
        Assert.Equal(AdminOperation.SetTimeZone, timeZone);
        Assert.True(AdminOperationNames.TryParse("disable-ipv6", out var ipv6));
        Assert.Equal(AdminOperation.DisableIpv6, ipv6);
        Assert.True(AdminOperationNames.TryParse("flush-dns", out var dns));
        Assert.Equal(AdminOperation.FlushDns, dns);
        Assert.True(AdminOperationNames.TryParse("register-bodyguard-task", out var register));
        Assert.Equal(AdminOperation.RegisterBodyguardTask, register);
        Assert.True(AdminOperationNames.TryParse("remove-bodyguard-task", out var remove));
        Assert.Equal(AdminOperation.RemoveBodyguardTask, remove);
        Assert.True(AdminOperationNames.TryParse("repair-system", out var repair));
        Assert.Equal(AdminOperation.RepairSystem, repair);
        Assert.True(AdminOperationNames.TryParse("migrate-legacy-bodyguard", out var migrate));
        Assert.Equal(AdminOperation.MigrateLegacyBodyguard, migrate);
        Assert.False(AdminOperationNames.TryParse("run-script", out _));
        Assert.False(AdminOperationNames.TryParse("Set-TimeZone", out _));
        Assert.False(AdminOperationNames.TryParse("", out _));
    }

    [Fact]
    public void Scalar_cli_parses_the_exact_public_contract()
    {
        var args = new[]
        {
            "--operation", "set-time-zone",
            "--user-sid", ValidSid,
            "--session-id", "2",
            "--time-zone-id", "Pacific Standard Time"
        };

        Assert.True(AdminRequest.TryParse(args, out var request, out var error), error);
        Assert.NotNull(request);
        Assert.Equal(AdminOperation.SetTimeZone, request.Operation);
        Assert.Equal(ValidSid, request.UserSid);
        Assert.Equal(2, request.SessionId);
        Assert.Equal("Pacific Standard Time", request.TimeZoneId);
    }

    [Fact]
    public void Removal_may_omit_session_but_still_requires_user_sid()
    {
        Assert.True(AdminRequest.TryParse(
            new[] { "--operation", "remove-bodyguard-task", "--user-sid", ValidSid },
            out var request,
            out var error), error);
        Assert.Equal(AdminOperation.RemoveBodyguardTask, request!.Operation);
        Assert.Null(request.SessionId);

        Assert.False(AdminRequest.TryParse(
            new[] { "--operation", "remove-bodyguard-task" },
            out _,
            out var missingSid));
        Assert.Contains("user-sid", missingSid, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Repair_system_validates_timezone_and_requires_interactive_session()
    {
        Assert.True(AdminRequest.TryParse(
            new[] { "--operation", "repair-system", "--user-sid", ValidSid, "--session-id", "2", "--time-zone-id", "Tokyo Standard Time" },
            out var request,
            out var error), error);
        Assert.Equal(AdminOperation.RepairSystem, request!.Operation);
        Assert.Equal(2, request.SessionId);
        Assert.Equal("Tokyo Standard Time", request.TimeZoneId);

        Assert.False(AdminRequest.TryParse(
            new[] { "--operation", "repair-system", "--user-sid", ValidSid, "--time-zone-id", "Tokyo Standard Time" },
            out _,
            out var noSession));
        Assert.Contains("session-id", noSession, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("repair-system", noSession, StringComparison.OrdinalIgnoreCase);

        Assert.True(AdminRequest.TryParse(
            new[] { "--operation", "repair-system", "--user-sid", ValidSid, "--session-id", "2" },
            out _,
            out var noZone));
        Assert.Equal(string.Empty, noZone);
    }

    [Fact]
    public void Cloud_directory_user_sid_is_supported_without_accepting_service_sids()
    {
        const string entraSid = "S-1-12-1-1-2-3-4";
        Assert.True(AdminRequest.IsUserSid(entraSid));
        Assert.False(AdminRequest.IsUserSid("S-1-12-1-1-2-3"));
        Assert.False(AdminRequest.IsUserSid("S-1-5-18"));
    }

    [Theory]
    [InlineData("--request-file", "request.json")]
    [InlineData("--path", "C:\\synthetic\\payload")]
    [InlineData("--command", "cmd.exe")]
    [InlineData("--executable", "cmd.exe")]
    [InlineData("--arguments", "/c whoami")]
    [InlineData("--script", "payload.ps1")]
    [InlineData("--working-directory", "C:\\synthetic")]
    [InlineData("--callback", "run")]
    public void Unknown_and_caller_controlled_options_are_rejected(string option, string value)
    {
        var args = new[]
        {
            "--operation", "flush-dns",
            "--user-sid", ValidSid,
            option, value
        };

        Assert.False(AdminRequest.TryParse(args, out var request, out var error));
        Assert.Null(request);
        Assert.Contains("unknown option", error, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData("--operation", "flush-dns", "--operation", "disable-ipv6")]
    [InlineData("--operation", "flush-dns", "--user-sid", ValidSid, "--user-sid", OtherSid)]
    [InlineData("--operation", "flush-dns", "--user-sid", ValidSid, "--session-id", "1", "--session-id", "2")]
    public void Duplicate_options_are_rejected(params string[] args)
    {
        Assert.False(AdminRequest.TryParse(args, out _, out var error));
        Assert.Contains("duplicate", error, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData("--operation")]
    [InlineData("--operation", "flush-dns", "--user-sid")]
    [InlineData("--operation", "flush-dns", "--user-sid", ValidSid, "--session-id")]
    [InlineData("--operation", "set-time-zone", "--user-sid", ValidSid, "--time-zone-id")]
    public void Missing_values_are_rejected(params string[] args)
    {
        Assert.False(AdminRequest.TryParse(args, out _, out var error));
        Assert.Contains("value", error, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData("--user-sid", "S-1-5-21-1004336348-1177238915-682003330-1001")]
    [InlineData("--operation", "made-up", "--user-sid", "S-1-5-21-1004336348-1177238915-682003330-1001")]
    public void Missing_or_invalid_operation_is_rejected(params string[] args)
    {
        Assert.False(AdminRequest.TryParse(args, out _, out var error));
        Assert.Contains("operation", error, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData("not-a-sid")]
    [InlineData("S-1-5-21-1-2-3")]
    [InlineData("S-1-5-21-1-2-3-500-extra")]
    [InlineData("S-1-5-21-1-2-3-500\n")]
    [InlineData("S-1-5-21-1-2-3-500;whoami")]
    [InlineData("S-1-5-18")]
    public void Malformed_or_service_sid_is_rejected(string sid)
    {
        Assert.False(AdminRequest.TryParse(
            new[] { "--operation", "flush-dns", "--user-sid", sid },
            out _,
            out var error));
        Assert.Contains("user-sid", error, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData("0")]
    [InlineData("-1")]
    [InlineData("abc")]
    [InlineData("2147483648")]
    public void Session_id_must_be_a_positive_integer(string sessionId)
    {
        Assert.False(AdminRequest.TryParse(
            new[] { "--operation", "register-bodyguard-task", "--user-sid", ValidSid, "--session-id", sessionId },
            out _,
            out var error));
        Assert.Contains("session-id", error, StringComparison.OrdinalIgnoreCase);
    }


    [Fact]
    public void Legacy_task_policy_accepts_only_the_exact_closed_contract()
    {
        var profile = Path.Combine(Path.GetTempPath(), "legacy-profile");
        var result = LegacyBodyguardTaskPolicy.ValidateTaskXml(LegacyTaskXml(profile), ValidSid, profile);

        Assert.True(result.IsValid, result.Error);
        Assert.Equal(LegacyScriptPath(profile), result.ScriptPath);
    }

    [Fact]
    public void Legacy_task_policy_allows_a_missing_trigger_user_but_rejects_other_users()
    {
        var profile = Path.Combine(Path.GetTempPath(), "legacy-profile");
        Assert.True(LegacyBodyguardTaskPolicy.ValidateTaskXml(
            LegacyTaskXml(profile, triggerUserId: ValidSid), ValidSid, profile).IsValid);
        Assert.True(LegacyBodyguardTaskPolicy.ValidateTaskXml(
            LegacyTaskXml(profile, triggerUserId: null), ValidSid, profile).IsValid);
        Assert.False(LegacyBodyguardTaskPolicy.ValidateTaskXml(
            LegacyTaskXml(profile, triggerUserId: OtherSid), ValidSid, profile).IsValid);
        Assert.False(LegacyBodyguardTaskPolicy.ValidateTaskXml(
            LegacyTaskXml(profile, principalSid: OtherSid), ValidSid, profile).IsValid);
    }

    [Fact]
    public void Legacy_task_policy_rejects_duplicate_or_arbitrary_actions()
    {
        var profile = Path.Combine(Path.GetTempPath(), "legacy-profile");
        var valid = LegacyTaskXml(profile);
        var duplicate = valid.Replace(
            "</Actions>",
            "<Exec><Command>powershell.exe</Command><Arguments>-NoProfile</Arguments></Exec></Actions>",
            StringComparison.Ordinal);
        var arbitrary = valid.Replace("<Exec>", "<ComHandler>", StringComparison.Ordinal)
            .Replace("</Exec>", "</ComHandler>", StringComparison.Ordinal);

        Assert.False(LegacyBodyguardTaskPolicy.ValidateTaskXml(duplicate, ValidSid, profile).IsValid);
        Assert.False(LegacyBodyguardTaskPolicy.ValidateTaskXml(arbitrary, ValidSid, profile).IsValid);
    }

    [Fact]
    public void Legacy_task_policy_rejects_external_namespaces_and_caller_controlled_commands()
    {
        var profile = Path.Combine(Path.GetTempPath(), "legacy-profile");
        var valid = LegacyTaskXml(profile);
        var externalNamespace = valid.Replace(
            "http://schemas.microsoft.com/windows/2004/02/mit/task",
            "urn:attacker",
            StringComparison.Ordinal);

        Assert.False(LegacyBodyguardTaskPolicy.ValidateTaskXml(externalNamespace, ValidSid, profile).IsValid);
        Assert.False(LegacyBodyguardTaskPolicy.ValidateTaskXml(
            LegacyTaskXml(profile, command: "cmd.exe"), ValidSid, profile).IsValid);
        Assert.False(LegacyBodyguardTaskPolicy.ValidateTaskXml(
            LegacyTaskXml(profile, arguments: LegacyArguments(profile) + " -Command whoami"), ValidSid, profile).IsValid);
    }
    [Fact]
    public void Repair_system_is_part_of_the_closed_operation_enum()
    {
        Assert.True(AdminOperationNames.TryParse("repair-system", out var repair));
        Assert.Equal(AdminOperation.RepairSystem, repair);
        Assert.False(AdminOperationNames.TryParse("repair-system ", out _));
    }

    [Fact]
    public void Repair_system_requires_a_session_id()
    {
        Assert.False(AdminRequest.TryParse(
            new[] { "--operation", "repair-system", "--user-sid", ValidSid },
            out _,
            out var error));
        Assert.Contains("session-id", error, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Legacy_migration_requires_a_session_and_rejects_extra_arguments()
    {
        Assert.False(AdminRequest.TryParse(
            new[] { "--operation", "migrate-legacy-bodyguard", "--user-sid", ValidSid },
            out _, out var missingSession));
        Assert.Contains("session-id", missingSession, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("migrate-legacy-bodyguard", missingSession, StringComparison.OrdinalIgnoreCase);

        Assert.True(AdminRequest.TryParse(
            new[] { "--operation", "migrate-legacy-bodyguard", "--user-sid", ValidSid, "--session-id", "2" },
            out var request, out var error), error);
        Assert.Equal(AdminOperation.MigrateLegacyBodyguard, request!.Operation);
        Assert.Equal(2, request.SessionId);

        Assert.False(AdminRequest.TryParse(
            new[]
            {
                "--operation", "migrate-legacy-bodyguard",
                "--user-sid", ValidSid,
                "--session-id", "2",
                "--time-zone-id", "Pacific Standard Time"
            },
            out _, out var extraArgument));
        Assert.Contains("time-zone-id", extraArgument, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Repair_system_accepts_an_optional_time_zone()
    {
        Assert.True(AdminRequest.TryParse(
            new[] { "--operation", "repair-system", "--user-sid", ValidSid, "--session-id", "2" },
            out var withoutTimeZone,
            out var withoutError), withoutError);
        Assert.Null(withoutTimeZone!.TimeZoneId);

        Assert.True(AdminRequest.TryParse(
            new[]
            {
                "--operation", "repair-system",
                "--user-sid", ValidSid,
                "--session-id", "2",
                "--time-zone-id", "Pacific Standard Time"
            },
            out var withTimeZone,
            out var withError), withError);
        Assert.Equal("Pacific Standard Time", withTimeZone!.TimeZoneId);

        Assert.False(AdminRequest.TryParse(
            new[] { "--operation", "flush-dns", "--user-sid", ValidSid, "--time-zone-id", "Pacific Standard Time" },
            out _,
            out var invalidTimeZone));
        Assert.Contains("set-time-zone", invalidTimeZone, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("repair-system", invalidTimeZone, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Repair_system_runs_the_fixed_sequence_after_one_identity_and_root_resolution()
    {
        var operations = new RecordingSystemOperations();
        var resolver = new FakeIdentityResolver(InteractiveIdentityResult.Success(ValidSid, 2));
        var roots = new FakeInstallRootProvider(InstallRootResult.Success(Path.Combine(Path.GetTempPath(), "synthetic-root")));
        var context = new AdminContext(resolver, roots, operations);

        var result = context.Execute(Request(
            AdminOperation.RepairSystem,
            ValidSid,
            sessionId: 2,
            timeZoneId: "Pacific Standard Time"));

        Assert.Equal(AdminExitCode.Success, result.ExitCode);
        Assert.Equal(1, resolver.CallCount);
        Assert.Equal(1, roots.CallCount);
        Assert.Equal("time-zone,ipv6,dns,task", operations.Sequence);
        Assert.Equal(4, operations.CallCount);
    }

    [Fact]
    public void Legacy_migration_is_dispatched_only_after_identity_and_root_validation()
    {
        var operations = new RecordingSystemOperations();
        var resolver = new FakeIdentityResolver(InteractiveIdentityResult.Success(ValidSid, 2));
        var roots = new FakeInstallRootProvider(InstallRootResult.Success(Path.Combine(Path.GetTempPath(), "synthetic-root")));
        var context = new AdminContext(resolver, roots, operations);

        var result = context.Execute(Request(AdminOperation.MigrateLegacyBodyguard, ValidSid, sessionId: 2));

        Assert.Equal(AdminExitCode.Success, result.ExitCode);
        Assert.Equal(1, resolver.CallCount);
        Assert.Equal(1, roots.CallCount);
        Assert.Equal("migrate-legacy-bodyguard", operations.Sequence);
        Assert.Equal(1, operations.MigrateCalls);
        Assert.Equal("ClaudeSwitcher.Bodyguard." + ValidSid, operations.LastMigratedTaskName);
    }

    [Fact]
    public void Legacy_migration_failure_reports_the_fixed_stage_without_claiming_success()
    {
        var operations = new RecordingSystemOperations { ThrowOnMigration = true };
        var resolver = new FakeIdentityResolver(InteractiveIdentityResult.Success(ValidSid, 2));
        var roots = new FakeInstallRootProvider(InstallRootResult.Success(Path.Combine(Path.GetTempPath(), "synthetic-root")));
        var context = new AdminContext(resolver, roots, operations);

        var result = context.Execute(Request(AdminOperation.MigrateLegacyBodyguard, ValidSid, sessionId: 2));

        Assert.Equal(AdminExitCode.OperationFailed, result.ExitCode);
        Assert.Contains("failed-stage=migrate-legacy-bodyguard", result.Error, StringComparison.Ordinal);
        Assert.Contains("completed-stages=none", result.Error, StringComparison.Ordinal);
        Assert.DoesNotContain("synthetic migration failure", result.Error, StringComparison.Ordinal);
    }

    [Fact]
    public void Repair_system_skips_time_zone_when_not_supplied()
    {
        var operations = new RecordingSystemOperations();
        var resolver = new FakeIdentityResolver(InteractiveIdentityResult.Success(ValidSid, 2));
        var roots = new FakeInstallRootProvider(InstallRootResult.Success(Path.Combine(Path.GetTempPath(), "synthetic-root")));
        var context = new AdminContext(resolver, roots, operations);

        var result = context.Execute(Request(AdminOperation.RepairSystem, ValidSid, sessionId: 2));

        Assert.Equal(AdminExitCode.Success, result.ExitCode);
        Assert.Equal("ipv6,dns,task", operations.Sequence);
        Assert.Equal(1, resolver.CallCount);
        Assert.Equal(1, roots.CallCount);
    }

    [Fact]
    public void Repair_system_stops_after_the_first_fixed_step_that_fails()
    {
        var operations = new RecordingSystemOperations { ThrowOnDns = true };
        var resolver = new FakeIdentityResolver(InteractiveIdentityResult.Success(ValidSid, 2));
        var roots = new FakeInstallRootProvider(InstallRootResult.Success(Path.Combine(Path.GetTempPath(), "synthetic-root")));
        var context = new AdminContext(resolver, roots, operations);

        var result = context.Execute(Request(
            AdminOperation.RepairSystem,
            ValidSid,
            sessionId: 2,
            timeZoneId: "Pacific Standard Time"));

        Assert.Equal(AdminExitCode.OperationFailed, result.ExitCode);
        Assert.Equal("time-zone,ipv6,dns", operations.Sequence);
        Assert.Equal(0, operations.RegisterCalls);
        Assert.Contains("failed-stage=dns", result.Error, StringComparison.Ordinal);
        Assert.Contains("completed-stages=time-zone,ipv6", result.Error, StringComparison.Ordinal);
        Assert.DoesNotContain("synthetic failure", result.Error, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("S-1-12-1-1234567890-1234567890-1234567890-1234567890")]
    [InlineData("S-1-12-1-0-0-0-1001")]
    public void Entra_id_user_sid_form_is_accepted(string sid)
    {
        Assert.True(AdminRequest.TryParse(
            new[] { "--operation", "flush-dns", "--user-sid", sid },
            out var request,
            out var error), error);
        Assert.Equal(sid, request!.UserSid);
        Assert.True(AdminRequest.IsUserSid(sid));
    }

    [Theory]
    [InlineData("S-1-12-1-1-2-3")]
    [InlineData("S-1-12-1-1-2-3-4-5")]
    [InlineData("S-1-12-1-a-b-c-d")]
    [InlineData("S-1-12-2-1-2-3-4")]
    [InlineData("S-1-5-32-545")]
    [InlineData("S-1-5-20")]
    [InlineData("S-1-1-0")]
    public void Non_user_or_malformed_sid_is_rejected(string sid)
    {
        Assert.False(AdminRequest.IsUserSid(sid));
        Assert.False(AdminRequest.TryParse(
            new[] { "--operation", "flush-dns", "--user-sid", sid },
            out _,
            out var error));
        Assert.Contains("user-sid", error, StringComparison.OrdinalIgnoreCase);
    }
    [Fact]
    public void Registration_requires_a_session_id()
    {
        Assert.False(AdminRequest.TryParse(
            new[] { "--operation", "register-bodyguard-task", "--user-sid", ValidSid },
            out _,
            out var error));
        Assert.Contains("session-id", error, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("register-bodyguard-task", error, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("repair-system", error, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData("flush-dns")]
    [InlineData("disable-ipv6")]
    [InlineData("register-bodyguard-task")]
    [InlineData("remove-bodyguard-task")]
    public void Time_zone_is_only_accepted_for_set_time_zone_and_repair_system(string operation)
    {
        Assert.False(AdminRequest.TryParse(
            new[]
            {
                "--operation", operation,
                "--user-sid", ValidSid,
                "--session-id", "1",
                "--time-zone-id", "Pacific Standard Time"
            },
            out _,
            out var error));
        Assert.Contains("time-zone-id", error, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData("")]
    [InlineData("Eastern Standard Time\n")]
    [InlineData("..\\Eastern Standard Time")]
    [InlineData("Eastern Standard Time;calc")]
    [InlineData("Not A Real Time Zone")]
    public void Set_time_zone_rejects_unsafe_or_unknown_scalar_values(string timeZoneId)
    {
        Assert.False(AdminRequest.TryParse(
            new[]
            {
                "--operation", "set-time-zone",
                "--user-sid", ValidSid,
                "--time-zone-id", timeZoneId
            },
            out _,
            out var error));
        Assert.Contains("time-zone-id", error, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Context_uses_WTS_resolver_and_rejects_a_different_interactive_sid()
    {
        var operations = new RecordingSystemOperations();
        var resolver = new FakeIdentityResolver(InteractiveIdentityResult.Success(OtherSid, 1));
        var roots = new FakeInstallRootProvider(InstallRootResult.Success(Path.Combine(Path.GetTempPath(), "synthetic-root")));
        var context = new AdminContext(resolver, roots, operations);

        var result = context.Execute(Request(AdminOperation.FlushDns, ValidSid, sessionId: 1));

        Assert.Equal(AdminExitCode.IdentityOrSessionMismatch, result.ExitCode);
        Assert.Equal(1, resolver.CallCount);
        Assert.Equal(0, operations.CallCount);
        Assert.Equal(0, roots.CallCount);
    }

    [Fact]
    public void Context_rejects_a_session_that_does_not_match_the_interactive_session()
    {
        var operations = new RecordingSystemOperations();
        var resolver = new FakeIdentityResolver(InteractiveIdentityResult.Success(ValidSid, 1));
        var roots = new FakeInstallRootProvider(InstallRootResult.Success(Path.Combine(Path.GetTempPath(), "synthetic-root")));
        var context = new AdminContext(resolver, roots, operations);

        var result = context.Execute(Request(AdminOperation.RegisterBodyguardTask, ValidSid, sessionId: 2));

        Assert.Equal(AdminExitCode.IdentityOrSessionMismatch, result.ExitCode);
        Assert.Equal(2, resolver.RequestedSessionId);
        Assert.Equal(0, operations.CallCount);
    }

    [Fact]
    public void Context_fails_closed_when_install_root_validation_fails()
    {
        var operations = new RecordingSystemOperations();
        var resolver = new FakeIdentityResolver(InteractiveIdentityResult.Success(ValidSid, 1));
        var roots = new FakeInstallRootProvider(InstallRootResult.Failure("install root is user-writable"));
        var context = new AdminContext(resolver, roots, operations);

        var result = context.Execute(Request(AdminOperation.FlushDns, ValidSid, sessionId: 1));

        Assert.Equal(AdminExitCode.UnsafeInstallRoot, result.ExitCode);
        Assert.Equal(0, operations.CallCount);
    }

    [Fact]
    public void Fixed_operations_dispatch_only_after_identity_and_root_validation()
    {
        var operations = new RecordingSystemOperations();
        var resolver = new FakeIdentityResolver(InteractiveIdentityResult.Success(ValidSid, 1));
        var roots = new FakeInstallRootProvider(InstallRootResult.Success(Path.Combine(Path.GetTempPath(), "synthetic-root")));
        var context = new AdminContext(resolver, roots, operations);

        Assert.Equal(AdminExitCode.Success, context.Execute(Request(AdminOperation.SetTimeZone, ValidSid, 1, "Pacific Standard Time")).ExitCode);
        Assert.Equal(AdminExitCode.Success, context.Execute(Request(AdminOperation.DisableIpv6, ValidSid, 1)).ExitCode);
        Assert.Equal(AdminExitCode.Success, context.Execute(Request(AdminOperation.FlushDns, ValidSid, 1)).ExitCode);
        Assert.Equal(AdminExitCode.Success, context.Execute(Request(AdminOperation.RegisterBodyguardTask, ValidSid, 1)).ExitCode);
        Assert.Equal(AdminExitCode.Success, context.Execute(Request(AdminOperation.RemoveBodyguardTask, ValidSid)).ExitCode);
        Assert.Equal(1, operations.TimeZoneCalls);
        Assert.Equal(1, operations.Ipv6Calls);
        Assert.Equal(1, operations.DnsCalls);
        Assert.Equal(1, operations.RegisterCalls);
        Assert.Equal(1, operations.RemoveCalls);
    }

    [Fact]
    public void Task_paths_and_names_are_derived_from_root_and_validated_sid()
    {
        var root = Path.Combine(Path.GetTempPath(), "claude-switcher-admin-tests", Guid.NewGuid().ToString("N"));

        var paths = BodyguardTaskPaths.Create(root, ValidSid);

        Assert.Equal(Path.Combine(root, "scripts", "claude-bodyguard.ps1"), paths.ScriptPath);
        Assert.Equal("ClaudeSwitcher.Bodyguard." + ValidSid, paths.TaskName);
    }

    [Theory]
    [InlineData("S-1-5-21-1-2-3-500;calc")]
    [InlineData("..\\outside")]
    [InlineData("")]
    public void Task_paths_reject_an_invalid_sid_instead_of_building_a_path(string sid)
    {
        Assert.Throws<ArgumentException>(() => BodyguardTaskPaths.Create(Path.GetTempPath(), sid));
    }

    [Fact]
    public void Repeated_registration_is_a_no_change_when_task_ownership_matches()
    {
        var expected = BodyguardTaskPaths.Create(Path.Combine(Path.GetTempPath(), "synthetic-root"), ValidSid);
        var existing = ExistingTask(expected, ValidSid, expected.TaskName);

        var decision = BodyguardTaskPolicy.Evaluate(expected, ValidSid, existing);

        Assert.Equal(BodyguardTaskDecision.NoChange, decision);
    }

    [Theory]
    [InlineData(OtherSid, false)]
    [InlineData(ValidSid, true)]
    public void Existing_task_with_wrong_owner_or_action_is_rejected(string principalSid, bool wrongAction)
    {
        var expected = BodyguardTaskPaths.Create(Path.Combine(Path.GetTempPath(), "synthetic-root"), ValidSid);
        var existing = ExistingTask(expected, principalSid, expected.TaskName) with
        {
            ActionArguments = wrongAction ? expected.ActionArguments + " -Command evil" : expected.ActionArguments
        };

        var decision = BodyguardTaskPolicy.Evaluate(expected, ValidSid, existing);

        Assert.Equal(BodyguardTaskDecision.Reject, decision);
    }

    [Theory]
    [InlineData("Password")]
    [InlineData("HighestAvailable")]
    [InlineData("Boot")]
    public void Bodyguard_task_rejects_wrong_logon_privilege_or_trigger(string invalidField)
    {
        var expected = BodyguardTaskPaths.Create(Path.Combine(Path.GetTempPath(), "synthetic-root"), ValidSid);
        var existing = ExistingTask(expected, ValidSid, expected.TaskName) with
        {
            LogonType = invalidField == "Password" ? invalidField : "InteractiveToken",
            RunLevel = invalidField == "HighestAvailable" ? invalidField : "LeastPrivilege",
            TriggerKind = invalidField == "Boot" ? invalidField : "LogonTrigger",
            Enabled = true,
            AllowDemandStart = true
        };
        Assert.Equal(BodyguardTaskDecision.Reject, BodyguardTaskPolicy.Evaluate(expected, ValidSid, existing));
    }

    [Fact]
    public void Bodyguard_task_xml_parser_preserves_exact_command_and_identity_contract()
    {
        var paths = BodyguardTaskPaths.Create(Path.Combine(Path.GetTempPath(), "synthetic-root"), ValidSid);
        var xml = CanonicalTaskXml(paths, ValidSid, CanonicalSettingsXml());

        var parsed = BodyguardTaskPolicy.ParseTaskXml(xml, paths.TaskName);

        Assert.Equal(BodyguardTaskDecision.NoChange, BodyguardTaskPolicy.Evaluate(paths, ValidSid, parsed));
        Assert.Equal(paths.PowerShellPath, parsed.ActionCommand);
        Assert.Equal(paths.ActionArguments, parsed.ActionArguments);
        Assert.Equal("Author", parsed.ActionContext);
        Assert.True(parsed.Enabled);
    }
    [Fact]
    public void Bodyguard_task_xml_accepts_scheduler_default_fields_but_rejects_security_relevant_changes()
    {
        var paths = BodyguardTaskPaths.Create(Path.Combine(Path.GetTempPath(), "synthetic-root"), ValidSid);
        var xml = CanonicalTaskXml(paths, ValidSid, """
          <Settings>
            <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
            <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
            <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
            <AllowHardTerminate>true</AllowHardTerminate>
            <StartWhenAvailable>false</StartWhenAvailable>
            <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
            <IdleSettings><StopOnIdleEnd>true</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
            <AllowStartOnDemand>true</AllowStartOnDemand>
            <Enabled>true</Enabled>
            <Hidden>false</Hidden>
            <RunOnlyIfIdle>false</RunOnlyIfIdle>
            <WakeToRun>false</WakeToRun>
            <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
            <Priority>7</Priority>
          </Settings>
        """);

        var parsed = BodyguardTaskPolicy.ParseTaskXml(xml, paths.TaskName);

        Assert.Equal(BodyguardTaskDecision.NoChange, BodyguardTaskPolicy.Evaluate(paths, ValidSid, parsed));
    }

    [Theory]
    [InlineData("<WorkingDirectory>C:\\synthetic</WorkingDirectory>")]
    [InlineData("<Unknown>C:\\synthetic</Unknown>")]
    public void Bodyguard_task_xml_rejects_extra_action_fields(string extraActionXml)
    {
        var paths = BodyguardTaskPaths.Create(Path.Combine(Path.GetTempPath(), "synthetic-root"), ValidSid);
        var xml = CanonicalTaskXml(paths, ValidSid, CanonicalSettingsXml(), extraActionXml);

        var parsed = BodyguardTaskPolicy.ParseTaskXml(xml, paths.TaskName);

        Assert.Equal(BodyguardTaskDecision.Reject, BodyguardTaskPolicy.Evaluate(paths, ValidSid, parsed));
    }

    [Theory]
    [InlineData("<Command>", "<Command xmlns=\"urn:foreign\">")]
    [InlineData("<Arguments>", "<Arguments xmlns=\"urn:foreign\">")]
    [InlineData("<UserId>", "<UserId xmlns=\"urn:foreign\">")]
    [InlineData("<MultipleInstancesPolicy>", "<MultipleInstancesPolicy xmlns=\"urn:foreign\">")]
    [InlineData("</Settings>", "<MultipleInstancesPolicy xmlns=\"urn:foreign\">IgnoreNew</MultipleInstancesPolicy></Settings>")]
    public void Bodyguard_task_xml_rejects_foreign_namespace_ownership_children(
        string original,
        string replacement)
    {
        var paths = BodyguardTaskPaths.Create(Path.Combine(Path.GetTempPath(), "synthetic-root"), ValidSid);
        var xml = CanonicalTaskXml(paths, ValidSid, CanonicalSettingsXml());

        Assert.Contains(original, xml, StringComparison.Ordinal);
        xml = xml.Replace(original, replacement, StringComparison.Ordinal);

        var parsed = BodyguardTaskPolicy.ParseTaskXml(xml, paths.TaskName);

        Assert.Equal(BodyguardTaskDecision.Reject, BodyguardTaskPolicy.Evaluate(paths, ValidSid, parsed));
    }
    [Theory]
    [InlineData("Author", true)]
    [InlineData("Product", false)]
    public void Bodyguard_task_xml_requires_the_author_action_context(string context, bool expected)
    {
        var paths = BodyguardTaskPaths.Create(Path.Combine(Path.GetTempPath(), "synthetic-root"), ValidSid);
        var xml = CanonicalTaskXml(paths, ValidSid, CanonicalSettingsXml()).Replace("Context=\"Author\"", $"Context=\"{context}\"", StringComparison.Ordinal);

        var parsed = BodyguardTaskPolicy.ParseTaskXml(xml, paths.TaskName);

        Assert.Equal(expected, BodyguardTaskPolicy.Evaluate(paths, ValidSid, parsed) == BodyguardTaskDecision.NoChange);
    }

    [Theory]
    [InlineData("action", false)]
    [InlineData("trigger", false)]
    public void Bodyguard_task_xml_rejects_extra_action_or_trigger_siblings(string sibling, bool expected)
    {
        var paths = BodyguardTaskPaths.Create(Path.Combine(Path.GetTempPath(), "synthetic-root"), ValidSid);
        var xml = CanonicalTaskXml(paths, ValidSid, CanonicalSettingsXml());
        xml = sibling == "action"
            ? xml.Replace(
                "<Actions Context=\"Author\">",
                "<Actions Context=\"Author\"><ComHandler><ClassId>{00000000-0000-0000-0000-000000000000}</ClassId></ComHandler>",
                StringComparison.Ordinal)
            : xml.Replace(
                "</Triggers>",
                "<BootTrigger><Enabled>true</Enabled></BootTrigger></Triggers>",
                StringComparison.Ordinal);

        var parsed = BodyguardTaskPolicy.ParseTaskXml(xml, paths.TaskName);

        Assert.Equal(expected, BodyguardTaskPolicy.Evaluate(paths, ValidSid, parsed) == BodyguardTaskDecision.NoChange);
    }

    [Theory]
    [InlineData("MultipleInstancesPolicy", "Parallel")]
    [InlineData("DisallowStartIfOnBatteries", "true")]
    [InlineData("StopIfGoingOnBatteries", "true")]
    [InlineData("ExecutionTimeLimit", "PT1H")]
    public void Bodyguard_task_xml_rejects_unsafe_instance_battery_or_time_limit_settings(string element, string value)
    {
        var paths = BodyguardTaskPaths.Create(Path.Combine(Path.GetTempPath(), "synthetic-root"), ValidSid);
        var original = element switch
        {
            "MultipleInstancesPolicy" => "IgnoreNew",
            "ExecutionTimeLimit" => "PT0S",
            _ => "false"
        };
        var settings = CanonicalSettingsXml().Replace($"<{element}>{original}</{element}>", $"<{element}>{value}</{element}>", StringComparison.Ordinal);
        var xml = CanonicalTaskXml(paths, ValidSid, settings);

        var parsed = BodyguardTaskPolicy.ParseTaskXml(xml, paths.TaskName);

        Assert.Equal(BodyguardTaskDecision.Reject, BodyguardTaskPolicy.Evaluate(paths, ValidSid, parsed));
    }

    [Theory]
    [InlineData("<Enabled>false</Enabled>", "<Enabled>false</Enabled>", false)]
    [InlineData("", "<Enabled>true</Enabled>", false)]
    [InlineData("<Enabled>true</Enabled>", "", false)]
    [InlineData("<Enabled>true</Enabled>", "<Enabled>true</Enabled>", true)]
    public void Bodyguard_task_xml_requires_enabled_task_and_trigger(
        string triggerEnabledXml,
        string taskEnabledXml,
        bool expected)
    {
        var paths = BodyguardTaskPaths.Create(Path.Combine(Path.GetTempPath(), "synthetic-root"), ValidSid);
        var settings = CanonicalSettingsXml().Replace(
            "<Enabled>true</Enabled>",
            taskEnabledXml,
            StringComparison.Ordinal);
        var xml = CanonicalTaskXml(paths, ValidSid, settings)
            .Replace("<LogonTrigger><Enabled>true</Enabled>", "<LogonTrigger>" + triggerEnabledXml, StringComparison.Ordinal);

        var parsed = BodyguardTaskPolicy.ParseTaskXml(xml, paths.TaskName);

        Assert.Equal(expected, BodyguardTaskPolicy.Evaluate(paths, ValidSid, parsed) == BodyguardTaskDecision.NoChange);
    }
    [Theory]
    [InlineData(null, false)]
    [InlineData(1, false)]
    [InlineData(4, false)]
    [InlineData(0, true)]
    public void Wts_identity_requires_an_active_connection_state(int? connectionState, bool expected)
    {
        Assert.Equal(expected, WtsSessionPolicy.IsActiveConnectionState(connectionState));
    }

    [Theory]
    [InlineData(2, 2, ValidSid, true)]
    [InlineData(1, 2, ValidSid, false)]
    [InlineData(2, 2, "S-1-5-18", false)]
    [InlineData(2, 2, "", false)]
    public void Wts_token_identity_requires_the_requested_session_and_a_supported_user_sid(
        int tokenSessionId,
        int requestedSessionId,
        string sid,
        bool expected)
    {
        Assert.Equal(expected, WtsSessionPolicy.IsSupportedTokenSession(tokenSessionId, requestedSessionId, sid));
    }


    [Fact]
    public void Process_token_identity_requires_one_unambiguous_supported_user_sid()
    {
        Assert.Equal(ValidSid, WtsSessionPolicy.SelectUnambiguousUserSid(new[] { ValidSid, ValidSid, "S-1-5-18", "" }));
        Assert.Null(WtsSessionPolicy.SelectUnambiguousUserSid(Array.Empty<string>()));
        Assert.Null(WtsSessionPolicy.SelectUnambiguousUserSid(new[] { ValidSid, OtherSid }));
    }

    [Fact]
    public void Process_token_identity_reports_ambiguous_supported_sids()
    {
        var selected = WtsSessionPolicy.SelectUnambiguousUserSid(new[] { ValidSid, OtherSid }, out var ambiguous);
        Assert.Null(selected);
        Assert.True(ambiguous);

        Assert.Equal(ValidSid, WtsSessionPolicy.SelectUnambiguousUserSid(new[] { ValidSid, ValidSid }, out var uniqueAmbiguous));
        Assert.False(uniqueAmbiguous);
    }

    [Fact]
    public void Protected_install_root_runtime_does_not_require_install_ps1()
    {
        var source = File.ReadAllText(Path.Combine(RepositoryRoot(), "windows", "ClaudeSwitcher.Admin", "ProtectedInstallRootProvider.cs"));

        Assert.DoesNotContain("install.ps1", source, StringComparison.OrdinalIgnoreCase);
    }
    [Fact]
    public void Protected_install_acl_policy_rejects_user_write_and_allows_read_only_access()
    {
        var users = new System.Security.Principal.SecurityIdentifier("S-1-5-32-545");
        var directUser = new System.Security.Principal.SecurityIdentifier("S-1-5-21-1-2-3-1001");
        Assert.False(InstallAclPolicy.IsUnsafeAllow(users, System.Security.AccessControl.FileSystemRights.ReadAndExecute, System.Security.AccessControl.PropagationFlags.None));
        Assert.True(InstallAclPolicy.IsUnsafeAllow(users, System.Security.AccessControl.FileSystemRights.WriteData, System.Security.AccessControl.PropagationFlags.None));
        Assert.True(InstallAclPolicy.IsUnsafeAllow(directUser, System.Security.AccessControl.FileSystemRights.ChangePermissions, System.Security.AccessControl.PropagationFlags.None));
        Assert.True(InstallAclPolicy.IsUnsafeAllow(users, unchecked((System.Security.AccessControl.FileSystemRights)0x40000000), System.Security.AccessControl.PropagationFlags.None));
        Assert.False(InstallAclPolicy.IsUnsafeAllow(users, System.Security.AccessControl.FileSystemRights.WriteData, System.Security.AccessControl.PropagationFlags.InheritOnly));
    }

    [Fact]
    public void Fixed_system_commands_use_absolute_system32_executables()
    {
        var runner = new RecordingFixedProcessRunner();
        var operations = new SystemOperations(runner);
        operations.SetTimeZone("Pacific Standard Time");
        operations.DisableIpv6();
        Assert.Equal(2, runner.Calls.Count);
        Assert.All(runner.Calls, call => Assert.True(Path.IsPathRooted(call.FilePath)));
        Assert.EndsWith("\\System32\\tzutil.exe", runner.Calls[0].FilePath, StringComparison.OrdinalIgnoreCase);
        Assert.EndsWith("\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", runner.Calls[1].FilePath, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("-NonInteractive", runner.Calls[1].Arguments);
    }

    [Fact]
    public void Missing_task_is_created_but_absent_removal_is_idempotent()
    {
        var expected = BodyguardTaskPaths.Create(Path.Combine(Path.GetTempPath(), "synthetic-root"), ValidSid);
        var missing = new ExistingBodyguardTask(false, null, null, null);

        Assert.Equal(BodyguardTaskDecision.Create, BodyguardTaskPolicy.Evaluate(expected, ValidSid, missing));
        Assert.Equal(BodyguardTaskDecision.NoChange, BodyguardTaskPolicy.EvaluateRemoval(expected, ValidSid, missing));
    }

    [Fact]
    public void Application_returns_stable_invalid_argument_exit_code_without_calling_context()
    {
        var operations = new RecordingSystemOperations();
        var resolver = new FakeIdentityResolver(InteractiveIdentityResult.Success(ValidSid, 1));
        var roots = new FakeInstallRootProvider(InstallRootResult.Success(Path.Combine(Path.GetTempPath(), "synthetic-root")));
        var context = new AdminContext(resolver, roots, operations);
        using var output = new StringWriter();

        var exitCode = AdminApplication.Run(new[] { "--operation", "run-script", "--user-sid", ValidSid }, context, output);

        Assert.Equal((int)AdminExitCode.InvalidArguments, exitCode);
        Assert.Equal(0, resolver.CallCount);
        Assert.Contains("operation", output.ToString(), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Application_maps_operation_exception_to_stable_failure_exit_code()
    {
        var operations = new RecordingSystemOperations { ThrowOnDns = true };
        var resolver = new FakeIdentityResolver(InteractiveIdentityResult.Success(ValidSid, 1));
        var roots = new FakeInstallRootProvider(InstallRootResult.Success(Path.Combine(Path.GetTempPath(), "synthetic-root")));
        var context = new AdminContext(resolver, roots, operations);
        using var output = new StringWriter();

        var exitCode = AdminApplication.Run(
            new[] { "--operation", "flush-dns", "--user-sid", ValidSid },
            context,
            output);

        Assert.Equal((int)AdminExitCode.OperationFailed, exitCode);
        Assert.Contains("failed", output.ToString(), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Admin_request_file_contains_no_process_launch_api()
    {
        var path = Path.Combine(RepositoryRoot(), "windows", "ClaudeSwitcher.Admin", "AdminRequest.cs");
        var text = File.ReadAllText(path);

        Assert.DoesNotContain("Process.Start", text, StringComparison.Ordinal);
        Assert.DoesNotContain("Invoke-Expression", text, StringComparison.Ordinal);
    }

    private const string ValidSid = "S-1-5-21-1004336348-1177238915-682003330-1001";
    private const string OtherSid = "S-1-5-21-1004336348-1177238915-682003330-1002";

    private static AdminRequest Request(
        AdminOperation operation,
        string sid,
        int? sessionId = null,
        string? timeZoneId = null)
    {
        var args = new List<string>
        {
            "--operation", OperationName(operation),
            "--user-sid", sid
        };
        if (sessionId.HasValue)
        {
            args.Add("--session-id");
            args.Add(sessionId.Value.ToString(System.Globalization.CultureInfo.InvariantCulture));
        }
        if (timeZoneId is not null)
        {
            args.Add("--time-zone-id");
            args.Add(timeZoneId);
        }

        Assert.True(AdminRequest.TryParse(args, out var request, out var error), error);
        return request!;
    }

    private static string OperationName(AdminOperation operation) => operation switch
    {
        AdminOperation.SetTimeZone => "set-time-zone",
        AdminOperation.DisableIpv6 => "disable-ipv6",
        AdminOperation.FlushDns => "flush-dns",
        AdminOperation.RegisterBodyguardTask => "register-bodyguard-task",
        AdminOperation.RemoveBodyguardTask => "remove-bodyguard-task",
        AdminOperation.RepairSystem => "repair-system",
        AdminOperation.MigrateLegacyBodyguard => "migrate-legacy-bodyguard",
        _ => throw new ArgumentOutOfRangeException(nameof(operation))
    };

    private static string LegacyScriptPath(string profileRoot) =>
        Path.Combine(profileRoot, ".claude-switcher", "claude-bodyguard.ps1");

    private static string LegacyArguments(string profileRoot) =>
        $"-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"{LegacyScriptPath(profileRoot)}\"";

    private static string LegacyTaskXml(
        string profileRoot,
        string? command = null,
        string? arguments = null,
        string? triggerUserId = null,
        string? principalSid = null)
    {
        var escapedSid = System.Security.SecurityElement.Escape(principalSid ?? ValidSid);
        var triggerUser = triggerUserId is null
            ? string.Empty
            : $"<UserId>{System.Security.SecurityElement.Escape(triggerUserId)}</UserId>";
        var escapedCommand = System.Security.SecurityElement.Escape(command ?? "powershell.exe");
        var escapedArguments = System.Security.SecurityElement.Escape(arguments ?? LegacyArguments(profileRoot));
        return $"""
            <?xml version="1.0" encoding="UTF-16"?>
            <Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
              <RegistrationInfo><Author>Legacy</Author></RegistrationInfo>
              <Triggers><LogonTrigger><Enabled>true</Enabled>{triggerUser}</LogonTrigger></Triggers>
              <Principals><Principal id="Author"><UserId>{escapedSid}</UserId><LogonType>Interactive</LogonType><RunLevel>Limited</RunLevel></Principal></Principals>
              <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><AllowStartOnDemand>true</AllowStartOnDemand><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Enabled>true</Enabled></Settings>
              <Actions Context="Author"><Exec><Command>{escapedCommand}</Command><Arguments>{escapedArguments}</Arguments></Exec></Actions>
            </Task>
            """;
    }
    private static string CanonicalSettingsXml() => """
      <Settings>
        <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
        <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
        <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
        <AllowStartOnDemand>true</AllowStartOnDemand>
        <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
        <Enabled>true</Enabled>
      </Settings>
    """;

    private static string CanonicalTaskXml(
        BodyguardTaskPaths paths,
        string sid,
        string settingsXml,
        string extraActionXml = "") => $"""
        <Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
          <Triggers><LogonTrigger><Enabled>true</Enabled><UserId>{sid}</UserId></LogonTrigger></Triggers>
          <Principals><Principal id="Author"><UserId>{sid}</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
          {settingsXml}
          <Actions Context="Author"><Exec><Command>{System.Security.SecurityElement.Escape(paths.PowerShellPath)}</Command><Arguments>{System.Security.SecurityElement.Escape(paths.ActionArguments)}</Arguments>{extraActionXml}</Exec></Actions>
        </Task>
        """;
    private static ExistingBodyguardTask ExistingTask(BodyguardTaskPaths paths, string sid, string taskName) => new(
        true,
        sid,
        paths.PowerShellPath,
        paths.ActionArguments,
        taskName,
        "InteractiveToken",
        "LeastPrivilege",
        "LogonTrigger",
        sid,
        true,
        true,
        "Author",
        "IgnoreNew",
        false,
        false,
        "PT0S");

    private static string RepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "global.json")))
        {
            directory = directory.Parent;
        }

        return directory?.FullName ?? throw new InvalidOperationException("Repository root not found.");
    }

    private sealed class FakeIdentityResolver(InteractiveIdentityResult result) : IInteractiveIdentityResolver
    {
        public int CallCount { get; private set; }
        public int? RequestedSessionId { get; private set; }

        public InteractiveIdentityResult Resolve(int? requestedSessionId)
        {
            CallCount++;
            RequestedSessionId = requestedSessionId;
            return result;
        }
    }

    private sealed class FakeInstallRootProvider(InstallRootResult result) : IInstallRootProvider
    {
        public int CallCount { get; private set; }

        public InstallRootResult Resolve(InteractiveIdentity identity)
        {
            CallCount++;
            return result;
        }
    }

    private sealed class RecordingFixedProcessRunner : IFixedProcessRunner
    {
        public List<FixedProcessCall> Calls { get; } = new();

        public FixedProcessResult Run(string filePath, IReadOnlyList<string> arguments, TimeSpan timeout)
        {
            Calls.Add(new FixedProcessCall(filePath, arguments.ToArray(), timeout));
            return new FixedProcessResult(0, string.Empty, string.Empty);
        }
    }

    private sealed class RecordingSystemOperations : ISystemOperations
    {
        public int CallCount { get; private set; }
        public int TimeZoneCalls { get; private set; }
        public int Ipv6Calls { get; private set; }
        public int DnsCalls { get; private set; }
        public int RegisterCalls { get; private set; }
        public int RemoveCalls { get; private set; }
        public int MigrateCalls { get; private set; }
        public string? LastMigratedTaskName { get; private set; }
        public bool ThrowOnDns { get; init; }
        public bool ThrowOnMigration { get; init; }
        public string Sequence => string.Join(",", sequence);
        private readonly List<string> sequence = new();

        public void SetTimeZone(string timeZoneId)
        {
            CallCount++;
            TimeZoneCalls++;
            sequence.Add("time-zone");
        }

        public void DisableIpv6()
        {
            CallCount++;
            Ipv6Calls++;
            sequence.Add("ipv6");
        }

        public void FlushDns()
        {
            CallCount++;
            DnsCalls++;
            sequence.Add("dns");
            if (ThrowOnDns)
            {
                throw new InvalidOperationException("synthetic failure");
            }
        }

        public void EnsureBodyguardTask(BodyguardTaskPaths paths, string userSid, int sessionId)
        {
            CallCount++;
            RegisterCalls++;
            sequence.Add("task");
        }

        public void RemoveBodyguardTask(BodyguardTaskPaths paths, string userSid)
        {
            CallCount++;
            RemoveCalls++;
            sequence.Add("remove");
        }

        public void MigrateLegacyBodyguardTask(BodyguardTaskPaths paths, string userSid, int sessionId)
        {
            CallCount++;
            MigrateCalls++;
            LastMigratedTaskName = paths.TaskName;
            sequence.Add("migrate-legacy-bodyguard");
            if (ThrowOnMigration)
            {
                throw new InvalidOperationException("synthetic migration failure");
            }
        }
    }
}
