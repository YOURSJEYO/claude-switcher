# Windows Native EXE Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development. Use a fresh implementer and a separate spec/code reviewer for each task. Keep implementation in an isolated agent workspace; do not edit application code directly on `main`.

**Goal:** Deliver a safe Windows x64 native WPF application and installer while retaining the repaired PowerShell core as the only implementation of environment checks and account switching.

**Architecture:** First repair and test every core path that can launch Claude or mutate account snapshots. Then add a versioned JSON contract and a .NET 10 WPF client, separate per-user setup from fixed administrator operations, and package both through Inno Setup. Windows and macOS/Linux CI jobs build artifacts independently; one final job verifies all artifacts and publishes only after isolated Windows VM acceptance.

**Tech Stack:** Windows PowerShell 5.1, dependency-free isolated PowerShell tests, .NET 10 LTS, WPF, xUnit, Inno Setup, GitHub Actions, Windows 11 x64 acceptance VM, Windows 10 22H2 compatibility VM.

**Test-runner adaptation:** The developer environment has only Pester 3.4.0, not Pester 5. `windows/tests/Invoke-CoreTests.ps1` is the dependency-free isolated runner used on both PowerShell 7 and Windows PowerShell 5.1. All subsequent core/protocol/transaction suites use that same runner; add tag filtering before the first tagged suite. The behavioral assertions and isolation requirements below are unchanged.

## Global Constraints

- Design authority: `docs/superpowers/specs/2026-10-26-windows-native-exe-design.md` (V2).
- Target framework is `net10.0-windows`; only `win-x64` ships in the first native release.
- Publish `SelfContained=true`, `PublishSingleFile=false`; do not enable trimming or Native AOT.
- Keep Windows PowerShell scripts UTF-8 with BOM.
- Do not change the internal layout of `accounts/A` or `accounts/B`; no C# code may read or mutate account snapshot contents.
- Every route that starts Claude must pass a fresh core-owned launch gate. UI state and `last-check.txt` never authorize launch.
- STUN with no valid response is unverified and blocks launch. `robocopy` return codes 0–7 are success; 8+ are failure.
- Serialize per-user mutating operations across CLI, PowerShell UI, and native UI; recover or explicitly block after interrupted transactions.
- User-scoped initialization runs as the original user. The elevated helper accepts fixed operations and validated scalar settings only; it never executes caller-supplied code or paths.
- Normal app and Claude processes run without elevation. UAC cancellation and partial failure are observable and retryable.
- No installer, task registration, network setting, account data, or maintainer-installed application is touched on the developer machine. Installation and uninstall tests run only on disposable VMs.
- CI jobs build and upload artifacts; only a final dependency-gated job may publish a Release. Checksums cover the exact final assets.
- Keep tests isolated from real Claude sessions, credentials, proxy secrets, and real egress IPs.

---

## File Map

- `windows/tests/ClaudeSwitch.Core.Tests.ps1`: isolated core tests for launch gates, STUN unknown states, copy exit codes, locks, and recovery.
- `windows/claude-switch.ps1`: authoritative launch gate, operation lock, recoverable snapshot transaction, JSON protocol and legacy text output.
- `windows/SwitcherUI.ps1`: compatibility UI; consume strict core results and never present partial output or warnings as success.
- `windows/ClaudeSwitcher.App/`: WPF views, process client, protocol models, state presentation, and setup wizard.
- `windows/ClaudeSwitcher.App.Tests/`: xUnit tests for JSON validation, process invocation, timeout, redaction, and UI-facing state.
- `windows/ClaudeSwitcher.Admin/`: fixed-function elevated helper installed under Program Files; accepts a closed set of operations.
- `windows/install.ps1`: legacy interactive installer plus explicit noninteractive validation; scripts resolve from `$PSScriptRoot`.
- `windows/ClaudeSwitcher.iss`: per-machine program install, original-user launch, uninstall handling, shortcut and task ownership.
- `scripts/package-windows.ps1`: deterministic publish directory, versioned Setup EXE and compatibility script zip.
- `.github/workflows/checks.yml`: Windows core/C# tests and Windows build check.
- `.github/workflows/release.yml`: independent platform artifact jobs followed by one validation/publish job.
- `windows/README.md`, `README.md`, `README.en.md`, `.gitignore`, and `global.json`: support policy, build instructions, release scope, SDK pin and generated output exclusions.

## Task 1: Make the PowerShell Core Fail Closed Before Launch

