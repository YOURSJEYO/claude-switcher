# Official Release Reminder Implementation Plan

**Goal:** Add the approved macOS first-launch notice about free official releases and reporting suspected impersonation or AGPL violations, with manual access after acknowledgement.

**Architecture:** Keep acknowledgement in an injectable UserDefaults store. A dedicated OfficialReleaseNoticeView receives an explicit acknowledgement callback; appearing or closing never writes the seen flag. VM owns the notice selection and other sheet flags, allowing menu actions to avoid overlapping panels. The information menu retains access to the existing security bulletin.

**Constraints:** Only repository files change. No installation, account, proxy or system configuration changes. Windows and Linux application behavior stays outside this change. Preserve audit and window lifecycle behavior.

## 1. Define regression scenarios

- [x] Add acknowledgement coverage: first presentation stays unread; dismissal stays unread; a fresh VM retries; explicit acknowledgement persists into a fresh UserDefaults/VM instance; manual viewing remains available.
- [x] Cover startup and hidden-window reopening through AppDelegate without extra core calls.
- [x] Cover existing-sheet collisions and preserve access to the security bulletin.
- [x] Inject isolated preferences into all model fixtures; remove test suites on cleanup.
- [x] Keep narrow static copy checks for the free-release statement, AGPL charging boundary and reporting URL; failures must not print the full Swift file.

The static tests failed before implementation as expected. Swift behavioral tests require macOS and must not be described as passed on Windows.

## 2. Implement the reminder

- [x] Add OfficialReleaseReminder with the key `officialReleaseReminderSeen.v1`.
- [x] Use NoticePage and VM.activeNotice to select a dedicated free-release notice or the existing security bulletin.
- [x] Guard automatic presentation once per VM startup. Only acknowledgeOfficialReleaseNotice writes the preference.
- [x] Present asynchronously after the launch window is created and the normal audit starts. showMainWindow and applicationShouldHandleReopen do not trigger automatic presentation.
- [x] Add an information menu with both notices and a menu-bar item titled “官方版本免费与举报”.
- [x] Keep settings, update, fingerprint, prompt and notice sheets mutually exclusive for menu-based presentation.
- [x] Add concise copy stating official releases are free and compliant AGPL redistribution may charge. Link to the project Issues only on user click and request evidence without private buyer/account details.
- [x] Give the isolated UI demo a stable, separate preferences suite keyed by its fake-core path; allow resetting only this demo suite with --reset-notice.

The close icon and Escape leave the notice unread. “知道了” (including its standard Return keyboard action) acknowledges and dismisses it.

## 3. Documentation and validation

- [x] Update both READMEs with first-launch/upgrade behavior, explicit acknowledgement and manual access.
- [x] Document isolated UI acceptance for unread restart, acknowledged restart, hidden-window manual access, existing security content, Issue opening and sheet conflicts.
- [x] Run focused static tests and applicable repository checks; inspect the diff for encoding and unrelated changes. All 106 static checks pass in an isolated checkout using the repository's LF endings; two unrelated working-copy CRLF assertions fail locally. Swift scenarios are skipped on Windows.
- [x] Review the implementation and resolve actionable findings. Add actual attached-sheet assertions to the launch/manual lifecycle scenario; physical button interaction remains part of manual macOS acceptance.
- [ ] Verify the macOS model tests and strict Swift build on a macOS runner when available.
- [x] Record any remaining manual macOS UI acceptance limitation: this Windows host cannot perform macOS manual UI/VoiceOver acceptance. Follow tests/MENU-BAR-TESTING.md in the isolated demo.

## 4. Delivery

- [ ] Fetch origin/main, preserve concurrent work and commit the implementation with its tests and documentation.
- [ ] Push main, inspect the resulting checks and report their actual outcome. Do not publish a release or deploy locally.
