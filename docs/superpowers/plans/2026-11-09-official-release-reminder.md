# Official Release Reminder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a one-time macOS startup reminder that the official release is free, provide a persistent manual entry from the menu bar, and direct suspected official impersonation or AGPL violations to the project Issues page.

**Architecture:** Keep the reminder state in a small `OfficialReleaseReminder` helper backed by injectable `UserDefaults`. Bind the existing announcement sheet to `VM`, trigger it after the first main window is created, and add a menu item that reopens the same sheet. Extend the existing security announcement with the licensing and reporting copy so there is one source of user-facing text.

**Tech Stack:** Swift 5.7+, SwiftUI, AppKit, Foundation `UserDefaults`, existing macOS model test executable.

## Global Constraints

- The official release reminder appears automatically only once per user profile.
- Manual viewing from the main window and menu bar remains available after the reminder is acknowledged.
- The copy must state that the official version is free while preserving the AGPL boundary that compliant redistribution may charge a fee.
- The Issue URL is `https://github.com/YOURSJEYO/claude-switcher/issues`.
- Do not change installation state, account data, system settings, core scripts, daemons, or update behavior.
- Keep existing menu bar lifecycle behavior: closing the window hides it and reopening reuses the same window.
- Run tests before claiming completion; macOS Swift UI compilation cannot be claimed from this Windows host unless a macOS runner is available.

---

### Task 1: Add failing reminder state tests

**Files:**
- Modify: `tests/MenuBarModelTests.swift` near the existing `startup_once` and `window_lifecycle` scenarios.
- Test target: the existing `MenuBarModelTests` executable.

**Interfaces:**
- Consumes: the planned `OfficialReleaseReminder.shouldShow(in:)` and `OfficialReleaseReminder.markSeen(in:)` methods.
- Produces: a regression scenario named `official_release_notice_once` that proves isolated preferences start unseen, become seen after acknowledgement, and stay seen on later checks.

- [ ] **Step 1: Add the failing test scenario before production code changes**

Add this switch case before the `default` case in `MenuBarModelTests.main()`:

```swift
case "official_release_notice_once":
    let suiteName = "menu-bar-official-release-(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        throw TestFailure(description: "无法创建隔离偏好存储")
    }
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try expect(OfficialReleaseReminder.shouldShow(in: defaults), "首次启动应显示官方版本提醒")
    OfficialReleaseReminder.markSeen(in: defaults)
    try expect(!OfficialReleaseReminder.shouldShow(in: defaults), "确认提醒后不应再次自动显示")
    try expect(!OfficialReleaseReminder.shouldShow(in: defaults), "已读状态应在后续启动中保持")
```

- [ ] **Step 2: Run the scenario and verify the expected red failure**

Run on macOS from the repository root using the existing Swift test build command documented by the project, passing `official_release_notice_once` to the test executable. Expected result: compilation fails because `OfficialReleaseReminder` does not exist yet. On this Windows host, record the equivalent limitation if Swift is unavailable and continue with the source-level test-first change.

- [ ] **Step 3: Commit the red test separately**

```bash
git add tests/MenuBarModelTests.swift
git commit -m "test: define official release reminder behavior"
```

---

### Task 2: Implement one-time reminder state and UI entry points

**Files:**
- Modify: `app/main.swift` in the model declarations, `VM`, `ContentView`, `NoticeView`, `AppDelegate`, and `MenuBarContent`.
- Test: `tests/MenuBarModelTests.swift` from Task 1.

**Interfaces:**
- `OfficialReleaseReminder.seenKey: String` is the single preference key.
- `OfficialReleaseReminder.shouldShow(in defaults: UserDefaults = .standard) -> Bool` returns whether the automatic reminder is still pending.
- `OfficialReleaseReminder.markSeen(in defaults: UserDefaults = .standard)` persists the acknowledged state.
- `VM.showNotice: Bool` controls the existing announcement sheet.
- `VM.prepareOfficialReleaseNotice()` sets `showNotice` only when the reminder has not been acknowledged.
- `VM.markOfficialReleaseNoticeSeen()` persists acknowledgement through the helper.

- [ ] **Step 1: Add the minimal `OfficialReleaseReminder` helper**

Place it near the existing model declarations in `app/main.swift`:

```swift
enum OfficialReleaseReminder {
    static let seenKey = "officialReleaseReminderSeen.v1"

    static func shouldShow(in defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: seenKey)
    }

    static func markSeen(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: seenKey)
    }
}
```

- [ ] **Step 2: Run the reminder test and verify it passes**

Run the same isolated `official_release_notice_once` scenario. Expected result: PASS.

- [ ] **Step 3: Add VM-owned sheet state and preference injection**

Add to `VM`:

```swift
@Published var showNotice = false
private let noticeDefaults: UserDefaults
```

Extend `VM.init(core:checkTimeout:operationTimeout:)` so it accepts `noticeDefaults: UserDefaults = .standard` and stores it. Leave `AppDelegate.init(vm:)` unchanged because it receives a fully initialized VM from tests. Add:

