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

- [x] Write failing isolated tests for a broker that acquires `operation.lock`, writes a validated context, renews the lease, and leaves the lock held until commit or rollback.
- [x] Run the isolated test runner and verify failures identify the missing broker functions.
- [x] Implement `Invoke-InstallerMaintenanceBroker`, `Invoke-MaintenanceSession`, internal `Invoke-NativeUpgradeFinalize`, and `Invoke-InstallerUserDataCleanup` with strict path, SID, reparse, timeout, and marker validation.
- [x] Add tests for lease renewal failure, recovery residue, unknown completion, default data preservation, explicit deletion, and reparse rejection.
- [x] Run both Windows PowerShell 5.1 and PowerShell 7 isolated tests.

### Task 2: Add upgrade-only user finalization

**Files:**
- Modify: `windows/install.ps1`
- Test: `windows/ClaudeSwitcher.Admin.Tests/UserSetupTests.ps1`

- [x] Write failing tests proving upgrade finalization updates only bundled user templates and `version.txt`.
- [x] Implement the internal `Invoke-NativeUpgradeFinalize -Operation` entry that requires the same broker process to own the active lock, lease, and prepared snapshot; it copies protected templates atomically, and leaves `config.json`, accounts, recovery material, and Claude data untouched.
- [x] Reject network access, region re-detection, system changes, and missing protected payload in this entry.
- [x] Run the focused user setup tests under both PowerShell hosts.

### Task 3: Extend the Inno installer lifecycle

**Files:**
- Modify: `windows/ClaudeSwitcher.iss`
- Modify: `scripts/package-windows.ps1`
- Test: `windows/ClaudeSwitcher.Admin.Tests/InstallerProtocolTests.ps1`
- Test: `windows/tests/ClaudeSwitch.Packaging.Tests.ps1`

- [x] Write failing static/protocol tests for existing-install preflight, maintenance broker signaling, upgrade rollback, default-preserving uninstall, optional data deletion, and new-install-only `-Initialize`.
- [x] Replace the unconditional existing-install/uninstall rejection with fixed-path and protected-payload preflight.
- [x] Add setup/uninstall lifecycle callbacks that start the broker, stop owned tasks, preserve rollback receipts, replace only protected payload, finalize task registration, and signal commit or rollback.
- [x] Add an uninstall choice that defaults to preserving user data and never uses `[UninstallDelete]` for user directories.
- [x] Stage `InstallerMaintenance.ps1` and validate the closed payload list.
- [x] Run packaging and installer protocol tests in Windows PowerShell 5.1 and PowerShell 7.

### Task 4: Extend Admin helper maintenance operations if required

**Files:**
- Modify: `windows/ClaudeSwitcher.Admin/AdminOperation.cs`
- Modify: `windows/ClaudeSwitcher.Admin/AdminRequest.cs`
- Modify: `windows/ClaudeSwitcher.Admin/AdminContext.cs`
- Modify: `windows/ClaudeSwitcher.Admin/SystemOperations.cs`
- Test: `windows/ClaudeSwitcher.Admin.Tests/AdminHelperTests.cs`

- [x] Reused the existing closed register/remove commands with exact SID/session matching; no new Admin operation was needed.
- [x] Kept register/remove ownership checks unchanged and bounded the stop wait before task deletion.
- [x] Test remove → replace → register and foreign-task refusal.
- [x] Run the complete Admin xUnit suite.

### Task 5: Verify, document, and publish the branch

**Files:**
- Modify: `windows/README.md`
- Modify: `README.md` only if the Windows installation boundary is duplicated there.
- Test: existing Windows PowerShell, .NET, Python, and packaging suites.

- [x] Document upgrade, repair, uninstall, data retention, and explicit deletion behavior.
- [x] Run fresh verification: App/Admin tests, PowerShell 5.1/7 core/setup/packaging tests, Python workflow tests, and clean publish checks.
- [x] Review `git diff --check`, staged diff, and branch status.
- [x] Commit the implementation and push the non-main branch.
- [ ] Confirm the final commit produces a successful GitHub Actions package artifact. Windows 10/11 VM acceptance remains external and unexecuted.

## Verification checkpoint (2026-10-29)

- Core: PowerShell 5.1 / 7 each 188/188. Packaging regressions: each 22/22.
- WPF: 199/199; Admin: 116/116. App/Admin self-contained directory publish succeeded.
- User setup: 34/34; installer protocol: 22/22; maintenance: 10/10; registry: 7/7; upgrade finalization: 13/13 on both PowerShell hosts. One file-symlink case logs SKIP locally when symbolic-link privilege is unavailable. Directory junction rejection is exercised.
- Windows Python tests: 69/69.
- Real Inno 6.7.3 compilation passes in hosted CI. Initial CI found a missing GetTickCount import, then a runner-role assumption in an isolated fixture; both have dedicated fixes. Final artifact confirmation is the remaining CI step.
- No installation, uninstallation, UAC, or Windows VM acceptance was performed on the maintainer machine. Interrupted transactions retain recovery material; uncertain recovery stays blocked.
