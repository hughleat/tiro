"""PyInstaller entry point that relocates all mutable Tiro worker state."""

from __future__ import annotations

import os
import sys
from pathlib import Path

if not getattr(sys, "frozen", False):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tiro_worker import common, server


def configure_paths() -> None:
    data_root = Path(os.environ["TIRO_DATA_DIR"]).expanduser()
    model_root = Path(os.environ["TIRO_MODEL_DIR"]).expanduser()
    common._reject_symbolic_link(data_root)
    common._reject_symbolic_link(model_root)
    data_dir = data_root.resolve()
    model_dir = model_root.resolve()

    common.configure_paths(data_dir, model_dir)
    os.environ["HF_HOME"] = str(model_dir)
    common.ensure_private_paths()


if __name__ == "__main__":
    configure_paths()
    server.main()