```swift
func prepareOfficialReleaseNotice() {
    showNotice = OfficialReleaseReminder.shouldShow(in: noticeDefaults)
}

func markOfficialReleaseNoticeSeen() {
    OfficialReleaseReminder.markSeen(in: noticeDefaults)
}
```

Keep `showNotice` independent from environment audit state so the reminder cannot block checks or account operations.

- [ ] **Step 4: Bind the existing announcement sheet to VM state**

In `ContentView`, remove the local `@State private var showNotice = false` and attach the existing sheet to `$vm.showNotice`:

```swift
.sheet(isPresented: $vm.showNotice) {
    NoticeView()
        .onAppear { vm.markOfficialReleaseNoticeSeen() }
}
```

Change the existing information button action to set `vm.showNotice = true`, preserving the current security announcement access.

- [ ] **Step 5: Add the free-release and reporting panel to `NoticeView`**

Keep the current security sections and prepend a visually distinct card containing the following user-facing points:

- `官方版本免费提供`
- `维护者不会出售官方安装包或账号服务`
- `不得冒充官方、维护者或授权渠道销售“官方 Claude 切换器”`
- `删除许可证、隐瞒修改、不给对应源码或施加冲突限制属于举报范围`
- `AGPL-3.0-only 允许履行义务的再分发收费，单纯收费不自动等于违规`

Add a button that opens `https://github.com/YOURSJEYO/claude-switcher/issues` with `NSWorkspace.shared.open`, and show the instruction to attach a listing URL, screenshots, and version details without exposing personal information, order details, or credentials. Update the sheet title to `官方公告与安全防护` and its English subtitle accordingly.

- [ ] **Step 6: Trigger the automatic reminder after first launch**

In `AppDelegate.applicationDidFinishLaunching`, preserve the order that creates and shows the main window and starts the VM, then call:

```swift
vm.prepareOfficialReleaseNotice()
```

The existing `showMainWindow()` and `applicationShouldHandleReopen` paths must not call this method, so closing and reopening the hidden window does not repeat the automatic reminder.

- [ ] **Step 7: Add the manual menu item**

In `MenuBarContent`, add a button before the existing update/settings actions:

```swift
Button("官方版本免费与举报") {
    showWindow()
    vm.showNotice = true
}
```

The item must work whether the window is hidden or visible and must not start a new environment audit.

- [ ] **Step 8: Run the focused test and existing static checks**

Run the isolated reminder scenario and the existing Python test suite. Expected result: the reminder state scenario passes, existing tests remain green, and `git diff --check` reports no whitespace errors.

- [ ] **Step 9: Commit the implementation**

```bash
git add app/main.swift tests/MenuBarModelTests.swift
git commit -m "feat: add one-time official release reminder"
```

---

### Task 3: Update isolated UI verification and validate the complete change

**Files:**
- Modify: `tests/MENU-BAR-TESTING.md` in the manual acceptance list.
- Test: `tests/MenuBarModelTests.swift`, all existing Python tests.

**Interfaces:**
- Consumes: the final `VM.showNotice` binding and `MenuBarContent` menu item from Task 2.
- Produces: repeatable manual acceptance instructions for the one-time reminder and manual menu entry.

- [ ] **Step 1: Add manual UI acceptance steps**

Add these checks to `tests/MENU-BAR-TESTING.md`:

1. Start with a fresh `UserDefaults` profile: the official release reminder appears once after the main window opens.
2. Close the reminder: restarting the same profile does not show it automatically again.
3. Open the menu bar item `官方版本免费与举报`: the same announcement opens again.
4. Click the Issue button: the project Issues page opens; closing the browser or failing to open the URL does not affect the App.
5. Confirm the existing security announcement sections and account controls still work.

- [ ] **Step 2: Run repository tests**

```bash
python3 -m unittest discover -s tests -v
```

Expected: all runnable tests pass; macOS-only Swift UI tests may be skipped on Windows.

- [ ] **Step 3: Perform source and diff validation**

```bash
rg -n "OfficialReleaseReminder|官方版本免费与举报|Free Official Release and Reports|YOURSJEYO/claude-switcher/issues" app/main.swift tests/MenuBarModelTests.swift tests/MENU-BAR-TESTING.md
git diff --check
git status --short --branch
```

Expected: the helper, automatic reminder, menu item, Issue URL, and manual acceptance steps are present; only intended files are modified.

- [ ] **Step 4: Commit the implementation and verification documentation**

```bash
git add app/main.swift tests/MenuBarModelTests.swift tests/MENU-BAR-TESTING.md
git commit -m "feat: show official release reminder on first launch"
```

- [ ] **Step 5: Synchronize with `origin/main` and push**

```bash
git fetch origin main
git rebase origin/main
git push origin main
```

If the remote advances before push, stash only the uncommitted task files, rebase onto the updated `origin/main`, restore the stash, rerun validation, and then push.