**Files:**
- Create: `windows/tests/ClaudeSwitch.Core.Tests.ps1`
- Create: `windows/tests/Invoke-CoreTests.ps1`
- Modify: `windows/claude-switch.ps1`
- Modify: `windows/SwitcherUI.ps1` only if its launch button bypasses the core command contract

**Interfaces:**
- `Test-LaunchGate` returns a structured result with `CanLaunch`, `Checks`, and a stable blocking reason.
- `Invoke-Switch` accepts only `[ValidateSet('A','B')][string] $Target`.
- `Get-StunAssessment` returns `ok` only if at least one valid STUN response matches the freshly observed proxy egress; no response, malformed response, and probe errors return blocking `unknown`/`fail`.
- Existing text `checkdetail`, `status`, `fix`, and `switch A|B` remain supported.

- [ ] **Step 1: Add failing isolated core tests** for: same-account launch with a failed egress check; normal A-to-B launch with failed country check; empty, malformed and mismatched STUN results; rejection of invalid account targets; output that omits a required check. Inject/mock network, process launch, time-zone, task and file APIs. Use a temporary home and synthetic test addresses only.
- [ ] **Step 2: Run the new tests and verify the expected failures.**

Run: `pwsh -NoLogo -NoProfile -File windows/tests/Invoke-CoreTests.ps1`

Expected: failing assertions demonstrate current bypasses; no test contacts live services or starts Claude.

- [ ] **Step 3: Implement the smallest core-owned launch gate.** Both the same-account branch and the account-change branch must invoke the same fresh gate immediately before `Start-ClaudeApp`; return nonzero and never call the launcher on a blocking/unknown result. Do not trust cached check files. Reject invalid targets before stopping Claude or touching files.
- [ ] **Step 4: Correct STUN truth states.** Separate `no response` from verified `no leak`; validate response structure and only pass on an observed public address that matches the current egress. Keep internal addresses and test fixtures out of user-facing details.
- [ ] **Step 5: Run the focused core suite and the PowerShell parser.**

Run: `pwsh -NoLogo -NoProfile -File windows/tests/Invoke-CoreTests.ps1`

Expected: all focused tests pass; invalid conditions report `CanLaunch=false`.

- [ ] **Step 6: Review the diff and commit** as `fix(windows): gate Claude launches on fresh checks`.

## Task 2: Make Account Switching Recoverable and Serialized

**Files:**
- Modify: `windows/tests/ClaudeSwitch.Core.Tests.ps1`
- Modify: `windows/claude-switch.ps1`
- Modify: `windows/SwitcherUI.ps1` for actionable `recoveryRequired` handling

**Interfaces:**
- `Enter-OperationLock` / `Exit-OperationLock` use an exclusive per-user lock-file handle with a bounded wait; process exit releases the handle.
- `Invoke-AccountTransaction` returns `operationId`, `phase`, `current`, `success`, and `recoveryRequired`.
- `Recover-PendingTransaction` either restores a verified prior state or refuses further mutation without deleting recovery data.

- [ ] **Step 1: Add failing tests** for robocopy exit codes 0, 7, 8 and 16; failed archive; failed account load; interruption before and after commit; stale transaction; and two competing processes attempting the same user lock. Every test uses synthetic directories and injected copy/kill hooks.
- [ ] **Step 2: Run focused tests and verify failures match the data-loss cases.**

Run: `pwsh -NoLogo -NoProfile -File windows/tests/Invoke-CoreTests.ps1 -Tag Transaction`

Expected: failures show the current implementation accepts exit 8+, advances account state after incomplete copies, and has no recovery lock.

- [ ] **Step 3: Check every robocopy exit code immediately.** Treat only 0–7 as successful. Do not update `current.txt`, delete a complete source, launch Claude, or log success after an 8+ return. Verify a copied tree before promoting it.
- [ ] **Step 4: Implement staged same-volume recovery.** Write an atomic transaction record outside `accounts/A` and `accounts/B`; stage copies beside their destination; retain the last verified source until target validation; atomically commit the active account marker; recover or set `recoveryRequired` after interruption. Never overwrite `.new`/`.previous` data before verifying its contents.
- [ ] **Step 5: Add the shared operation lock** around core mutations and check-detail writes. Use `try/finally` to close the handle. A second process returns a stable busy status instead of racing. Internal gate calls must not reacquire the lock.
- [ ] **Step 6: Test every transaction failure injection and rerun all PowerShell tests.**

