# Windows Upgrade and Uninstall Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven development or executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Enable safe in-place upgrade, repair install, and default data-preserving uninstall for the Windows native installer.

**Architecture:** Inno Setup orchestrates protected Program Files replacement while a user-context maintenance broker holds the existing operation lock and lease across the mutation. The protected Admin helper remains the only task registration/removal boundary. User data deletion is an explicit post-uninstall action performed in the user context.

**Tech Stack:** Inno Setup Pascal Script 6.7.3, Windows PowerShell 5.1, PowerShell test harness, .NET 10 WPF/Admin tests.

## Global Constraints

- Preserve `%USERPROFILE%\\.claude-switcher` and `%APPDATA%\\Claude` by default.
- Never run a user-writable ZIP script elevated.
- Do not weaken `BodyguardTaskPolicy`, `LegacyBodyguardTaskPolicy`, ACL, SID, session, lease, or JSON protocol validation.
- Upgrade and uninstall must fail closed on active transactions, recovery residue, ambiguous task ownership, cross-user identity, or uncertain rollback.
- Changes under `core/`, `daemons/`, or `installer/` require `scripts/gen-sums.sh`; Windows-only changes do not.

---

### Task 1: Add maintenance broker primitives

**Files:**
- Create: `windows/helpers/InstallerMaintenance.ps1`
- Modify: `windows/helpers/UserSetup.ps1`
- Test: `windows/ClaudeSwitcher.Admin.Tests/InstallerMaintenanceTests.ps1`

- [ ] Write failing isolated tests for a broker that acquires `operation.lock`, writes a validated context, renews the lease, and leaves the lock held until commit or rollback.
- [ ] Run the isolated test runner and verify failures identify the missing broker functions.
- [ ] Implement `Invoke-InstallerMaintenanceBroker`, `Test-InstallerMaintenanceContext`, `Invoke-InstallerUpgradeFinalize`, and `Invoke-InstallerUserDataCleanup` with strict path, SID, reparse, timeout, and marker validation.
- [ ] Add tests for lease renewal failure, recovery residue, unknown completion, default data preservation, explicit deletion, and reparse rejection.
- [ ] Run both Windows PowerShell 5.1 and PowerShell 7 isolated tests.

### Task 2: Add upgrade-only user finalization

**Files:**
- Modify: `windows/install.ps1`
- Test: `windows/ClaudeSwitcher.Admin.Tests/UserSetupTests.ps1`

- [ ] Write failing tests proving upgrade finalization updates only bundled user templates and `version.txt`.
- [ ] Implement an explicit `-FinalizeUpgrade` entry that requires a valid maintenance context, copies protected templates atomically, and leaves `config.json`, accounts, recovery material, and Claude data untouched.
- [ ] Reject network access, region re-detection, system changes, and missing protected payload in this entry.
- [ ] Run the focused user setup tests under both PowerShell hosts.

### Task 3: Extend the Inno installer lifecycle

**Files:**
- Modify: `windows/ClaudeSwitcher.iss`
- Modify: `scripts/package-windows.ps1`
- Test: `windows/ClaudeSwitcher.Admin.Tests/InstallerProtocolTests.ps1`
- Test: `windows/tests/ClaudeSwitch.Packaging.Tests.ps1`

- [ ] Write failing static/protocol tests for existing-install preflight, maintenance broker signaling, upgrade rollback, default-preserving uninstall, optional data deletion, and new-install-only `-Initialize`.
- [ ] Replace the unconditional existing-install/uninstall rejection with fixed-path and protected-payload preflight.
- [ ] Add setup/uninstall lifecycle callbacks that start the broker, stop owned tasks, preserve rollback receipts, replace only protected payload, finalize task registration, and signal commit or rollback.
- [ ] Add an uninstall choice that defaults to preserving user data and never uses `[UninstallDelete]` for user directories.
- [ ] Stage `InstallerMaintenance.ps1` and validate the closed payload list.
- [ ] Run packaging and installer protocol tests in Windows PowerShell 5.1 and PowerShell 7.

### Task 4: Extend Admin helper maintenance operations if required

**Files:**
- Modify: `windows/ClaudeSwitcher.Admin/AdminOperation.cs`
- Modify: `windows/ClaudeSwitcher.Admin/AdminRequest.cs`
- Modify: `windows/ClaudeSwitcher.Admin/AdminContext.cs`
- Modify: `windows/ClaudeSwitcher.Admin/SystemOperations.cs`
- Test: `windows/ClaudeSwitcher.Admin.Tests/AdminHelperTests.cs`

- [ ] Write failing tests for any required hold/commit task lifecycle command with exact SID/session matching.
- [ ] Add only the minimum maintenance operation needed by Inno/broker; keep existing register/remove ownership checks unchanged.
- [ ] Test remove → replace → register and foreign-task refusal.
- [ ] Run the complete Admin xUnit suite.

### Task 5: Verify, document, and publish the branch

**Files:**
- Modify: `windows/README.md`
- Modify: `README.md` only if the Windows installation boundary is duplicated there.
- Test: existing Windows PowerShell, .NET, Python, and packaging suites.

- [ ] Document upgrade, repair, uninstall, data retention, and explicit deletion behavior.
- [ ] Run fresh verification: App/Admin tests, PowerShell 5.1/7 core/setup/packaging tests, Python workflow tests, and clean publish checks.
- [ ] Review `git diff --check`, staged diff, and branch status.
- [ ] Commit the implementation and push the non-main branch.
- [ ] Confirm GitHub Actions run status and report that VM acceptance remains separate until actually executed.
