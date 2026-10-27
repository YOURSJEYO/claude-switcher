#!/usr/bin/env python3
"""Create a detached HMAC-SHA256 signature for a VM acceptance report.

This helper signs exact report bytes. It never executes the installer, reads VM
state, or prints the trusted key. Use only from a protected signing job.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import os
import sys
import tempfile
from pathlib import Path


KEY_ENV = "WINDOWS_VM_REPORT_HMAC_KEY"
MAX_REPORT_BYTES = 2 * 1024 * 1024


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise ValueError("invalid arguments")


def read_key() -> bytes:
    value = os.environ.get(KEY_ENV)
    if value is None or value == "":
        raise ValueError("key_missing")
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise ValueError("key_invalid") from exc
    if len(encoded) < 32:
        raise ValueError("key_invalid")
    return encoded


def parse_args(argv: list[str]) -> argparse.Namespace:
    if any(argument in {"-h", "--help"} for argument in argv):
        raise ValueError("help is not a signing result")
    parser = ArgumentParser(add_help=False, allow_abbrev=False)
    parser.add_argument("--report", required=True)
    parser.add_argument("--signature", required=True)
    return parser.parse_args(argv)


def paths_refer_to_same_file(first: Path, second: Path) -> bool:
    try:
        if first.resolve(strict=False) == second.resolve(strict=False):
            return True
    except OSError:
        pass
    try:
        return first.samefile(second)
    except OSError:
        return False


def write_atomically(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
    except Exception:
        try:
            os.unlink(temporary_name)
        except OSError:
            pass
        raise


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(sys.argv[1:] if argv is None else argv)
        key = read_key()
    except ValueError:
        return 2

    try:
        report_path = Path(args.report)
        signature_path = Path(args.signature)
        if paths_refer_to_same_file(report_path, signature_path):
            return 2
        with report_path.open("rb") as handle:
            raw = handle.read(MAX_REPORT_BYTES + 1)
        if len(raw) > MAX_REPORT_BYTES:
            return 2
        signature = hmac.new(key, raw, hashlib.sha256).hexdigest().encode("ascii")
        if paths_refer_to_same_file(report_path, signature_path):
            return 2
        write_atomically(signature_path, signature)
    except Exception:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())