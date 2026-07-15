#!/usr/bin/env python3
"""Align and validate an app's declared minimum macOS against bundled Mach-O files."""

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


def macho_minimums(path: Path) -> list[str]:
    try:
        with path.open("rb") as handle:
            if handle.read(4) not in MACHO_MAGICS:
                return []
    except OSError:
        return []
    result = subprocess.run(
        ["/usr/bin/vtool", "-show-build", str(path)],
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        return []
    return MINOS_PATTERN.findall(result.stdout)


def bundled_minimum(app: Path) -> tuple[str, Path] | None:
    highest: tuple[tuple[int, int, int], str, Path] | None = None
    for path in app.rglob("*"):
        if not path.is_file():
            continue
        for value in macho_minimums(path):
            candidate = (version_tuple(value), value, path)
            if highest is None or candidate[0] > highest[0]:
                highest = candidate
    return None if highest is None else (highest[1], highest[2])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument(
        "--update",
        action="store_true",
        help="raise LSMinimumSystemVersion to the highest bundled Mach-O minimum",
    )
    args = parser.parse_args()

    plist_path = args.app / "Contents" / "Info.plist"
    with plist_path.open("rb") as handle:
        plist = plistlib.load(handle)
    declared = str(plist.get("LSMinimumSystemVersion", "0.0"))
    required = bundled_minimum(args.app)
    if required is None:
        raise SystemExit(f"no Mach-O files found under {args.app}")
    required_version, required_by = required

    if args.update and version_tuple(declared) < version_tuple(required_version):
        plist["LSMinimumSystemVersion"] = required_version
        with plist_path.open("wb") as handle:
            plistlib.dump(plist, handle, sort_keys=False)
        declared = required_version

    if version_tuple(declared) < version_tuple(required_version):
        raise SystemExit(
            f"{plist_path} declares macOS {declared}, but {required_by} requires "
            f"macOS {required_version}"
        )

    relative_binary = required_by.relative_to(args.app)
    print(
        f"macOS minimum validated: {declared} "
        f"(highest bundled requirement {required_version} from {relative_binary})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
