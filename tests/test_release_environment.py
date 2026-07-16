import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from scripts.prepare_release_environment import locked_package, select_wheel
from scripts.validate_macos_compatibility import validate


class ReleaseEnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.lock = {
            "package": [
                {
                    "name": "mlx",
                    "version": "1.2.3",
                    "wheels": [
                        {
                            "url": "https://example.test/mlx-1.2.3-cp314-cp314-macosx_14_0_arm64.whl",
                            "hash": "sha256:mac14",
                        },
                        {
                            "url": "https://example.test/mlx-1.2.3-cp314-cp314-macosx_26_0_arm64.whl",
                            "hash": "sha256:mac26",
                        },
                    ],
                },
                {
                    "name": "mlx-metal",
                    "version": "1.2.3",
                    "wheels": [
                        {
                            "url": "https://example.test/mlx_metal-1.2.3-py3-none-macosx_14_0_arm64.whl",
                            "hash": "sha256:metal14",
                        }
                    ],
                },
            ]
        }

    def test_selects_exact_deployment_target_and_python(self):
        wheel = select_wheel(locked_package(self.lock, "mlx"), "cp314", "14.0")
        self.assertEqual(wheel["hash"], "sha256:mac14")

    def test_selects_pure_python_metal_wheel(self):
        wheel = select_wheel(
            locked_package(self.lock, "mlx-metal"), "cp314", "14.0"
        )
        self.assertEqual(wheel["hash"], "sha256:metal14")

    def test_missing_target_wheel_fails(self):
        with self.assertRaisesRegex(ValueError, "locked wheel not found"):
            select_wheel(locked_package(self.lock, "mlx"), "cp313", "14.0")

    def test_duplicate_package_fails(self):
        self.lock["package"].append(self.lock["package"][0])
        with self.assertRaisesRegex(ValueError, "expected one locked mlx"):
            locked_package(self.lock, "mlx")


class CompatibilityValidationTests(unittest.TestCase):
    def validate_fixture(self, minimum: str, architectures: set[str]):
        with TemporaryDirectory() as directory:
            binary = Path(directory) / "binary"
            binary.touch()
            with (
                patch(
                    "scripts.validate_macos_compatibility.is_macho",
                    return_value=True,
                ),
                patch(
                    "scripts.validate_macos_compatibility.macho_details",
                    return_value=([minimum], architectures),
                ),
            ):
                return validate(Path(directory), "14.0", "arm64")

    def test_accepts_targeted_arm64_binary(self):
        minimum, _, count = self.validate_fixture("14.0", {"arm64"})
        self.assertEqual((minimum, count), ("14.0", 1))

    def test_rejects_binary_requiring_newer_system(self):
        with self.assertRaisesRegex(ValueError, "above 14.0"):
            self.validate_fixture("15.0", {"arm64"})

    def test_rejects_binary_without_arm64(self):
        with self.assertRaisesRegex(ValueError, "lacks required arm64"):
            self.validate_fixture("14.0", {"x86_64"})


if __name__ == "__main__":
    unittest.main()