Run: `pwsh -NoLogo -NoProfile -File windows/tests/Invoke-CoreTests.ps1`

Expected: 0 failures; at every injected failure at least one validated copy remains and the current marker matches the recoverable state.

- [ ] **Step 7: Commit** as `fix(windows): make account switching recoverable`.

## Task 3: Define a Strict Core Protocol and Preserve the Script UI

**Files:**
- Modify: `windows/tests/ClaudeSwitch.Core.Tests.ps1`
- Modify: `windows/claude-switch.ps1`
- Modify: `windows/SwitcherUI.ps1`

**Interfaces:**
- Core entry form: `claude-switch.ps1 <command> -Json -OperationId <guid>` for the native client; text mode stays available.
- JSON result fields: `schemaVersion`, `operationId`, `command`, `success`, `code`, `message`; `checkdetail` also returns 14 `checks` and `canLaunch`; `switch` returns `current`, `phase`, `recoveryRequired`.
- Stable check IDs, in display order: `proxy_engine`, `tun_interface`, `egress_country`, `ip_consistency`, `timezone`, `locale`, `ipv6`, `dns`, `webrtc`, `bodyguard`, `routing_rules`, `client_language`, `asn`, `ecosystem`. Preserve current Chinese labels in a separate `name` field.

- [ ] **Step 1: Add failing tests** for complete schema, all 14 unique IDs, operation ID echo, warning allowlist (`ip_consistency`, `asn` only), unknown status, duplicate/unknown IDs, malformed JSON, nonzero failure exit, protocol/text compatibility and redacted detail.
- [ ] **Step 2: Run the protocol tests and verify they fail against the current text-only output.**

Run: `pwsh -NoLogo -NoProfile -File windows/tests/Invoke-CoreTests.ps1 -Tag Protocol`

Expected: protocol contract assertions fail; text commands remain unaffected.

- [ ] **Step 3: Emit one JSON object on stdout** for native mode. Put diagnostic output on stderr or a protected redacted log. Propagate native exit codes; normalize robocopy codes inside transaction code only.
- [ ] **Step 4: Update `SwitcherUI.ps1`** so it treats missing/duplicate/unknown output and warnings as non-green, checks `switch` results rather than merely absence of `FAIL:`, and refuses launch unless the core confirms the gate. Keep UTF-8 BOM.
- [ ] **Step 5: Run protocol plus legacy behavior tests.**

Run: `pwsh -NoLogo -NoProfile -File windows/tests/Invoke-CoreTests.ps1`

Expected: JSON mode returns exactly one valid object; text `checkdetail` remains 14 parseable rows; unknown/warn outcomes never show green.

- [ ] **Step 6: Commit** as `feat(windows): add versioned core result protocol`.

## Task 4: Build the .NET 10 WPF Client

**Files:**
- Create: `global.json`
- Create: `windows/ClaudeSwitcher.App/ClaudeSwitcher.App.csproj`
- Create: `windows/ClaudeSwitcher.App/App.xaml` and `App.xaml.cs`
- Create: `windows/ClaudeSwitcher.App/MainWindow.xaml` and `MainWindow.xaml.cs`
- Create: `windows/ClaudeSwitcher.App/Models/CoreResult.cs` and `CheckResult.cs`
- Create: `windows/ClaudeSwitcher.App/Services/CoreClient.cs` and `CoreResultParser.cs`
- Create: `windows/ClaudeSwitcher.App.Tests/ClaudeSwitcher.App.Tests.csproj` and parser/client test files
- Modify: `.gitignore` for .NET build output

**Interfaces:**
- `CoreClient.RunAsync(CoreCommand command, string? target, Guid operationId, CancellationToken cancellationToken)` starts only the installed PowerShell core and returns a typed `CoreResult`.
- `CoreResultParser.Parse(string stdout, int exitCode, CoreCommand expectedCommand, Guid expectedOperationId)` rejects invalid/incomplete responses.
- UI states are `Checking`, `Ready`, `Blocked`, `Running`, `RecoveryRequired`, and `SetupRequired`; only a core result with valid `canLaunch=true` enables launch.

