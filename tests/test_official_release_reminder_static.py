"""Static contract checks for the macOS official release reminder."""

from pathlib import Path
import unittest


PROJECT = Path(__file__).resolve().parents[1]
MAIN_SWIFT = (PROJECT / "app/main.swift").read_text(encoding="utf-8")


class OfficialReleaseReminderStaticTests(unittest.TestCase):
    def assert_source_contains(self, text):
        self.assertTrue(text in MAIN_SWIFT, f"Missing reminder text: {text}")

    def test_reminder_uses_a_persistent_seen_key_and_manual_issue_entry(self):
        self.assert_source_contains('officialReleaseReminderSeen.v1')
        self.assert_source_contains('官方版本免费与举报')
        self.assert_source_contains('https://github.com/YOURSJEYO/claude-switcher/issues')

    def test_reminder_copy_preserves_agpl_commercial_boundary(self):
        self.assert_source_contains('官方版本免费提供')
        self.assert_source_contains('AGPL-3.0-only')
        self.assert_source_contains('收费不自动等于违规')


if __name__ == "__main__":
    unittest.main()
