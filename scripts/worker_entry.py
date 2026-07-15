"""PyInstaller entry point that relocates all mutable Tiro worker state."""

from __future__ import annotations

import os
import sys
from pathlib import Path

if not getattr(sys, "frozen", False):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import app


def configure_paths() -> None:
    data_dir = Path(os.environ["TIRO_DATA_DIR"]).expanduser().resolve()
    model_dir = Path(os.environ["TIRO_MODEL_DIR"]).expanduser().resolve()

    app.ROOT = data_dir.parent
    app.DATA_DIR = data_dir
    app.AUDIO_DIR = data_dir / "audio"
    app.HISTORY_PATH = data_dir / "history.jsonl"
    app.RETENTION_PATH = data_dir / "retention.json"
    app.VOCABULARY_PATH = data_dir / "vocabulary.json"
    app.PROFILES_PATH = data_dir / "profiles.json"
    app.SUGGESTIONS_PATH = data_dir / "suggestions.json"
    app.MODEL_CACHE = model_dir
    app.MODEL_HUB_CACHE = model_dir / "hub"
    os.environ["HF_HOME"] = str(model_dir)


if __name__ == "__main__":
    configure_paths()
    app.main()