- [ ] **Step 1: Create parser tests first** for valid result; each failure, warning, missing/duplicate/unknown checks, schema mismatch, command/operation mismatch, empty stdout and nonzero exit. Create the .NET solution/project files without app behavior.
- [ ] **Step 2: Run `dotnet test windows/ClaudeSwitcher.App.Tests`** and confirm tests fail because `CoreResultParser` is not implemented.
- [ ] **Step 3: Implement immutable protocol records and a strict parser** matching Task 3 fields and warning allowlist. A mismatch always returns blocked state.
- [ ] **Step 4: Add process tests** for A/B allowlisting, ArgumentList contents, no `cmd.exe`, missing core, UTF-8 Chinese output, bounded stdout/stderr, exit code and operation-specific timeout/cancellation. Tests use a temporary fake PowerShell executable/core; never invoke the installed core.
- [ ] **Step 5: Implement `CoreClient`** with explicit PowerShell 5.1 path lookup, `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File`, `ArgumentList`, redirected async streams, size limits, timeout rules and result redaction. Query timeout may terminate only that query; switch timeout stays attached to operation status and does not kill a committing process.
- [ ] **Step 6: Implement WPF UI** with the existing 14-row information hierarchy, current account, A/B controls, refresh, repair, first-run setup state and recovery message. Disable conflicting actions while busy; closing the window never terminates Claude or a committing core transaction.
- [ ] **Step 7: Run tests and publish a self-contained directory.**

Run: `dotnet test windows/ClaudeSwitcher.App.Tests`

Run: `dotnet publish windows/ClaudeSwitcher.App -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false`

Expected: tests pass; publish output contains the WPF apphost and runtime files and starts on a Windows x64 test host without system .NET.

- [ ] **Step 8: Commit** as `feat(windows): add native WPF client`.

## Task 5: Separate Per-User Setup from Elevated System Operations

**Files:**
- Modify: `windows/install.ps1`
- Create: `windows/ClaudeSwitcher.Admin/ClaudeSwitcher.Admin.csproj` plus its request validation and fixed operations
- Create: `windows/helpers/` only for immutable templates/assets needed by the installer
- Create: `windows/ClaudeSwitcher.iss`
- Modify: `windows/tests/ClaudeSwitch.Core.Tests.ps1` for noninteractive configuration validation
- Add admin-helper unit tests alongside the helper project

**Interfaces:**
- Install script accepts `-NonInteractive`, validated `-ProxyMode`, and `-ProxyGroup`; missing information fails before writes. Its source is derived from `$PSScriptRoot`.
- User configuration is versioned JSON under that user's `.claude-switcher` directory and stores proxy mode/group plus validated country/time-zone/culture targets. Do not execute old scripts to migrate settings.
- Admin helper accepts only a closed enum of system operations and validated scalar settings; it derives user identity and paths itself.

- [ ] **Step 1: Add failing tests** for noninteractive no-prompt behavior, proxy detection failure, missing/invalid group, CN or unknown country, unknown time zone, culture target mapping, invalid helper operation, mismatched user SID, UAC cancel and repeated idempotent setup. Tests must not call Windows system-setting cmdlets.
- [ ] **Step 2: Run isolated installer/helper tests** and verify current `Read-Host`, fallback and admin-context assumptions fail those tests.
- [ ] **Step 3: Refactor install stages** into pure validation, original-user setup and system configuration. A missing or unsupported region target exits before changing files or settings; delete environment-variable FORCE fallback from the native flow. Keep direct legacy install as an explicit interactive entry.
- [ ] **Step 4: Implement the elevated helper** with fixed operations for time zone, IPv6, DNS-cache flush, and this product's owned scheduled-task registration/removal. Validate interactive user SID and session; reject arbitrary command/path arguments. Task runs as that user, not SYSTEM or another administrator.
- [ ] **Step 5: Implement Inno Setup** to install protected program files, invoke first-run initialization as the original user when supported, and show a normal-user relaunch instruction when identity is ambiguous. Keep UAC cancellation and partial stage result visible. Never auto-launch Claude.
- [ ] **Step 6: Implement uninstall and upgrade rules**: remove only the scheduled task owned by this product/version after confirming SID/action path; preserve account and recovery data by default; restore backed-up settings only by explicit user request and only if the current value is still the product-written value. Block setup/uninstall during a core transaction.
- [ ] **Step 7: Run isolated tests, PowerShell parser, helper tests and Inno Setup compile check.** Installation/uninstall execution remains reserved for disposable VMs.
- [ ] **Step 8: Commit** as `feat(windows): add user-safe native installer`.

## Task 6: Automate Windows Build and Aggregate Cross-Platform Releases

