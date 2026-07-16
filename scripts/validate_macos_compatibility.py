#!/usr/bin/env python3
"""Enforce a deployment target and architecture across a macOS app bundle."""

from __future__ import annotations

import argparse
import plistlib
import re
import subprocess
from pathlib import Path


MINOS_PATTERN = re.compile(r"^\s*minos\s+(\d+(?:\.\d+){1,2})\s*$", re.MULTILINE)
MACHO_MAGICS = {
    bytes.fromhex(value)
    for value in (
        "feedface",
        "cefaedfe",
        "feedfacf",
        "cffaedfe",
        "cafebabe",
        "bebafeca",
        "cafebabf",
        "bfbafeca",
    )
}


def version_tuple(value: str) -> tuple[int, int, int]:
    parts = [int(part) for part in value.split(".")]
    return tuple((parts + [0, 0])[:3])  # type: ignore[return-value]


def is_macho(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            return handle.read(4) in MACHO_MAGICS
    except OSError as error:
        raise ValueError(f"could not read bundled file {path}: {error}") from error


def command_output(arguments: list[str], path: Path) -> str:
    result = subprocess.run(arguments, capture_output=True, check=False, text=True)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "unknown error"
        raise ValueError(f"could not inspect {path}: {detail}")
    return result.stdout


def macho_details(path: Path) -> tuple[list[str], set[str]]:
    build = command_output(["/usr/bin/vtool", "-show-build", str(path)], path)
    minimums = MINOS_PATTERN.findall(build)
    if not minimums:
        raise ValueError(f"Mach-O file has no deployment target: {path}")
    architectures = set(
        command_output(["/usr/bin/lipo", "-archs", str(path)], path).split()
    )
    return minimums, architectures


def validate(app: Path, target: str, architecture: str) -> tuple[str, Path, int]:
    target_version = version_tuple(target)
    highest: tuple[tuple[int, int, int], str, Path] | None = None
    violations: list[str] = []
    count = 0

    for path in app.rglob("*"):
        if not path.is_file():
            continue
        try:
            macho = is_macho(path)
        except ValueError as error:
            violations.append(str(error))
            continue
        if not macho:
            continue
        count += 1
        try:
            minimums, architectures = macho_details(path)
        except ValueError as error:
            violations.append(str(error))
            continue
        if architecture not in architectures:
            violations.append(f"{path} lacks required {architecture} architecture")
        for minimum in minimums:
            candidate = (version_tuple(minimum), minimum, path)
            if highest is None or candidate[0] > highest[0]:
                highest = candidate
            if candidate[0] > target_version:
                violations.append(f"{path} requires macOS {minimum}, above {target}")

    if count == 0 or highest is None:
        violations.append(f"no Mach-O files found under {app}")
    if violations:
        raise ValueError("\n".join(violations))
    return highest[1], highest[2], count


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--target", required=True)
    parser.add_argument("--architecture", default="arm64")
    args = parser.parse_args()

    plist_path = args.app / "Contents" / "Info.plist"
    with plist_path.open("rb") as handle:
        plist = plistlib.load(handle)
    declared = str(plist.get("LSMinimumSystemVersion", "0.0"))
    if version_tuple(declared) != version_tuple(args.target):
        raise SystemExit(
            f"{plist_path} declares macOS {declared}; expected exactly {args.target}"
        )

    try:
        required, required_by, count = validate(
            args.app, args.target, args.architecture
        )
    except ValueError as error:
        raise SystemExit(str(error)) from error
    relative_binary = required_by.relative_to(args.app)
    print(
        f"macOS {args.target} compatibility verified across {count} Mach-O files "
        f"(highest requirement {required} from {relative_binary})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
