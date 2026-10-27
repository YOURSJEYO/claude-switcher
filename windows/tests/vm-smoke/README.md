# Windows VM acceptance preparation

This directory prepares Task 7. It does not execute installers, provision VMs, or contain acceptance evidence. Do not commit a generated acceptance report unless a protected environment produced it and the controller explicitly requests it.

## Files

- `acceptance-scenarios.json`: mandatory scenario/environment matrix and required diagnostic kinds.
- `report-schema.json`: closed structural JSON Schema for acceptance reports. The verifier and scenario matrix are authoritative for exact scenario IDs, real UTC dates, the supported year range, and execution ordering; passing JSON Schema alone is insufficient.
- `sign-report.py`: stdlib-only HMAC-SHA256 signer for the protected signing job.
- `../../../scripts/verify-windows-vm-report.py`: fail-closed verifier for release gating.

## Protected-environment requirements

1. Run VM scenarios only on disposable Windows VMs with synthetic account trees and fake proxy services. Never sign into Claude and never use residential egress.
2. Assemble the report only from the exact CI artifact for the run being released. Validate it before signing.
3. Keep `WINDOWS_VM_REPORT_HMAC_KEY` in the CI secret store of a protected environment. Require trusted maintainers, manual approval or equivalent protection, short-lived jobs, and masked logs.
4. Never expose the key to VM workloads, pull-request jobs, command lines, files, caches, diagnostics, or artifacts. Rotate it after suspected disclosure.
5. Run `sign-report.py` only inside the protected signing job. It signs the exact report bytes and writes a detached lowercase hex signature.
6. Retain workflow/run identity and VM provisioning logs outside the signed report for audit. The HMAC proves integrity relative to the configured key; it does not prove execution or provide non-repudiation.

## Verifier contract

```text
python scripts/verify-windows-vm-report.py \
  --report <report.json> \
  --signature <report.json.sig> \
  --installer <ClaudeSwitcher-<version>-windows-setup.exe> \
  --expected-commit <40 lowercase hex> \
  --expected-version <x.y.z[-suffix]>
```

- The key comes only from `WINDOWS_VM_REPORT_HMAC_KEY` (UTF-8, at least 32 bytes). No key argument or report field is accepted.
- The detached signature is lowercase hexadecimal HMAC-SHA256 over the exact report bytes.
- The verifier recomputes the installer SHA256 and requires both the exact report hash and `ClaudeSwitcher-<expected-version>-windows-setup.exe`.
- Required commit, version, Windows 11 x64 clean/no-.NET evidence, Windows 10 22H2 x64 evidence, all 10 mandated scenarios exactly once, `executed: true`, `result: passed`, and required diagnostic kinds must match.
- Unknown/missing fields, duplicate environments/scenarios, mismatched hashes, unsupported OS, unsafe diagnostics, IP addresses, credentials, or secrets fail closed.
- Output is exactly one JSON object on stdout. Exit code 0 means all checks passed; any other result is a verification failure. Untrusted input and human-readable error text are not written to stderr; failures use stable codes in `errors`.

## Signing example

```text
Set WINDOWS_VM_REPORT_HMAC_KEY only through protected CI secret injection.
python windows/tests/vm-smoke/sign-report.py --report build/vm/report.json --signature build/vm/report.json.sig
Remove the environment variable after the signing step.
```

Do not type the key on a command line or store it in a temporary file. Ensure the CI platform masks it in logs.

## Mandatory scenario checklist

The verifier requires each scenario exactly once in an executed environment, with `result: passed` and the required diagnostic kinds.

| ID | Required environment | Assertion |
| --- | --- | --- |
| `win11-clean-no-dotnet-install` | Windows 11 x64, no .NET runtime | Setup succeeds without downloading .NET; native EXE launches; first-run state is correct. |
| `win10-22h2-compatibility` | Windows 10 22H2 x64, build `19045.*` | Record build, launch result, and compatibility conclusion. |
| `standard-user-install` | Windows 11 x64 | Config/snapshots/task bind the initiating standard user; Claude is non-elevated. |
| `alternate-admin-uac-credentials` | Windows 11 x64 | Alternate admin approval does not retarget user data/task; Claude is non-elevated. |
| `elevated-terminal-identity` | Windows 11 x64 | Setup does not guess the original user; it installs only and directs a normal desktop relaunch. |
| `setup-upgrade-uninstall` | Windows 11 x64 | Setup/upgrade/uninstall preserve archives/config; owned task/shortcut behavior, task ACL/identity, packaged files, and normal-user Claude launch are verified. |
| `uac-cancellation` | Windows 11 x64 | Actual incomplete stage is shown; success is not reported; retry is possible. |
| `partial-system-helper-failure` | Windows 11 x64 | Failed stage is shown; success is not reported; recoverable state and retry are verified. |
| `interrupted-copy-recovery` | Windows 11 x64 | Injected failure/crash leaves a recoverable synthetic account and consistent marker. |
| `concurrent-entry-points` | Windows 11 x64 | CLI, legacy UI, and native UI mutations serialize; one writer; no snapshot loss. |

## Evidence limits

A successful verifier result confirms schema, signature, hash, commit, version, OS/scenario coverage, and the verifier's conservative redaction checks only. It does not independently prove that a VM ran, that diagnostics are truthful, or that Windows 10 is supported. The controller must keep actual execution records separate and may mark a platform unsupported when its VM was unavailable.

## Scanner limits

The scanner is heuristic and deliberately conservative. It scans every string in the report for control characters; URLs, IP addresses, email addresses, and local paths; common credential labels (including quoted JSON-style labels); well-known token prefixes; authorization values; private-key headers; and country/egress metadata. Matching text is rejected rather than rewritten, so benign text containing one of those shapes can fail closed.

The scanner cannot guarantee detection of arbitrary secrets, novel or unrecognized token formats, encoded/encrypted payloads, or secrets split across fields. A clean result is not proof that a diagnostic is true or that a report is safe to publish outside the protected environment. Keep reports minimal, synthetic, and free of raw logs or real account, network, or credential data.
