from __future__ import annotations

import os
import secrets
import traceback
import uuid
from http import HTTPStatus
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"
AUDIO_DIR = DATA_DIR / "audio"
HISTORY_PATH = DATA_DIR / "history.jsonl"
RETENTION_PATH = DATA_DIR / "retention.json"
VOCABULARY_PATH = DATA_DIR / "vocabulary.json"
PROFILES_PATH = DATA_DIR / "profiles.json"
SUGGESTIONS_PATH = DATA_DIR / "suggestions.json"
SNIPPETS_PATH = DATA_DIR / "snippets.json"
MODEL_CACHE = ROOT / ".cache" / "huggingface"


def _log_exception(context: str, exc: Exception) -> None:
    print(f"{context}: {exc!r}", flush=True)
    traceback.print_exc()


MODEL_HUB_CACHE = MODEL_CACHE / "hub"
SAMPLE_RATE = 16_000
MAX_RECORDING_BYTES = 100 * 1024 * 1024
API_VERSION = 6
MAX_JSON_BODY_BYTES = 16 * 1024
MAX_ORIGIN_BUNDLE_ID = 255
MAX_ORIGIN_APP_NAME = 200
MAX_VOCABULARY_ENTRIES = 500
MAX_PROFILES = 200
MAX_SNIPPETS = 200
MAX_SNIPPET_CONTENT = 2_000
MAX_HISTORY_LIMIT = 200
DEFAULT_HISTORY_LIMIT = 20
MAX_COMPARISON_MODELS = 3
RETENTION_DAYS = {0, 7, 30, 90}
HISTORY_ID_NAMESPACE = uuid.UUID("99bb23a4-4c7b-4d82-85aa-a33a072950f7")
SUGGESTION_ID_NAMESPACE = uuid.UUID("ad2d6d17-a3ef-49df-bbd5-ed73ad9b81cb")
STAGED_AUDIO_PREFIX = ".tiro-delete-"

TRANSCRIPTION_MODES = {"standard", "verbatim"}
PUNCTUATION_MODES = {"automatic", "spoken", "none"}
QWEN_LANGUAGES = {
    "Arabic", "Cantonese", "Chinese", "Czech", "Danish", "Dutch", "English",
    "Filipino", "Finnish", "French", "German", "Greek", "Hindi", "Hungarian",
    "Indonesian", "Italian", "Japanese", "Korean", "Macedonian", "Malay",
    "Persian", "Polish", "Portuguese", "Romanian", "Russian", "Spanish",
    "Swedish", "Thai", "Turkish", "Vietnamese",
}

MODELS = {
    "compact": {
        "id": "mlx-community/parakeet-tdt_ctc-110m",
        "label": "Compact English (459 MB)",
        "backend": "parakeet",
        "download_size_bytes": 459_000_000,
    },
    "parakeet-v2": {
        "id": "mlx-community/parakeet-tdt-0.6b-v2",
        "label": "Parakeet English v2 (2.47 GB)",
        "backend": "parakeet",
        "download_size_bytes": 2_470_000_000,
    },
    "qwen": {
        "id": "mlx-community/Qwen3-ASR-0.6B-4bit",
        "label": "Qwen3-ASR multilingual (713 MB)",
        "backend": "qwen",
        "download_size_bytes": 713_000_000,
    },
}


def configure_paths(data_dir: Path, model_dir: Path) -> None:
    """Configure mutable worker storage before the server starts."""
    global ROOT, DATA_DIR, AUDIO_DIR, HISTORY_PATH, RETENTION_PATH
    global VOCABULARY_PATH, PROFILES_PATH, SUGGESTIONS_PATH, SNIPPETS_PATH
    global MODEL_CACHE, MODEL_HUB_CACHE

    ROOT = data_dir.parent
    DATA_DIR = data_dir
    AUDIO_DIR = data_dir / "audio"
    HISTORY_PATH = data_dir / "history.jsonl"
    RETENTION_PATH = data_dir / "retention.json"
    VOCABULARY_PATH = data_dir / "vocabulary.json"
    PROFILES_PATH = data_dir / "profiles.json"
    SUGGESTIONS_PATH = data_dir / "suggestions.json"
    SNIPPETS_PATH = data_dir / "snippets.json"
    MODEL_CACHE = model_dir
    MODEL_HUB_CACHE = model_dir / "hub"


def shutdown_is_authorized(received_token: str) -> bool:
    expected = os.environ.get("TIRO_WORKER_TOKEN", "")
    return bool(expected) and secrets.compare_digest(received_token, expected)


class HTTPError(ValueError):
    def __init__(self, status: HTTPStatus, message: str):
        super().__init__(message)
        self.status = status


def _atomic_write(path: Path, content: str) -> None:
    _ensure_private_directory(path.parent)
    _reject_symbolic_link(path)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        _repair_private_file(path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _ensure_private_directory(path: Path) -> None:
    _reject_symbolic_link(path)
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        os.fchmod(descriptor, 0o700)
    finally:
        os.close(descriptor)


def _reject_symbolic_link(path: Path) -> None:
    try:
        path.lstat()
    except FileNotFoundError:
        return
    if path.is_symlink():
        raise OSError(f"Refusing symbolic link at private path: {path}")


def _repair_private_file(path: Path) -> None:
    _reject_symbolic_link(path)
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        os.fchmod(descriptor, 0o600)
    finally:
        os.close(descriptor)


def _write_private_bytes(path: Path, content: bytes) -> None:
    _ensure_private_directory(path.parent)
    _reject_symbolic_link(path)
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    with os.fdopen(descriptor, "wb") as output:
        output.write(content)
        os.fchmod(output.fileno(), 0o600)


def _append_private_text(path: Path, content: str) -> None:
    _ensure_private_directory(path.parent)
    _reject_symbolic_link(path)
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    with os.fdopen(descriptor, "a", encoding="utf-8") as output:
        output.write(content)
        os.fchmod(output.fileno(), 0o600)


def ensure_private_paths() -> None:
    for directory in (DATA_DIR, AUDIO_DIR, MODEL_CACHE, MODEL_HUB_CACHE):
        _ensure_private_directory(directory)
    for path in (
        HISTORY_PATH,
        RETENTION_PATH,
        VOCABULARY_PATH,
        PROFILES_PATH,
        SUGGESTIONS_PATH,
        SNIPPETS_PATH,
    ):
        _reject_symbolic_link(path)
        if path.is_file():
            _repair_private_file(path)
