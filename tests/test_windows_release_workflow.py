from __future__ import annotations

import re
import unittest
from pathlib import Path
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[1]


def load_yaml(relative_path: str) -> tuple[str, dict[str, Any]]:
    text = (ROOT / relative_path).read_text(encoding="utf-8")
    parsed = yaml.safe_load(text)
    if not isinstance(parsed, dict):
        raise AssertionError(f"{relative_path} did not parse to a mapping")
    return text, parsed


def trigger(workflow: dict[str, Any]) -> Any:
    return workflow.get("on", workflow.get(True))


def job_steps(job: dict[str, Any]) -> list[dict[str, Any]]:
    steps = job.get("steps", [])
    if not isinstance(steps, list):
        raise AssertionError("job steps must be a list")
    return steps


def step_text(step: dict[str, Any]) -> str:
    parts = [
        str(step.get("name", "")),
        str(step.get("id", "")),
        str(step.get("run", "")),
        str(step.get("uses", "")),
    ]
    with_values = step.get("with", {})
    if isinstance(with_values, dict):
        parts.extend(f"{key}: {value}" for key, value in with_values.items())
    env_values = step.get("env", {})
    if isinstance(env_values, dict):
        parts.extend(str(value) for value in env_values.values())
    return "\n".join(parts)


def job_text(job: dict[str, Any]) -> str:
    return "\n".join(step_text(step) for step in job_steps(job))


def job_permissions(job: dict[str, Any]) -> dict[str, str]:
    permissions = job.get("permissions", {})
    return permissions if isinstance(permissions, dict) else {}


