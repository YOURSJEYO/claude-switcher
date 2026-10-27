from __future__ import annotations

import copy
import hashlib
import hmac
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VERIFIER = ROOT / "scripts" / "verify-windows-vm-report.py"
SIGNER = ROOT / "windows" / "tests" / "vm-smoke" / "sign-report.py"
MATRIX_PATH = ROOT / "windows" / "tests" / "vm-smoke" / "acceptance-scenarios.json"
SCHEMA_PATH = ROOT / "windows" / "tests" / "vm-smoke" / "report-schema.json"

MATRIX = json.loads(MATRIX_PATH.read_text(encoding="utf-8"))
SCHEMA = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
COMMIT = "a" * 40
VERSION = "1.2.3"
INSTALLER_BYTES = b"synthetic installer fixture; never executed"
KEY = b"k" * 48
KEY_PROTECTION = "external-secret-store; WINDOWS_VM_REPORT_HMAC_KEY >= 32 UTF-8 bytes"
ENVIRONMENT_IDS = [item["id"] for item in MATRIX["requiredEnvironments"]]
SCENARIO_IDS = [item["id"] for item in MATRIX["scenarios"]]
SCENARIO_BY_ID = {item["id"]: item for item in MATRIX["scenarios"]}
ENVIRONMENT_BY_ID = {item["id"]: item for item in MATRIX["requiredEnvironments"]}


def installer_name(version: str = VERSION) -> str:
    return MATRIX["installerNameTemplate"].format(version=version)


def valid_report() -> dict:
    installer_sha256 = hashlib.sha256(INSTALLER_BYTES).hexdigest().upper()
    environments = []
    for env_spec in MATRIX["requiredEnvironments"]:
        env_id = env_spec["id"]
        if env_id == "windows-11-x64-clean":
            os_record = {
                "family": "windows-11",
                "version": "24H2",
                "build": "26100.2314",
                "architecture": "x64",
                "dotnetRuntimeInstalled": False,
            }
        else:
            os_record = {
                "family": "windows-10",
                "version": "22H2",
                "build": "19045.4894",
                "architecture": "x64",
                "dotnetRuntimeInstalled": False,
            }

        scenarios = []
        for index, scenario_id in enumerate(env_spec["scenarioIds"]):
            required_kinds = SCENARIO_BY_ID[scenario_id]["requiredDiagnosticKinds"]
            scenarios.append(
                {
                    "id": scenario_id,
                    "result": "passed",
                    "startedAt": f"2026-10-27T00:00:{index:02d}Z",
                    "finishedAt": f"2026-10-27T00:01:{index:02d}Z",
                    "diagnostics": [
                        {
                            "kind": kind,
                            "summary": "Synthetic acceptance check recorded.",
                        }
                        for kind in required_kinds
                    ],
                    "executed": True,
                }
            )

        environments.append(
            {
                "id": env_id,
                "os": os_record,
                "executed": True,
                "scenarios": scenarios,
            }
        )

    return {
        "schemaVersion": 1,
        "product": "ClaudeSwitcher",
        "reportType": "windows-vm-acceptance",
        "sourceCommit": COMMIT,
        "version": VERSION,
        "installer": {
            "name": installer_name(),
            "sha256": installer_sha256,
        },
        "signer": {
            "environment": "protected-vm-acceptance",
            "keyProtection": KEY_PROTECTION,
        },
        "environments": environments,
    }


def report_bytes(report: dict) -> bytes:
    return json.dumps(report, ensure_ascii=True, indent=2).encode("utf-8")


def detached_signature(raw: bytes, key: bytes = KEY) -> bytes:
    return hmac.new(key, raw, hashlib.sha256).hexdigest().encode("ascii")


class VerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.installer_path = self.root / installer_name()
        self.installer_path.write_bytes(INSTALLER_BYTES)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def invoke(
        self,
        report: dict | None = None,
        *,
        raw: bytes | None = None,
        signature: bytes | None = None,
        key: str | bytes | None = KEY,
        expected_commit: str = COMMIT,
        expected_version: str = VERSION,
        installer_path: Path | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], dict]:
        if raw is None:
            raw = report_bytes(valid_report() if report is None else report)
        if signature is None:
            signature = detached_signature(raw)

        report_path = self.root / "report.json"
        signature_path = self.root / "report.json.sig"
        report_path.write_bytes(raw)
        signature_path.write_bytes(signature)

        env = os.environ.copy()
        env.pop("WINDOWS_VM_REPORT_HMAC_KEY", None)
        if key is not None:
            env["WINDOWS_VM_REPORT_HMAC_KEY"] = key.decode("utf-8") if isinstance(key, bytes) else key

        command = [
            sys.executable,
            str(VERIFIER),
            "--report",
            str(report_path),
            "--signature",
            str(signature_path),
            "--installer",
            str(installer_path or self.installer_path),
            "--expected-commit",
            expected_commit,
            "--expected-version",
            expected_version,
        ]
        completed = subprocess.run(
            command,
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(completed.stdout.count("\n"), 1, completed.stdout)
        return completed, json.loads(completed.stdout)

    def assert_failure(self, completed: subprocess.CompletedProcess[str], result: dict, code: str) -> None:
        self.assertNotEqual(0, completed.returncode)
        self.assertFalse(result["verified"])
        self.assertIn(code, result["errors"])
        self.assertEqual([], [error for error in result["errors"] if not isinstance(error, str)])

    def test_acceptance_matrix_defines_the_ten_mandated_scenarios(self) -> None:
        self.assertEqual(
            [
                "win11-clean-no-dotnet-install",
                "win10-22h2-compatibility",
                "standard-user-install",
                "alternate-admin-uac-credentials",
                "elevated-terminal-identity",
                "setup-upgrade-uninstall",
                "uac-cancellation",
                "partial-system-helper-failure",
                "interrupted-copy-recovery",
                "concurrent-entry-points",
            ],
            SCENARIO_IDS,
        )
        self.assertEqual(10, len(SCENARIO_IDS))
        self.assertEqual(2, len(ENVIRONMENT_IDS))
        self.assertEqual("^19045\\.[0-9]{1,6}$", ENVIRONMENT_BY_ID["windows-10-22h2-x64"]["buildPattern"])
        self.assertEqual(
            "^(?:2[2-9][0-9]{3}|[3-9][0-9]{4})(?:\\.[0-9]{1,6})?$",
            ENVIRONMENT_BY_ID["windows-11-x64-clean"]["buildPattern"],
        )

    def test_report_schema_is_closed_and_covers_required_diagnostic_kinds(self) -> None:
        self.assertEqual(False, SCHEMA["additionalProperties"])
        self.assertEqual("object", SCHEMA["type"])
        self.assertEqual(
            {
                "schemaVersion",
                "product",
                "reportType",
                "sourceCommit",
                "version",
                "installer",
                "signer",
                "environments",
            },
            set(SCHEMA["required"]),
        )
        diagnostics = SCHEMA["properties"]["environments"]["items"]["properties"]["scenarios"]["items"]["properties"]["diagnostics"]
        allowed_kinds = set(diagnostics["items"]["properties"]["kind"]["enum"])
        required_kinds = {
            kind
            for scenario in MATRIX["scenarios"]
            for kind in scenario["requiredDiagnosticKinds"]
        }
        self.assertLessEqual(required_kinds, allowed_kinds)
        summary_pattern = diagnostics["items"]["properties"]["summary"]["pattern"]
        self.assertIn("\\x00-\\x1f", summary_pattern)
        self.assertIn("PRIVATE KEY", summary_pattern)
        self.assertIn("password", summary_pattern)
        self.assertIsNotNone(re.fullmatch(summary_pattern, "Synthetic acceptance check recorded."))
        self.assertIsNone(re.fullmatch(summary_pattern, '{"password":"hunter2"}'))
        self.assertIsNone(
            re.fullmatch(summary_pattern, "sk-proj-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        )
        self.assertIsNone(re.fullmatch(summary_pattern, "ok\r\nfake"))

        os_properties = SCHEMA["properties"]["environments"]["items"]["properties"]["os"]["properties"]
        windows_11_pattern = MATRIX["requiredEnvironments"][0]["buildPattern"]
        self.assertRegex("22000", windows_11_pattern)
        self.assertRegex("22000.1", windows_11_pattern)
        self.assertNotRegex("21999", windows_11_pattern)
        self.assertNotRegex("100000", windows_11_pattern)
        self.assertIsNotNone(re.fullmatch(os_properties["build"]["pattern"], "22000"))
        self.assertIsNotNone(re.fullmatch(os_properties["build"]["pattern"], "26100.2314"))
        self.assertIsNotNone(re.fullmatch(os_properties["build"]["pattern"], "19045.4894"))
        self.assertIsNone(re.fullmatch(os_properties["build"]["pattern"], "19045"))
        self.assertIsNone(re.fullmatch(os_properties["build"]["pattern"], "19045.1234567"))
        self.assertIsNotNone(re.fullmatch(ENVIRONMENT_BY_ID["windows-10-22h2-x64"]["buildPattern"], "19045.123456"))
        self.assertIsNone(re.fullmatch(ENVIRONMENT_BY_ID["windows-10-22h2-x64"]["buildPattern"], "19045.1234567"))
        self.assertIsNone(re.fullmatch(os_properties["build"]["pattern"], "198.51.100.42"))
        scenario_properties = SCHEMA["properties"]["environments"]["items"]["properties"]["scenarios"]["items"]["properties"]
        self.assertIn("Z$", scenario_properties["startedAt"]["pattern"])

    def test_valid_synthetic_fixture_passes(self) -> None:
        completed, result = self.invoke()
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertEqual("", completed.stderr)
        self.assertEqual(
            {
                "schemaVersion",
                "verified",
                "sourceCommit",
                "version",
                "installerSha256",
                "requiredScenarioCount",
                "verifiedScenarioCount",
                "errors",
            },
            set(result),
        )
        self.assertTrue(result["verified"])
        self.assertEqual([], result["errors"])
        self.assertEqual("", completed.stderr)
        self.assertEqual(COMMIT, result["sourceCommit"])
        self.assertEqual(VERSION, result["version"])
        self.assertEqual(hashlib.sha256(INSTALLER_BYTES).hexdigest().upper(), result["installerSha256"])
        self.assertEqual(10, result["requiredScenarioCount"])
        self.assertEqual(10, result["verifiedScenarioCount"])

    def test_tampered_report_bytes_fail_signature_verification(self) -> None:
        original = report_bytes(valid_report())
        signature = detached_signature(original)
        tampered = original.replace(b'"version": "1.2.3"', b'"version": "1.2.4"', 1)
        completed, result = self.invoke(raw=tampered, signature=signature)
        self.assert_failure(completed, result, "signature_invalid")
        self.assertNotIn("1.2.4", completed.stdout)

    def test_wrong_trusted_key_fails_and_is_not_echoed(self) -> None:
        wrong_key = "z" * 48
        completed, result = self.invoke(key=wrong_key)
        self.assert_failure(completed, result, "signature_invalid")
        self.assertNotIn(wrong_key, completed.stdout)
        self.assertNotIn(wrong_key, completed.stderr)

    def test_missing_and_short_keys_fail_closed(self) -> None:
        completed, result = self.invoke(key=None)
        self.assert_failure(completed, result, "key_missing")
        completed, result = self.invoke(key="too-short")
        self.assert_failure(completed, result, "key_invalid")
        self.assertNotIn("too-short", completed.stdout)
        self.assertNotIn("too-short", completed.stderr)

    def test_missing_and_unknown_fields_fail_closed(self) -> None:
        report = valid_report()
        report.pop("version")
        completed, result = self.invoke(report)
        self.assert_failure(completed, result, "report_field_missing")

        report = valid_report()
        report["unexpected"] = "value"
        completed, result = self.invoke(report)
        self.assert_failure(completed, result, "report_field_unknown")

    def test_duplicate_json_keys_are_rejected(self) -> None:
        raw = b'{"schemaVersion":1,"version":"9.9.9",' + report_bytes(valid_report())[1:]
        completed, result = self.invoke(raw=raw)
        self.assert_failure(completed, result, "report_invalid_json")

    def test_installer_hash_and_name_mismatches_are_rejected(self) -> None:
        report = valid_report()
        report["installer"]["sha256"] = "0" * 64
        completed, result = self.invoke(report)
        self.assert_failure(completed, result, "installer_hash_mismatch")

        report = valid_report()
        report["installer"]["name"] = installer_name("1.2.4")
        completed, result = self.invoke(report)
        self.assert_failure(completed, result, "installer_name_mismatch")

    def test_unreadable_installer_is_rejected_without_echoing_path(self) -> None:
        missing = self.root / "private" / installer_name()
        completed, result = self.invoke(installer_path=missing)
        self.assert_failure(completed, result, "installer_unreadable")
        self.assertNotIn(str(missing), completed.stdout)
        self.assertNotIn(str(missing), completed.stderr)

    def test_commit_and_version_mismatches_are_rejected(self) -> None:
        completed, result = self.invoke(expected_commit="b" * 40)
        self.assert_failure(completed, result, "commit_mismatch")

        alternate_installer = self.root / installer_name("1.2.4")
        alternate_installer.write_bytes(INSTALLER_BYTES)
        completed, result = self.invoke(
            expected_version="1.2.4",
            installer_path=alternate_installer,
        )
        self.assert_failure(completed, result, "version_mismatch")

    def test_malformed_expected_provenance_is_a_usage_error(self) -> None:
        completed, result = self.invoke(expected_commit="A" * 40)
        self.assert_failure(completed, result, "usage_error")

        completed, result = self.invoke(expected_version="v1.2.3")
        self.assert_failure(completed, result, "usage_error")

    def test_help_and_unknown_options_cannot_exit_successfully(self) -> None:
        env = os.environ.copy()
        env["WINDOWS_VM_REPORT_HMAC_KEY"] = KEY.decode("utf-8")
        for argument in ("--help", "--unknown-option"):
            with self.subTest(argument=argument):
                completed = subprocess.run(
                    [sys.executable, str(VERIFIER), argument],
                    cwd=ROOT,
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=30,
                    check=False,
                )
                self.assertNotEqual(0, completed.returncode)
                self.assertEqual(1, completed.stdout.count("\n"))
                result = json.loads(completed.stdout)
                self.assertFalse(result["verified"])
                self.assertIn("usage_error", result["errors"])

    def test_report_cannot_supply_the_hmac_key(self) -> None:
        report = valid_report()
        report["hmacKey"] = KEY.decode("utf-8")
        raw = report_bytes(report)
        completed, result = self.invoke(raw=raw, signature=detached_signature(raw))
        self.assert_failure(completed, result, "report_field_unknown")
        self.assertNotIn(KEY.decode("utf-8"), completed.stdout)
        self.assertNotIn(KEY.decode("utf-8"), completed.stderr)

    def test_unknown_scenario_is_rejected(self) -> None:
        report = valid_report()
        report["environments"][0]["scenarios"].append(
            {
                "id": "free-form-extra-scenario",
                "result": "passed",
                "startedAt": "2026-10-27T00:00:00Z",
                "finishedAt": "2026-10-27T00:01:00Z",
                "diagnostics": [{"kind": "result", "summary": "Synthetic value."}],
                "executed": True,
            }
        )
        completed, result = self.invoke(report)
        self.assert_failure(completed, result, "scenario_unknown")

    def test_malformed_json_and_unreadable_files_are_rejected(self) -> None:
        malformed = b"{not-json"
        completed, result = self.invoke(raw=malformed, signature=detached_signature(malformed))
        self.assert_failure(completed, result, "report_invalid_json")

        missing_report = self.root / "missing-report.json"
        missing_signature = self.root / "missing-report.json.sig"
        env = os.environ.copy()
        env["WINDOWS_VM_REPORT_HMAC_KEY"] = KEY.decode("utf-8")
        completed = subprocess.run(
            [
                sys.executable,
                str(VERIFIER),
                "--report",
                str(missing_report),
                "--signature",
                str(missing_signature),
                "--installer",
                str(self.installer_path),
                "--expected-commit",
                COMMIT,
                "--expected-version",
                VERSION,
            ],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(1, completed.stdout.count("\n"))
        result = json.loads(completed.stdout)
        self.assert_failure(completed, result, "report_unreadable")

    def test_missing_duplicate_and_unknown_environments_are_rejected(self) -> None:
        report = valid_report()
        report["environments"] = [report["environments"][0]]
        completed, result = self.invoke(report)
        self.assert_failure(completed, result, "required_environment_missing")

        report = valid_report()
        report["environments"].append(copy.deepcopy(report["environments"][1]))
        completed, result = self.invoke(report)
        self.assert_failure(completed, result, "environment_duplicate")

        report = valid_report()
        report["environments"][1]["id"] = "unknown-vm"
        completed, result = self.invoke(report)
        self.assert_failure(completed, result, "environment_unknown")

    def test_unexecuted_environment_is_rejected(self) -> None:
        report = valid_report()
        report["environments"][0]["executed"] = False
        completed, result = self.invoke(report)
        self.assert_failure(completed, result, "environment_not_executed")

    def test_missing_duplicate_unexecuted_and_failed_scenarios_are_rejected(self) -> None:
        report = valid_report()
        report["environments"][0]["scenarios"].pop(0)
        completed, result = self.invoke(report)
        self.assert_failure(completed, result, "scenario_missing")

        report = valid_report()
        report["environments"][0]["scenarios"].append(copy.deepcopy(report["environments"][0]["scenarios"][0]))
        completed, result = self.invoke(report)
        self.assert_failure(completed, result, "scenario_duplicate")

        report = valid_report()
        report["environments"][0]["scenarios"][0]["executed"] = False
        completed, result = self.invoke(report)
        self.assert_failure(completed, result, "scenario_not_executed")

        report = valid_report()
        report["environments"][0]["scenarios"][0]["result"] = "failed"
        completed, result = self.invoke(report)
        self.assert_failure(completed, result, "scenario_not_passed")

    def test_scenario_in_the_wrong_environment_is_rejected(self) -> None:
        report = valid_report()
        win11 = report["environments"][0]
        win10 = report["environments"][1]
        moved = next(item for item in win11["scenarios"] if item["id"] == "standard-user-install")
        win11["scenarios"].remove(moved)
        win10["scenarios"].append(moved)
        completed, result = self.invoke(report)
        self.assert_failure(completed, result, "scenario_environment_mismatch")

    def test_windows_11_build_must_be_plausible_and_optional_revision_is_accepted(self) -> None:
        for build in ("22000", "22000.1234", "22631.4890", "26100.2314", "99999"):
            with self.subTest(build=build):
                report = valid_report()
                report["environments"][0]["os"]["build"] = build
                completed, result = self.invoke(report)
                self.assertEqual(0, completed.returncode, completed.stdout)
                self.assertTrue(result["verified"])

        for build in (
            "1",
            "21999.1",
            "100000",
            "26100.",
            "26100..1",
            "26100.1234567",
            "198.51.100.42",
            "https://example.invalid/a",
        ):
            with self.subTest(build=build):
                report = valid_report()
                report["environments"][0]["os"]["build"] = build
                completed, result = self.invoke(report)
                self.assert_failure(completed, result, "environment_build_invalid")

    def test_os_version_and_signer_environment_reject_addresses_urls_and_paths(self) -> None:
        for field, value in (
            ("signer", "198.51.100.42"),
            ("signer", "https://example.invalid/a"),
            ("signer", "/home/alice"),
            ("os", "198.51.100.42"),
            ("os", "https://example.invalid/a"),
        ):
            with self.subTest(field=field, value=value):
                report = valid_report()
                if field == "signer":
                    report["signer"]["environment"] = value
                else:
                    report["environments"][0]["os"]["version"] = value
                completed, result = self.invoke(report)
                self.assert_failure(completed, result, "sensitive_data_detected")
                self.assertNotIn(value, completed.stdout)
                self.assertNotIn(value, completed.stderr)

    def test_signer_metadata_rejects_tokens_quoted_secrets_and_control_characters(self) -> None:
        cases = (
            ("sk-proj-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", "sensitive_data_detected"),
            ('{"password":"hunter2"}', "sensitive_data_detected"),
            ("ok\r\nfake", "report_schema_invalid"),
            ("ok\x00fake", "report_schema_invalid"),
            ("ok\x1bfake", "report_schema_invalid"),
        )
        for value, expected in cases:
            with self.subTest(value=value):
                report = valid_report()
                report["signer"]["environment"] = value
                completed, result = self.invoke(report)
                self.assert_failure(completed, result, expected)
                self.assertNotIn(value, completed.stdout)
                self.assertNotIn(value, completed.stderr)

    def test_unknown_os_build_and_wrong_runtime_state_are_rejected(self) -> None:
        report = valid_report()
        report["environments"][0]["os"]["family"] = "windows-12"
        completed, result = self.invoke(report)
        self.assert_failure(completed, result, "environment_os_invalid")

        report = valid_report()
        report["environments"][1]["os"]["build"] = "19044.4894"
        completed, result = self.invoke(report)
        self.assert_failure(completed, result, "environment_build_invalid")

        report = valid_report()
        report["environments"][0]["os"]["dotnetRuntimeInstalled"] = True
        completed, result = self.invoke(report)
        self.assert_failure(completed, result, "environment_runtime_mismatch")

    def test_missing_and_unknown_diagnostic_kinds_are_rejected(self) -> None:
        report = valid_report()
        report["environments"][0]["scenarios"][0]["diagnostics"].pop(0)
        completed, result = self.invoke(report)
        self.assert_failure(completed, result, "diagnostics_missing")

        report = valid_report()
        report["environments"][0]["scenarios"][0]["diagnostics"].append(
            {"kind": "free-form-log", "summary": "Synthetic value."}
        )
        completed, result = self.invoke(report)
        self.assert_failure(completed, result, "report_schema_invalid")

    def test_timestamp_shape_requires_utc_z_and_rejects_compact_or_implausible_values(self) -> None:
        accepted = ("2026-10-27T00:00:00Z", "2026-10-27T00:00:00.123456Z")
        for value in accepted:
            with self.subTest(accepted=value):
                report = valid_report()
                scenario = report["environments"][0]["scenarios"][0]
                scenario["startedAt"] = value
                scenario["finishedAt"] = "2026-10-27T00:01:00Z"
                completed, result = self.invoke(report)
                self.assertEqual(0, completed.returncode, completed.stdout)
                self.assertTrue(result["verified"])

        rejected = (
            "2026-10-27T00:00:00+00:00",
            "2026-10-27T00:00:00+05:00",
            "20261027T000000Z",
            "2026-10-27T00:00:00",
            "2999-10-27T00:00:00Z",
            "2019-12-31T23:59:59Z",
        )
        for value in rejected:
            with self.subTest(rejected=value):
                report = valid_report()
                report["environments"][0]["scenarios"][0]["startedAt"] = value
                completed, result = self.invoke(report)
                self.assert_failure(completed, result, "timestamp_invalid")

    def test_invalid_or_reversed_timestamps_are_rejected(self) -> None:
        report = valid_report()
        report["environments"][0]["scenarios"][0]["startedAt"] = "not-a-date"
        completed, result = self.invoke(report)
        self.assert_failure(completed, result, "timestamp_invalid")

        report = valid_report()
        scenario = report["environments"][0]["scenarios"][0]
        scenario["startedAt"] = "2026-10-27T00:02:00Z"
        scenario["finishedAt"] = "2026-10-27T00:01:00Z"
        completed, result = self.invoke(report)
        self.assert_failure(completed, result, "timestamp_invalid")

    def test_malformed_membership_types_return_stable_schema_errors(self) -> None:
        mutations = (
            lambda report: report["environments"][0]["os"].__setitem__("family", []),
            lambda report: report["environments"][0]["scenarios"][0].__setitem__("result", []),
            lambda report: report["environments"][0]["scenarios"][0]["diagnostics"][0].__setitem__("kind", []),
            lambda report: report["environments"][0].__setitem__("id", []),
            lambda report: report["environments"][0]["scenarios"][0].__setitem__("id", {}),
        )
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                report = valid_report()
                mutate(report)
                completed, result = self.invoke(report)
                self.assert_failure(completed, result, "report_schema_invalid")
                self.assertNotIn("internal_error", result["errors"])

    def test_token_shaped_quoted_and_control_character_text_is_rejected(self) -> None:
        unsafe_values = (
            "sk-proj-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
            "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
            "AKIAIOSFODNN7EXAMPLE",
            "Basic dXNlcjpwYXNzd29yZA==",
            '{"password":"hunter2"}',
            "-----BEGIN PRIVATE KEY-----",
            "ok\r\nfake",
            "ok\x00fake",
            "ok\x1bfake",
        )
        for unsafe in unsafe_values:
            with self.subTest(unsafe=unsafe):
                report = valid_report()
                report["environments"][0]["scenarios"][0]["diagnostics"][0]["summary"] = unsafe
                completed, result = self.invoke(report)
                expected = "report_schema_invalid" if any(ord(char) < 32 for char in unsafe) else "sensitive_data_detected"
                self.assert_failure(completed, result, expected)
                self.assertNotIn(unsafe, completed.stdout)
                self.assertNotIn(unsafe, completed.stderr)

    def test_ip_country_secret_and_local_path_diagnostics_are_rejected_without_echo(self) -> None:
        unsafe_values = [
            "Observed 198.51.100.42 during the check.",
            "Observed 2001:db8::1 during the check.",
            "country=CN",
            "token=super-secret-value",
            "password: hunter2",
            r"artifact at C:\Users\alice\private\report.txt",
            "https://proxy.example.invalid/private",
        ]
        for unsafe in unsafe_values:
            with self.subTest(unsafe=unsafe):
                report = valid_report()
                report["environments"][0]["scenarios"][0]["diagnostics"][0]["summary"] = unsafe
                completed, result = self.invoke(report)
                self.assert_failure(completed, result, "sensitive_data_detected")
                self.assertNotIn(unsafe, completed.stdout)
                self.assertNotIn(unsafe, completed.stderr)

    def test_invalid_signature_format_is_rejected(self) -> None:
        completed, result = self.invoke(signature=b"F" * 64)
        self.assert_failure(completed, result, "signature_invalid")

        completed, result = self.invoke(signature=b"abc")
        self.assert_failure(completed, result, "signature_invalid")


class SignerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.report_path = self.root / "report.json"
        self.signature_path = self.root / "report.json.sig"
        self.raw = report_bytes(valid_report())
        self.report_path.write_bytes(self.raw)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def invoke(
        self,
        key: str | None = KEY.decode("utf-8"),
        *,
        report_path: Path | None = None,
        signature_path: Path | None = None,
        extra_args: tuple[str, ...] = (),
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.pop("WINDOWS_VM_REPORT_HMAC_KEY", None)
        if key is not None:
            env["WINDOWS_VM_REPORT_HMAC_KEY"] = key
        return subprocess.run(
            [
                sys.executable,
                str(SIGNER),
                "--report",
                str(report_path or self.report_path),
                "--signature",
                str(signature_path or self.signature_path),
                *extra_args,
            ],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )

    def test_signer_writes_detached_lowercase_hmac_without_changing_report(self) -> None:
        completed = self.invoke()
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertEqual("", completed.stdout)
        self.assertEqual("", completed.stderr)
        self.assertEqual(self.raw, self.report_path.read_bytes())
        self.assertEqual(detached_signature(self.raw), self.signature_path.read_bytes())

    def test_signer_rejects_identical_and_aliased_output_paths_without_overwriting_report(self) -> None:
        completed = self.invoke(signature_path=self.report_path)
        self.assertNotEqual(0, completed.returncode)
        self.assertEqual(self.raw, self.report_path.read_bytes())

        if hasattr(os, "link"):
            hardlink = self.root / "report-hardlink.json"
            os.link(self.report_path, hardlink)
            completed = self.invoke(signature_path=hardlink)
            self.assertNotEqual(0, completed.returncode)
            self.assertEqual(self.raw, self.report_path.read_bytes())
            self.assertEqual(self.raw, hardlink.read_bytes())

        if hasattr(os, "symlink"):
            symlink = self.root / "report-symlink.json"
            try:
                symlink.symlink_to(self.report_path)
            except OSError:
                pass
            else:
                completed = self.invoke(signature_path=symlink)
                self.assertNotEqual(0, completed.returncode)
                self.assertEqual(self.raw, self.report_path.read_bytes())

    def test_signer_help_is_not_a_successful_signing_result(self) -> None:
        completed = self.invoke(extra_args=("--help",))
        self.assertNotEqual(0, completed.returncode)
        self.assertFalse(self.signature_path.exists())

    def test_signer_requires_a_long_key_from_the_environment_only(self) -> None:
        completed = self.invoke(key=None)
        self.assertNotEqual(0, completed.returncode)
        self.assertFalse(self.signature_path.exists())

        short_key = "short-key"
        completed = self.invoke(key=short_key)
        self.assertNotEqual(0, completed.returncode)
        self.assertFalse(self.signature_path.exists())
        self.assertNotIn(short_key, completed.stdout)
        self.assertNotIn(short_key, completed.stderr)


if __name__ == "__main__":
    unittest.main()
