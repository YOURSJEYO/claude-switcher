#!/usr/bin/env python3
"""Fail-closed verifier for ClaudeSwitcher Windows VM acceptance reports.

The trusted key is supplied only through WINDOWS_VM_REPORT_HMAC_KEY. The
verifier never accepts a key from command-line arguments, files, or report
content, and never writes the key or untrusted report text to stdout/stderr.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import ipaddress
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
MATRIX_PATH = ROOT / "windows" / "tests" / "vm-smoke" / "acceptance-scenarios.json"

MAX_REPORT_BYTES = 2 * 1024 * 1024
MAX_SIGNATURE_BYTES = 64
MAX_INSTALLER_CHUNK = 1024 * 1024

KEY_ENV = "WINDOWS_VM_REPORT_HMAC_KEY"
KEY_PROTECTION = "external-secret-store; WINDOWS_VM_REPORT_HMAC_KEY >= 32 UTF-8 bytes"
EXPECTED_ENVIRONMENT_IDS = ("windows-11-x64-clean", "windows-10-22h2-x64")
EXPECTED_SCENARIO_IDS = (
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
)

COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
VERSION_RE = re.compile(
    r"^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?$"
)
SHA256_UPPER_RE = re.compile(r"^[0-9A-F]{64}$")
SIGNATURE_RE = re.compile(r"^[0-9a-f]{64}$")
ENV_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
SIGNER_ENV_RE = re.compile(r"^[A-Za-z][A-Za-z0-9 _-]{0,127}$")
OS_VERSION_RE = re.compile(r"^(?:[0-9]{2}H[12]|Windows (?:10|11) [0-9]{2}H[12])$")
BUILD_RE = re.compile(r"^[0-9]{1,6}(?:\.[0-9]{1,6})?$")
UTC_TIMESTAMP_RE = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:\.[0-9]{1,6})?Z$"
)
CONTROL_CHAR_RE = re.compile(r"[\x00-\x1f\x7f-\x9f]")
MIN_TIMESTAMP = datetime(2020, 1, 1, tzinfo=timezone.utc)
MAX_TIMESTAMP = datetime(2100, 1, 1, tzinfo=timezone.utc)
INSTALLER_NAME_RE = re.compile(r"^ClaudeSwitcher-[0-9A-Za-z.-]+-windows-setup\.exe$")
ALLOWED_DIAGNOSTIC_KINDS = {
    "setup-exit",
    "app-launch",
    "first-run-state",
    "os-build",
    "identity",
    "task",
    "acl",
    "account-data",
    "packaged-files",
    "cancellation",
    "helper-stage",
    "recovery",
    "concurrency",
    "result",
    "environment",
}
ALLOWED_RESULTS = {"passed", "failed", "blocked", "not-run"}
TOP_LEVEL_FIELDS = {
    "schemaVersion",
    "product",
    "reportType",
    "sourceCommit",
    "version",
    "installer",
    "signer",
    "environments",
}
INSTALLER_FIELDS = {"name", "sha256"}
SIGNER_FIELDS = {"environment", "keyProtection"}
ENVIRONMENT_FIELDS = {"id", "os", "executed", "scenarios"}
OS_FIELDS = {
    "family",
    "version",
    "build",
    "architecture",
    "dotnetRuntimeInstalled",
}
SCENARIO_FIELDS = {
    "id",
    "result",
    "startedAt",
    "finishedAt",
    "diagnostics",
    "executed",
}
DIAGNOSTIC_FIELDS = {"kind", "summary"}

IPV4_RE = re.compile(r"(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])")
IPV6_CANDIDATE_RE = re.compile(
    r"(?<![0-9A-Fa-f])(?:[0-9A-Fa-f]{0,4}:){2,}[0-9A-Fa-f:.]*(?![0-9A-Fa-f])"
)
URL_RE = re.compile(r"(?i)\b(?:https?|ftp)://[^\s]+")
WINDOWS_PATH_RE = re.compile(r"(?i)(?:\b[A-Z]:[\\/]|\\\\[^\\\s]+\\|%USERPROFILE%[\\/])")
POSIX_PATH_RE = re.compile(r"(?i)(?:^|[\s\"'])/(?:Users|home|root|tmp|var/tmp)/")
SECRET_RE = re.compile(
    r"(?i)[\"']?\b(?:access[_-]?token|refresh[_-]?token|auth[_-]?token|"
    r"api[_-]?key|apikey|access[_-]?key|client[_-]?secret|"
    r"aws[_-]?secret[_-]?access[_-]?key|token|password|passwd|secret|"
    r"private[_-]?key|authorization|cookie|session[_-]?id)\b[\"']?\s*[:=]"
)
COUNTRY_EGRESS_RE = re.compile(
    r"(?i)[\"']?\b(?:country|country[_-]?code|loc|location|egress(?:[_-]?ip)?)"
    r"\b[\"']?\s*[:=]"
)
EMAIL_RE = re.compile(r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b")
TOKEN_SHAPED_RE = re.compile(
    r"(?i)(?:"
    r"\bsk-(?:proj-|svcacct-|live-|test-)?[A-Za-z0-9_-]{16,}\b"
    r"|\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b"
    r"|\bgithub_pat_[A-Za-z0-9_]{20,}\b"
    r"|\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"
    r"|\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}"
    r"|\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"
    r"|\bxox[baprs]-[A-Za-z0-9-]{10,}\b"
    r"|\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}\b"
    r"|\bAIza[0-9A-Za-z_-]{30,}\b"
    r"|\bnpm_[A-Za-z0-9]{20,}\b"
    r"|-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----"
    r")"
)


class UsageError(ValueError):
    pass


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise UsageError(message)


def unique_errors(errors: Iterable[str]) -> list[str]:
    return sorted(set(errors))


def emit_result(
    *,
    verified: bool,
    source_commit: str | None,
    version: str | None,
    installer_sha256: str | None,
    required_count: int,
    verified_count: int,
    errors: Iterable[str],
) -> int:
    payload = {
        "schemaVersion": 1,
        "verified": bool(verified),
        "sourceCommit": source_commit,
        "version": version,
        "installerSha256": installer_sha256,
        "requiredScenarioCount": int(required_count),
        "verifiedScenarioCount": int(verified_count),
        "errors": unique_errors(errors),
    }
    sys.stdout.write(json.dumps(payload, ensure_ascii=True, separators=(",", ":")) + "\n")
    return 0 if verified else 1


def parse_args(argv: list[str]) -> argparse.Namespace:
    # Help must not be a successful verification path: callers can distinguish
    # success only by exit 0, so every invocation emits the machine result.
    if any(argument in {"-h", "--help"} for argument in argv):
        raise UsageError("help is not a verification result")
    parser = ArgumentParser(add_help=False, allow_abbrev=False)
    parser.add_argument("--report", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--installer", required=True)
    parser.add_argument("--expected-commit", required=True)
    parser.add_argument("--expected-version", required=True)
    return parser.parse_args(argv)


def load_matrix() -> dict[str, Any]:
    data = json.loads(MATRIX_PATH.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("matrix is not an object")
    if data.get("schemaVersion") != 1:
        raise ValueError("matrix schema version")
    if data.get("product") != "ClaudeSwitcher":
        raise ValueError("matrix product")
    if data.get("reportType") != "windows-vm-acceptance":
        raise ValueError("matrix report type")
    if data.get("installerNameTemplate") != "ClaudeSwitcher-{version}-windows-setup.exe":
        raise ValueError("matrix installer template")
    environments = data.get("requiredEnvironments")
    scenarios = data.get("scenarios")
    if not isinstance(environments, list) or not isinstance(scenarios, list):
        raise ValueError("matrix arrays")
    if tuple(item.get("id") for item in environments if isinstance(item, dict)) != EXPECTED_ENVIRONMENT_IDS:
        raise ValueError("matrix environment ids")
    if tuple(item.get("id") for item in scenarios if isinstance(item, dict)) != EXPECTED_SCENARIO_IDS:
        raise ValueError("matrix scenario ids")
    scenario_by_id = {item["id"]: item for item in scenarios if isinstance(item, dict)}
    if set(scenario_by_id) != set(EXPECTED_SCENARIO_IDS):
        raise ValueError("matrix scenario set")
    environment_by_id = {item["id"]: item for item in environments if isinstance(item, dict)}
    for scenario_id in EXPECTED_SCENARIO_IDS:
        scenario = scenario_by_id[scenario_id]
        environment_id = scenario.get("requiredEnvironment")
        if environment_id not in environment_by_id:
            raise ValueError("matrix scenario environment")
        kinds = scenario.get("requiredDiagnosticKinds")
        if not isinstance(kinds, list) or not kinds or not all(kind in ALLOWED_DIAGNOSTIC_KINDS for kind in kinds):
            raise ValueError("matrix diagnostic kinds")
    for environment in environments:
        ids = environment.get("scenarioIds")
        if not isinstance(ids, list) or not all(isinstance(item, str) for item in ids):
            raise ValueError("matrix environment scenarios")
        if set(ids) != {
            scenario_id
            for scenario_id, scenario in scenario_by_id.items()
            if scenario.get("requiredEnvironment") == environment["id"]
        }:
            raise ValueError("matrix environment coverage")
    return data


def read_limited(path: Path, limit: int) -> bytes:
    with path.open("rb") as handle:
        data = handle.read(limit + 1)
    if len(data) > limit:
        raise ValueError("file too large")
    return data


def hash_installer(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(MAX_INSTALLER_CHUNK)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest().upper()


def trusted_key() -> tuple[bytes | None, str | None]:
    value = os.environ.get(KEY_ENV)
    if value is None or value == "":
        return None, "key_missing"
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError:
        return None, "key_invalid"
    if len(encoded) < 32:
        return None, "key_invalid"
    return encoded, None


def strict_json(raw: bytes) -> Any:
    def reject_duplicate(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate key")
            result[key] = value
        return result

    def reject_constant(value: str) -> None:
        raise ValueError("non-finite number")

    text = raw.decode("utf-8")
    return json.loads(
        text,
        object_pairs_hook=reject_duplicate,
        parse_constant=reject_constant,
    )


def exact_object(
    value: Any,
    expected_fields: set[str],
    errors: set[str],
) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        errors.add("report_schema_invalid")
        return None
    actual_fields = set(value)
    if expected_fields - actual_fields:
        errors.add("report_field_missing")
    if actual_fields - expected_fields:
        errors.add("report_field_unknown")
    return value


def valid_string(value: Any, *, pattern: re.Pattern[str] | None = None, minimum: int = 1, maximum: int = 512) -> bool:
    if not isinstance(value, str):
        return False
    if not (minimum <= len(value) <= maximum):
        return False
    if CONTROL_CHAR_RE.search(value):
        return False
    if pattern is not None and pattern.fullmatch(value) is None:
        return False
    return True


def valid_iso8601(value: Any) -> datetime | None:
    if not isinstance(value, str) or UTC_TIMESTAMP_RE.fullmatch(value) is None:
        return None
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        return None
    if parsed.tzinfo is None or parsed.utcoffset() != timedelta(0):
        return None
    if not (MIN_TIMESTAMP <= parsed < MAX_TIMESTAMP):
        return None
    return parsed


def has_ip_address(text: str) -> bool:
    for match in IPV4_RE.finditer(text):
        try:
            ipaddress.ip_address(match.group(0))
        except ValueError:
            continue
        return True
    for match in IPV6_CANDIDATE_RE.finditer(text):
        candidate = match.group(0).strip(".,;()[]{}<>")
        try:
            ipaddress.ip_address(candidate)
        except ValueError:
            continue
        return True
    return False


def text_is_safe(text: str) -> bool:
    if URL_RE.search(text):
        return False
    if WINDOWS_PATH_RE.search(text) or POSIX_PATH_RE.search(text):
        return False
    if SECRET_RE.search(text) or COUNTRY_EGRESS_RE.search(text):
        return False
    if TOKEN_SHAPED_RE.search(text):
        return False
    if EMAIL_RE.search(text) or has_ip_address(text):
        return False
    return True


def iter_strings(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from iter_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from iter_strings(item)


def validate_shape(report: Any) -> tuple[set[str], dict[str, Any] | None]:
    errors: set[str] = set()
    top = exact_object(report, TOP_LEVEL_FIELDS, errors)
    if top is None:
        return errors, None

    if any(not text_is_safe(text) for text in iter_strings(top)):
        errors.add("sensitive_data_detected")

    if type(top.get("schemaVersion")) is not int or top.get("schemaVersion") != 1:
        errors.add("report_schema_invalid")
    if top.get("product") != "ClaudeSwitcher":
        errors.add("report_schema_invalid")
    if top.get("reportType") != "windows-vm-acceptance":
        errors.add("report_schema_invalid")
    if not valid_string(top.get("sourceCommit"), pattern=COMMIT_RE, maximum=40):
        errors.add("report_schema_invalid")
    if not valid_string(top.get("version"), pattern=VERSION_RE, maximum=128):
        errors.add("report_schema_invalid")

    installer = exact_object(top.get("installer"), INSTALLER_FIELDS, errors)
    if installer is not None:
        if not valid_string(installer.get("name"), pattern=INSTALLER_NAME_RE, maximum=256):
            errors.add("report_schema_invalid")
        if not valid_string(installer.get("sha256"), pattern=SHA256_UPPER_RE, maximum=64):
            errors.add("report_schema_invalid")

    signer = exact_object(top.get("signer"), SIGNER_FIELDS, errors)
    if signer is not None:
        if not valid_string(signer.get("environment"), pattern=SIGNER_ENV_RE, maximum=128):
            errors.add("report_schema_invalid")
        if signer.get("keyProtection") != KEY_PROTECTION:
            errors.add("report_schema_invalid")

    environments = top.get("environments")
    if not isinstance(environments, list):
        errors.add("report_schema_invalid")
        return errors, top
    if len(environments) < 2:
        errors.add("required_environment_missing")

    for environment in environments:
        env = exact_object(environment, ENVIRONMENT_FIELDS, errors)
        if env is None:
            continue
        if not valid_string(env.get("id"), pattern=ENV_ID_RE, maximum=128):
            errors.add("report_schema_invalid")
        if not isinstance(env.get("executed"), bool):
            errors.add("report_schema_invalid")

        os_record = exact_object(env.get("os"), OS_FIELDS, errors)
        if os_record is not None:
            family = os_record.get("family")
            if not isinstance(family, str) or family not in {"windows-10", "windows-11"}:
                errors.add("report_schema_invalid")
            if not valid_string(os_record.get("version"), pattern=OS_VERSION_RE, maximum=32):
                errors.add("report_schema_invalid")
            if not valid_string(os_record.get("build"), pattern=BUILD_RE, maximum=32):
                errors.add("report_schema_invalid")
            if os_record.get("architecture") != "x64":
                errors.add("report_schema_invalid")
            if not isinstance(os_record.get("dotnetRuntimeInstalled"), bool):
                errors.add("report_schema_invalid")

        scenarios = env.get("scenarios")
        if not isinstance(scenarios, list):
            errors.add("report_schema_invalid")
            continue
        for scenario in scenarios:
            item = exact_object(scenario, SCENARIO_FIELDS, errors)
            if item is None:
                continue
            if not valid_string(item.get("id"), maximum=128):
                errors.add("report_schema_invalid")
            result = item.get("result")
            if not isinstance(result, str) or result not in ALLOWED_RESULTS:
                errors.add("report_schema_invalid")
            if not isinstance(item.get("executed"), bool):
                errors.add("report_schema_invalid")
            if valid_iso8601(item.get("startedAt")) is None:
                errors.add("timestamp_invalid")
            if valid_iso8601(item.get("finishedAt")) is None:
                errors.add("timestamp_invalid")

            diagnostics = item.get("diagnostics")
            if not isinstance(diagnostics, list) or not (1 <= len(diagnostics) <= 32):
                errors.add("diagnostics_missing")
                continue
            for diagnostic in diagnostics:
                diag = exact_object(diagnostic, DIAGNOSTIC_FIELDS, errors)
                if diag is None:
                    continue
                kind = diag.get("kind")
                if not isinstance(kind, str) or kind not in ALLOWED_DIAGNOSTIC_KINDS:
                    errors.add("report_schema_invalid")
                if not valid_string(diag.get("summary"), maximum=512):
                    errors.add("report_schema_invalid")
                elif not text_is_safe(diag["summary"]):
                    errors.add("sensitive_data_detected")
    return errors, top


def validate_report(
    report: dict[str, Any],
    matrix: dict[str, Any],
    expected_commit: str,
    expected_version: str,
    expected_installer_name: str,
    computed_installer_sha256: str | None,
    installer_path_name: str | None,
) -> tuple[set[str], int]:
    errors, top = validate_shape(report)
    if top is None:
        return errors, 0

    if top.get("sourceCommit") != expected_commit:
        errors.add("commit_mismatch")
    if top.get("version") != expected_version:
        errors.add("version_mismatch")

    installer = top.get("installer")
    if isinstance(installer, dict):
        if installer.get("name") != expected_installer_name:
            errors.add("installer_name_mismatch")
        if computed_installer_sha256 is None:
            errors.add("installer_unreadable")
        elif installer.get("sha256") != computed_installer_sha256:
            errors.add("installer_hash_mismatch")
    elif computed_installer_sha256 is None:
        errors.add("installer_unreadable")
    if installer_path_name != expected_installer_name:
        errors.add("installer_name_mismatch")

    environments = top.get("environments")
    if not isinstance(environments, list):
        return errors, 0

    scenario_by_id = {
        item["id"]: item for item in matrix["scenarios"] if isinstance(item, dict)
    }
    environment_by_id = {
        item["id"]: item for item in matrix["requiredEnvironments"] if isinstance(item, dict)
    }

    seen_environment_ids: set[str] = set()
    environment_records: dict[str, dict[str, Any]] = {}
    for environment in environments:
        if not isinstance(environment, dict):
            continue
        environment_id = environment.get("id")
        if not isinstance(environment_id, str):
            errors.add("report_schema_invalid")
            continue
        if environment_id in seen_environment_ids:
            errors.add("environment_duplicate")
        seen_environment_ids.add(environment_id)
        if environment_id not in environment_by_id:
            errors.add("environment_unknown")
            continue
        environment_records[environment_id] = environment
        if environment.get("executed") is not True:
            errors.add("environment_not_executed")

        os_record = environment.get("os")
        if not isinstance(os_record, dict):
            errors.add("environment_os_invalid")
            continue
        specification = environment_by_id[environment_id]
        if (
            os_record.get("family") != specification["osFamily"]
            or os_record.get("architecture") != specification["architecture"]
        ):
            errors.add("environment_os_invalid")
        if environment_id == "windows-11-x64-clean":
            if os_record.get("dotnetRuntimeInstalled") is not False:
                errors.add("environment_runtime_mismatch")
        if environment_id == "windows-10-22h2-x64" and os_record.get("version") != "22H2":
            errors.add("environment_os_invalid")
        build_pattern = specification.get("buildPattern")
        build = os_record.get("build")
        if not isinstance(build_pattern, str) or not isinstance(build, str) or re.fullmatch(build_pattern, build) is None:
            errors.add("environment_build_invalid")

    for environment_id in EXPECTED_ENVIRONMENT_IDS:
        if environment_id not in seen_environment_ids:
            errors.add("required_environment_missing")

    occurrences: dict[str, list[tuple[str, dict[str, Any]]]] = {
        scenario_id: [] for scenario_id in EXPECTED_SCENARIO_IDS
    }
    for environment_id, environment in environment_records.items():
        scenarios = environment.get("scenarios")
        if not isinstance(scenarios, list):
            continue
        for scenario in scenarios:
            if not isinstance(scenario, dict):
                continue
            scenario_id = scenario.get("id")
            if not isinstance(scenario_id, str):
                errors.add("report_schema_invalid")
                continue
            if scenario_id not in scenario_by_id:
                errors.add("scenario_unknown")
                continue
            occurrences[scenario_id].append((environment_id, scenario))

    verified_scenarios = 0
    for scenario_id in EXPECTED_SCENARIO_IDS:
        matches = occurrences[scenario_id]
        specification = scenario_by_id[scenario_id]
        required_environment = specification["requiredEnvironment"]
        if not matches:
            errors.add("scenario_missing")
            continue
        if len(matches) > 1:
            errors.add("scenario_duplicate")

        correct_environment = any(environment_id == required_environment for environment_id, _ in matches)
        if not correct_environment:
            errors.add("scenario_environment_mismatch")
        if any(environment_id != required_environment for environment_id, _ in matches):
            errors.add("scenario_environment_mismatch")

        scenario_ok = len(matches) == 1 and matches[0][0] == required_environment
        if scenario_ok:
            scenario = matches[0][1]
            if scenario.get("executed") is not True:
                errors.add("scenario_not_executed")
                scenario_ok = False
            if scenario.get("result") != "passed":
                errors.add("scenario_not_passed")
                scenario_ok = False

            started = valid_iso8601(scenario.get("startedAt"))
            finished = valid_iso8601(scenario.get("finishedAt"))
            if started is None or finished is None or finished < started:
                errors.add("timestamp_invalid")
                scenario_ok = False

            diagnostics = scenario.get("diagnostics")
            if not isinstance(diagnostics, list):
                errors.add("diagnostics_missing")
                scenario_ok = False
            else:
                kinds = {
                    diagnostic.get("kind")
                    for diagnostic in diagnostics
                    if isinstance(diagnostic, dict) and isinstance(diagnostic.get("kind"), str)
                }
                if not set(specification["requiredDiagnosticKinds"]).issubset(kinds):
                    errors.add("diagnostics_missing")
                    scenario_ok = False
                if any(
                    isinstance(diagnostic, dict)
                    and isinstance(diagnostic.get("summary"), str)
                    and not text_is_safe(diagnostic["summary"])
                    for diagnostic in diagnostics
                ):
                    errors.add("sensitive_data_detected")
                    scenario_ok = False
            if scenario_ok:
                verified_scenarios += 1

    return errors, verified_scenarios


def main(argv: list[str] | None = None) -> int:
    args_list = sys.argv[1:] if argv is None else argv
    try:
        args = parse_args(args_list)
    except UsageError:
        return emit_result(
            verified=False,
            source_commit=None,
            version=None,
            installer_sha256=None,
            required_count=len(EXPECTED_SCENARIO_IDS),
            verified_count=0,
            errors={"usage_error"},
        )

    expected_commit = args.expected_commit
    expected_version = args.expected_version
    if COMMIT_RE.fullmatch(expected_commit) is None or VERSION_RE.fullmatch(expected_version) is None:
        return emit_result(
            verified=False,
            source_commit=None,
            version=None,
            installer_sha256=None,
            required_count=len(EXPECTED_SCENARIO_IDS),
            verified_count=0,
            errors={"usage_error"},
        )

    expected_installer_name = f"ClaudeSwitcher-{expected_version}-windows-setup.exe"
    try:
        matrix = load_matrix()
    except Exception:
        return emit_result(
            verified=False,
            source_commit=expected_commit,
            version=expected_version,
            installer_sha256=None,
            required_count=len(EXPECTED_SCENARIO_IDS),
            verified_count=0,
            errors={"verifier_configuration_invalid"},
        )

    key, key_error = trusted_key()
    if key_error is not None:
        return emit_result(
            verified=False,
            source_commit=expected_commit,
            version=expected_version,
            installer_sha256=None,
            required_count=len(matrix["scenarios"]),
            verified_count=0,
            errors={key_error},
        )

    try:
        report_raw = read_limited(Path(args.report), MAX_REPORT_BYTES)
    except Exception:
        return emit_result(
            verified=False,
            source_commit=expected_commit,
            version=expected_version,
            installer_sha256=None,
            required_count=len(matrix["scenarios"]),
            verified_count=0,
            errors={"report_unreadable"},
        )

    try:
        signature_raw = read_limited(Path(args.signature), MAX_SIGNATURE_BYTES)
    except Exception:
        return emit_result(
            verified=False,
            source_commit=expected_commit,
            version=expected_version,
            installer_sha256=None,
            required_count=len(matrix["scenarios"]),
            verified_count=0,
            errors={"signature_unreadable"},
        )

    try:
        signature_text = signature_raw.decode("ascii")
    except UnicodeDecodeError:
        signature_text = ""
    if SIGNATURE_RE.fullmatch(signature_text) is None:
        return emit_result(
            verified=False,
            source_commit=expected_commit,
            version=expected_version,
            installer_sha256=None,
            required_count=len(matrix["scenarios"]),
            verified_count=0,
            errors={"signature_invalid"},
        )

    expected_signature = hmac.new(key, report_raw, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected_signature, signature_text):
        return emit_result(
            verified=False,
            source_commit=expected_commit,
            version=expected_version,
            installer_sha256=None,
            required_count=len(matrix["scenarios"]),
            verified_count=0,
            errors={"signature_invalid"},
        )

    try:
        report = strict_json(report_raw)
    except Exception:
        return emit_result(
            verified=False,
            source_commit=expected_commit,
            version=expected_version,
            installer_sha256=None,
            required_count=len(matrix["scenarios"]),
            verified_count=0,
            errors={"report_invalid_json"},
        )

    if not isinstance(report, dict):
        return emit_result(
            verified=False,
            source_commit=expected_commit,
            version=expected_version,
            installer_sha256=None,
            required_count=len(matrix["scenarios"]),
            verified_count=0,
            errors={"report_schema_invalid"},
        )

    installer_sha256: str | None = None
    try:
        installer_path = Path(args.installer)
        installer_sha256 = hash_installer(installer_path)
        installer_path_name = installer_path.name
    except Exception:
        installer_path_name = None

    errors, verified_count = validate_report(
        report,
        matrix,
        expected_commit,
        expected_version,
        expected_installer_name,
        installer_sha256,
        installer_path_name,
    )
    verified = not errors
    return emit_result(
        verified=verified,
        source_commit=expected_commit,
        version=expected_version,
        installer_sha256=installer_sha256,
        required_count=len(matrix["scenarios"]),
        verified_count=verified_count,
        errors=errors,
    )


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
    except Exception:
        sys.stdout.write(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "verified": False,
                    "sourceCommit": None,
                    "version": None,
                    "installerSha256": None,
                    "requiredScenarioCount": len(EXPECTED_SCENARIO_IDS),
                    "verifiedScenarioCount": 0,
                    "errors": ["internal_error"],
                },
                separators=(",", ":"),
            )
            + "\n"
        )
        raise SystemExit(1)