**Files:**
- Create: `scripts/package-windows.ps1`
- Modify: `.github/workflows/checks.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `.gitignore`
- Modify: `windows/README.md`, `README.md`, and `README.en.md`

**Interfaces:**
- Package script: `scripts/package-windows.ps1 -Version <safe-version> -OutputDirectory <path>`. It runs tests, publishes, stages a closed file list, compiles setup, creates the script fallback zip, and writes a manifest.
- CI artifact names include platform, architecture and workflow run identity; only the aggregate job can publish.

- [ ] **Step 1: Add packaging contract tests** using a temporary output root: unsafe version rejected, missing tool fails, missing expected file fails, no `bin/obj` or user data enters archives, setup/zip names and manifest agree.
- [ ] **Step 2: Run tests to verify missing packaging script and manifest fail.**
- [ ] **Step 3: Implement the Windows packager** using fixed tool discovery, `dotnet test`, `dotnet publish` and Inno Setup compile. Produce `ClaudeSwitcher-<version>-windows-setup.exe` and `ClaudeSwitcher-<version>-windows.zip`.
- [ ] **Step 4: Add Windows CI checks** for PowerShell core tests, xUnit, PowerShell parse checks, packaging and archive manifest. Keep separate build permissions read-only.
- [ ] **Step 5: Refactor release workflow** into macOS/Linux build and Windows build artifact jobs; one downstream job downloads all assets, validates versions/manifests, computes release SHA256, creates a draft, verifies assets, then publishes. Any missing artifact blocks publication.
- [ ] **Step 6: Document Windows x64 runtime, installation/UAC behavior, unsigned SmartScreen status, fallback ZIP distinction, build/test commands, support matrix and upgrade/uninstall data retention.**
- [ ] **Step 7: Run workflow syntax checks and local package tests; inspect each archive manifest.**
- [ ] **Step 8: Commit** as `ci(windows): build and release native installer`.

## Task 7: Disposable VM Acceptance and Final Review

**Files:**
- Create: `windows/tests/vm-smoke/` scripts and a machine-readable acceptance report schema
- Modify: release workflow to require a successful signed VM-smoke report before final publishing
- Modify: documentation only for observed and passed compatibility results

**Interfaces:**
- VM report records OS build, installer version/hash, scenario ID, result, and redacted diagnostics; it contains no real account files or egress address.
- Release job accepts only a report bound to the same commit and exact installer SHA256.

- [ ] **Step 1: Add acceptance scenarios** for no-.NET Windows 11 install, Windows 10 22H2 compatibility, standard-user install, alternate administrator UAC credentials, elevated-terminal identity handling, setup/upgrade/uninstall, cancellation, partial system-helper failure, interrupted copy recovery, and concurrent entry points.
- [ ] **Step 2: Run the scenario suite on disposable VMs with fake proxy services and synthetic account trees.** Never sign into Claude or use residential egress in synthetic tests.
- [ ] **Step 3: Fix failures in the owning earlier task and re-run its unit suite plus the affected VM scenario.**
- [ ] **Step 4: Verify packaged files, task ACL/identity, normal-user Claude launch, preserved account data after uninstall, final SHA256 and draft release asset inventory.**
- [ ] **Step 5: Dispatch a high-capability whole-change reviewer against the complete branch diff and all recorded minor concerns. Fix critical/important findings and re-run their covering tests.**
- [ ] **Step 6: Record which VM scenarios were actually executed. Do not mark Windows 10 or installer behavior supported if the corresponding VM was unavailable.**

## Task Dependencies

Integration order is `Task 1 → Task 2 → Task 3 → Task 4 → Task 5 → Task 6 → Task 7`. Shared PowerShell-core changes remain sequential and require review before the next core task. Task 4's new C# files may be implemented against isolated protocol fixtures in parallel, with a disjoint write scope; they cannot be declared integrated or releasable until Tasks 1–3 pass. Only one agent at a time may edit a given file, and commits are coordinated by the controller.

## Plan Self-Review

- Core fail-closed behavior and STUN unknown state: Task 1.
- Snapshot recovery, `robocopy`, same-user serialization: Task 2.
- Versioned output and compatibility UI: Task 3.
- .NET 10 process boundary, parser, UI, timeout/redaction tests: Task 4.
- Original-user vs admin identity, configuration, helper, install/upgrade/uninstall: Task 5.
- Packaging, checks workflow, single release publisher, docs: Task 6.
- Actual Windows 10/11 installation and operation evidence: Task 7.
- Placeholder scan: no TODO/TBD steps; each task has exact file scope, test command, expected outcome and commit title.
- All commands use isolated fixtures locally; privileged install and uninstall are only VM steps.
