#!/usr/bin/env python3
"""Install the locked MLX wheels for Tiro's deployment target."""

from __future__ import annotations

import argparse
import json
import platform
import subprocess
import tomllib
from pathlib import Path
from urllib.parse import urlparse


TARGET_PACKAGES = ("mlx", "mlx-metal")


def locked_package(lock: dict, name: str) -> dict:
    matches = [package for package in lock["package"] if package["name"] == name]
    if len(matches) != 1:
        raise ValueError(f"expected one locked {name} package, found {len(matches)}")
    return matches[0]


def select_wheel(package: dict, python_tag: str, target: str) -> dict:
    distribution = package["name"].replace("-", "_")
    version = package["version"]
    platform_tag = f"macosx_{target.replace('.', '_')}_arm64"
    abi = f"{python_tag}-{python_tag}" if package["name"] == "mlx" else "py3-none"
    expected = f"{distribution}-{version}-{abi}-{platform_tag}.whl"
    matches = [
        wheel
        for wheel in package.get("wheels", [])
        if Path(urlparse(wheel["url"]).path).name == expected
    ]
    if len(matches) != 1:
        raise ValueError(f"locked wheel not found: {expected}")
    return matches[0]


def python_tag(python: Path) -> str:
    command = [
        str(python),
        "-c",
        "import json, sys; print(json.dumps([sys.implementation.name, sys.version_info[:2]]))",
    ]
    implementation, version = json.loads(subprocess.check_output(command, text=True))
    if implementation != "cpython":
        raise ValueError(f"unsupported release interpreter: {implementation}")
    return f"cp{version[0]}{version[1]}"


def install_arguments(lock: dict, tag: str, target: str) -> list[str]:
    arguments: list[str] = []
    for name in TARGET_PACKAGES:
        wheel = select_wheel(locked_package(lock, name), tag, target)
        algorithm, digest = wheel["hash"].split(":", 1)
        arguments.append(f"{wheel['url']}#{algorithm}={digest}")
    return arguments


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--python", type=Path, required=True)
    parser.add_argument("--target", required=True)
    args = parser.parse_args()

    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("release wheel preparation requires an Apple Silicon Mac")
    if not args.python.is_file():
        raise SystemExit(f"release interpreter not found: {args.python}")

    with args.lock.open("rb") as handle:
        lock = tomllib.load(handle)
    wheels = install_arguments(lock, python_tag(args.python), args.target)
    subprocess.run(
        [
            str(args.python),
            "-m",
            "uv",
            "pip",
            "install",
            "--python",
            str(args.python),
            "--reinstall",
            "--no-deps",
            *wheels,
        ],
        check=True,
    )
    print(f"Prepared locked MLX wheels for macOS {args.target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