class WindowsReleaseWorkflowContractTests(unittest.TestCase):
    def test_checks_are_read_only_and_preserve_existing_macos_coverage(self) -> None:
        _, workflow = load_yaml(".github/workflows/checks.yml")
        self.assertEqual(workflow.get("permissions"), {"contents": "read"})
        jobs = workflow.get("jobs", {})
        mac_jobs = [job for job in jobs.values() if str(job.get("runs-on", "")).startswith("macos-")]
        self.assertTrue(mac_jobs, "macOS checks job is missing")
        mac_text = "\n".join(job_text(job) for job in mac_jobs)
        for required in (
            'python3 -m pip install --disable-pip-version-check "PyYAML==6.0.2"',
            "python3 -B -m unittest discover -s tests -v",
            "swiftc -O -parse-as-library -warnings-as-errors",
            "shasum -a 256 -c SHA256SUMS",
            "node --check docs/app.js",
            "bash -n core/claude-switch.sh",
        ):
            self.assertIn(required, mac_text)

        mac_steps = [step for job in mac_jobs for step in job_steps(job)]
        dependency_index = next(
            index
            for index, step in enumerate(mac_steps)
            if "PyYAML==6.0.2" in step_text(step)
        )
        tests_index = next(
            index
            for index, step in enumerate(mac_steps)
            if "python3 -B -m unittest discover -s tests -v" in step_text(step)
        )
        self.assertLess(dependency_index, tests_index)

    def test_checks_builds_and_validates_windows_x64_package(self) -> None:
        _, workflow = load_yaml(".github/workflows/checks.yml")
        jobs = workflow.get("jobs", {})
        windows_jobs = [job for job in jobs.values() if "windows-2022" in str(job.get("runs-on", ""))]
        self.assertEqual(len(windows_jobs), 1, "one Windows x64 checks job is required")
        windows = windows_jobs[0]
        text = job_text(windows)
        for required in (
            "actions/setup-dotnet@v4",
            "10.0.403",
            "innosetup",
            "6.7.3",
            "Parser]::ParseFile",
            "powershell.exe",
            "pwsh",
            "windows/ClaudeSwitcher.App.Tests/ClaudeSwitcher.App.Tests.csproj",
            "windows/ClaudeSwitcher.Admin.Tests/ClaudeSwitcher.Admin.Tests.csproj",
            "scripts/package-windows.ps1",
            "manifest.json",
            "ClaudeSwitcher-",
            "-windows-setup.exe",
            "-windows.zip",
        ):
            self.assertIn(required, text)
        self.assertNotIn("--no-restore", text)
        upload_steps = [step for step in job_steps(windows) if "actions/upload-artifact@" in str(step.get("uses", ""))]
        self.assertEqual(len(upload_steps), 1, "Windows checks must upload one package artifact")
        artifact_name = str(upload_steps[0].get("with", {}).get("name", ""))
        self.assertRegex(artifact_name, r"checks-windows-x64-.*github\.run_id")
        self.assertRegex(artifact_name, r"github\.run_attempt")
        self.assertNotIn("WINDOWS_VM_REPORT_HMAC_KEY", text)

    def test_release_separates_builds_and_has_one_downstream_publisher(self) -> None:
        _, workflow = load_yaml(".github/workflows/release.yml")
        self.assertEqual(workflow.get("permissions"), {"contents": "read"})
        jobs = workflow.get("jobs", {})
        for required_job in ("build-macos-linux", "build-windows", "verify-windows-vm", "publish"):
            self.assertIn(required_job, jobs)

        mac_job = jobs["build-macos-linux"]
        mac_text = job_text(mac_job)
        self.assertIn("scripts/package-macos.sh", mac_text)
        self.assertIn("ClaudeSwitcher-${VERSION}-macos-${ARCH_LABEL}-app-only.zip", mac_text)
        self.assertIn("ClaudeSwitcher-${VERSION}-macos-${ARCH_LABEL}-app-only.dmg", mac_text)
        self.assertNotIn("macos-arm64-app-only", mac_text)
        self.assertIn("-linux.tar.gz", mac_text)
        self.assertNotIn("ClaudeSwitcher-${VERSION}-windows.zip", mac_text)
        self.assertEqual(
            mac_job.get("outputs", {}).get("macos_arch"),
            "${{ steps.macos-arch.outputs.arch }}",
        )
        arch_step = next(
            step for step in job_steps(mac_job) if step.get("id") == "macos-arch"
        )
        arch_text = step_text(arch_step)
        self.assertIn("uname -m", arch_text)
        self.assertIn("arm64", arch_text)
        self.assertIn("x86_64", arch_text)
        self.assertIn("GITHUB_OUTPUT", arch_text)

        windows_text = job_text(jobs["build-windows"])
        self.assertIn("scripts/package-windows.ps1", windows_text)
        self.assertIn("actions/upload-artifact@", windows_text)
        self.assertNotIn("gh release", windows_text)

        write_jobs = [
            name for name, job in jobs.items() if job_permissions(job).get("contents") == "write"
        ]
        self.assertEqual(write_jobs, ["publish"])
        self.assertTrue({"build-macos-linux", "build-windows", "verify-windows-vm"}.issubset(set(jobs["publish"].get("needs", []))))

        release_commands = [
            name
            for name, job in jobs.items()
            if re.search(r"\bgh release (?:create|upload|edit)\b", job_text(job))
        ]
        self.assertEqual(release_commands, ["publish"])

    def test_release_verifier_cli_and_publisher_architecture_match_actual_contract(self) -> None:
        _, workflow = load_yaml(".github/workflows/release.yml")
        verifier = (ROOT / "scripts/verify-windows-vm-report.py").read_text(encoding="utf-8")
        for required in (
            'parser.add_argument("--expected-commit", required=True)',
            'parser.add_argument("--expected-version", required=True)',
        ):
            self.assertIn(required, verifier)

        gate_text = job_text(workflow["jobs"]["verify-windows-vm"])
        self.assertIn('--expected-commit "$GITHUB_SHA"', gate_text)
        self.assertIn('--expected-version "$VERSION"', gate_text)
        self.assertNotIn('--commit "$GITHUB_SHA"', gate_text)
        self.assertNotIn('--version "$VERSION"', gate_text)

        publisher_text = job_text(workflow["jobs"]["publish"])
        self.assertIn("${{ needs.build-macos-linux.outputs.macos_arch }}", publisher_text)
        self.assertIn("MACOS_ARCH", publisher_text)
        self.assertNotIn("uname -m", publisher_text)

    def test_release_gate_requires_trusted_signed_exact_installer_evidence(self) -> None:
        text, workflow = load_yaml(".github/workflows/release.yml")
        gate = workflow["jobs"]["verify-windows-vm"]
        gate_text = job_text(gate)
        environment = gate.get("environment")
        environment_name = environment.get("name") if isinstance(environment, dict) else environment
        self.assertTrue(environment_name, "VM verifier must run in a protected GitHub environment")
        self.assertIn("build-windows", gate.get("needs", []))
        self.assertNotEqual(job_permissions(gate).get("contents"), "write")

        self.assertEqual(text.count("${{ secrets.WINDOWS_VM_REPORT_HMAC_KEY }}"), 1)
        self.assertIn("${{ secrets.WINDOWS_VM_REPORT_HMAC_KEY }}", gate_text)
        self.assertIn("actions/download-artifact@", gate_text)
        self.assertIn("WINDOWS_VM_ACCEPTANCE_RUN_ID", gate_text)
        self.assertIn("run-id: ${{ vars.WINDOWS_VM_ACCEPTANCE_RUN_ID }}", gate_text)
        self.assertIn("windows-vm-acceptance-${{ github.sha }}", gate_text)
        self.assertIn("scripts/verify-windows-vm-report.py", gate_text)
        for argument in (
            "--report",
            "--signature",
            "--expected-commit \"$GITHUB_SHA\"",
            "--expected-version \"$VERSION\"",
            "--installer",
            "-windows-setup.exe",
        ):
            self.assertIn(argument, gate_text)
        self.assertNotIn("sign-report.py", gate_text)
        self.assertNotIn("scripts/package-windows.ps1", gate_text)

    def test_publisher_validates_all_assets_checksums_and_publishes_only_draft_after_verification(self) -> None:
        text, workflow = load_yaml(".github/workflows/release.yml")
        publisher = workflow["jobs"]["publish"]
        publisher_text = job_text(publisher)
        for asset in (
            "macos-",
            "-app-only.zip",
            "-app-only.dmg",
            "installer-kit.zip",
            "linux.tar.gz",
            "-windows-setup.exe",
            "-windows.zip",
            "manifest.json",
            "SHA256SUMS-release.txt",
        ):
            self.assertIn(asset, publisher_text)
        for required in (
            "gh release view",
            "gh release create",
            "--draft",
            "gh release download",
            "gh release edit",
            "--draft=false",
            "manifest",
            "sourceCommit",
            "runtime",
            "win-x64",
        ):
            self.assertIn(required, publisher_text)
        self.assertNotIn("--clobber", text)

        validation_step = next(
            step
            for step in job_steps(publisher)
            if step.get("name") == "Validate complete asset inventory and Windows manifest"
        )
        validation_text = step_text(validation_step)
        self.assertIn('VERSION="${VERSION#v}"\nexport VERSION', validation_text)
        self.assertIn("actual != expected", validation_text)
        self.assertIn("extra={sorted(actual - expected)}", validation_text)
        self.assertIn("entry.is_symlink()", validation_text)
        self.assertIn('"setup": f"ClaudeSwitcher-{version}-windows-setup.exe"', validation_text)
        self.assertIn('"zip": f"ClaudeSwitcher-{version}-windows.zip"', validation_text)
        self.assertIn("macos-{os.environ['MACOS_ARCH']}-app-only.zip", validation_text)
        self.assertIn("macos-{os.environ['MACOS_ARCH']}-app-only.dmg", validation_text)
        self.assertIn("manifest[\"artifacts\"][key][\"name\"] == filename", validation_text)
        self.assertLess(validation_text.index("actual != expected"), validation_text.index("manifest ="))

    def test_ignore_rules_cover_python_and_dotnet_build_outputs(self) -> None:
        ignored = (ROOT / ".gitignore").read_text(encoding="utf-8")
        for pattern in ("__pycache__/", "*.py[cod]", "build/", "**/bin/", "**/obj/"):
            self.assertIn(pattern, ignored)

    def test_docs_describe_native_beta_runtime_install_and_acceptance_boundary(self) -> None:
        windows_doc = (ROOT / "windows/README.md").read_text(encoding="utf-8")
        windows_lower = windows_doc.lower()

        source_files = (
            "windows/ClaudeSwitcher.iss",
            "windows/helpers/UserSetup.ps1",
            "windows/install.ps1",
            "windows/ClaudeSwitcher.App/Services/SetupClient.cs",
            "windows/ClaudeSwitcher.App/Models/SetupProtocol.cs",
            ".github/workflows/checks.yml",
        )
        for relative_path in source_files:
            self.assertTrue(
                (ROOT / relative_path).is_file(),
                f"documented source is missing: {relative_path}",
            )

        for required in (
            ".NET 10",
            "10.0.403",
            "6.7.3",
            "self-contained",
            "ClaudeSwitcher.exe",
            "apphost",
            "PublishSingleFile=false",
            "unsigned",
            "SmartScreen",
            "Windows 11 x64",
            "Windows 10 22H2",
            "ARM64",
            "-windows-setup.exe",
            "-windows.zip",
            "PowerShell 5.1",
            "VM acceptance",
            "hosted CI",
            "not Windows 10/11 acceptance",
            "preserve",
            "UAC",
            "Preview/Apply",
            "SetupClient",
            "no successful local Setup EXE compile",
            "no successful hosted run is claimed",
        ):
            self.assertIn(required.lower(), windows_lower)

        self.assertIn("ClaudeSwitcher-<version>-windows-setup.exe", windows_doc)
        self.assertIn("inno setup", windows_lower)
        self.assertIn("does not contain the protected admin helper executable", windows_lower)
        self.assertIn("does not install the protected helper", windows_lower)
        self.assertIn("no full install or system-repair parity", windows_lower)
        self.assertIn("no windows release readiness", windows_lower)

        for required in (
            "sid-scoped",
            "running",
            "fresh heartbeat",
            "expected user sid/session",
        ):
            self.assertIn(required, windows_lower)

        stale_claims = (
            "原生 setup exe 尚不能由当前代码树打包产出",
            "claudeswitcher.iss` 缺失",
            "helpers/` 目前没有打包所需的 helper payload",
            "仍是旧的交互式管理员脚本",
            "当前打包器在生成任一工件前就会失败",
            "原生安装器集成未完成",
            "补齐 inno 模板与 helper payload",
            "missing inno template",
            "payload are missing",
            "native packaging is currently blocked",
            "current packager fails before producing either windows asset",
        )
        for stale in stale_claims:
            self.assertNotIn(stale, windows_lower)

        for readme in ("README.md", "README.en.md"):
            doc = (ROOT / readme).read_text(encoding="utf-8")
            doc_lower = doc.lower()
            self.assertIn("ClaudeSwitcher-<version>-windows-setup.exe", doc)
            self.assertIn("ClaudeSwitcher-<version>-windows.zip", doc)
            self.assertIn("claudeswitcher.iss", doc_lower)
            self.assertIn("helpers/", doc_lower)
            self.assertRegex(doc_lower, r"hosted ci|\u6258\u7ba1 ci|hosted runner")
            self.assertRegex(doc_lower, r"signed vm|signed.*acceptance|\u7b7e\u540d.*vm|vm.*\u7b7e\u540d")
            self.assertRegex(doc_lower, r"no windows release|release readiness|\u6ca1\u6709\u53ef\u53d1\u5e03")
            self.assertRegex(doc_lower, r"no setup exe|\u672a\u6210\u529f\u7f16\u8bd1 setup exe|\u5c1a\u672a\u6210\u529f\u7f16\u8bd1 setup exe")
            for required in (
                "no full install or system-repair parity",
                "does not install the protected helper",
                "never run user-writable scripts elevated",
                "native setup",
            ):
                self.assertIn(required, doc_lower)
            for stale in stale_claims:
                self.assertNotIn(stale, doc_lower)


if __name__ == "__main__":
    unittest.main()
