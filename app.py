from __future__ import annotations

import base64
import binascii
import gc
import io
import json
import math
import os
import re
import secrets
import shutil
import threading
import time
import uuid
import wave
from array import array
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parent
DATA_DIR = ROOT / "data"
AUDIO_DIR = DATA_DIR / "audio"
HISTORY_PATH = DATA_DIR / "history.jsonl"
RETENTION_PATH = DATA_DIR / "retention.json"
VOCABULARY_PATH = DATA_DIR / "vocabulary.json"
MODEL_CACHE = ROOT / ".cache" / "huggingface"
MODEL_HUB_CACHE = MODEL_CACHE / "hub"
SAMPLE_RATE = 16_000
MAX_RECORDING_BYTES = 100 * 1024 * 1024
API_VERSION = 4
MAX_JSON_BODY_BYTES = 16 * 1024
MAX_HISTORY_LIMIT = 200
DEFAULT_HISTORY_LIMIT = 20
RETENTION_DAYS = {0, 7, 30, 90}
HISTORY_ID_NAMESPACE = uuid.UUID("99bb23a4-4c7b-4d82-85aa-a33a072950f7")
STAGED_AUDIO_PREFIX = ".tiro-delete-"

MODELS = {
    "compact": {
        "id": "mlx-community/parakeet-tdt_ctc-110m",
        "label": "Compact English (459 MB)",
        "backend": "parakeet",
    },
    "parakeet-v2": {
        "id": "mlx-community/parakeet-tdt-0.6b-v2",
        "label": "Parakeet English v2 (2.47 GB)",
        "backend": "parakeet",
    },
    "qwen": {
        "id": "mlx-community/Qwen3-ASR-0.6B-4bit",
        "label": "Qwen3-ASR multilingual (713 MB)",
        "backend": "qwen",
    },
}

_model = None
_model_id: str | None = None
_operation_lock = threading.Lock()
_history_lock = threading.Lock()


def load_vocabulary() -> list[dict[str, str]]:
    try:
        payload = json.loads(VOCABULARY_PATH.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return []
    entries = payload.get("entries", []) if isinstance(payload, dict) else []
    return [
        {"spoken": entry["spoken"].strip(), "written": entry["written"].strip()}
        for entry in entries
        if isinstance(entry, dict)
        and isinstance(entry.get("spoken"), str)
        and isinstance(entry.get("written"), str)
        and entry["spoken"].strip()
        and entry["written"].strip()
    ]


def apply_vocabulary(text: str, entries: list[dict[str, str]]) -> str:
    rules = {
        entry["spoken"].casefold(): (entry["spoken"], entry["written"])
        for entry in entries
    }
    if not rules:
        return text
    replacements = {key: written for key, (_, written) in rules.items()}
    alternatives = sorted((spoken for spoken, _ in rules.values()), key=len, reverse=True)
    pattern = re.compile(
        r"(?<!\w)(?:" + "|".join(map(re.escape, alternatives)) + r")(?!\w)",
        re.IGNORECASE,
    )
    return pattern.sub(
        lambda match: replacements.get(match.group(0).casefold(), match.group(0)),
        text,
    )


def shutdown_is_authorized(received_token: str) -> bool:
    expected = os.environ.get("TIRO_WORKER_TOKEN", "")
    return bool(expected) and secrets.compare_digest(received_token, expected)


class HTTPError(ValueError):
    def __init__(self, status: HTTPStatus, message: str):
        super().__init__(message)
        self.status = status


def _history_id(entry: dict, occurrence: int = 0) -> str | None:
    timestamp = entry.get("timestamp")
    audio_file = entry.get("audio_file")
    if not isinstance(timestamp, str) or not isinstance(audio_file, str):
        return None
    framed = json.dumps(
        ["missing-id", timestamp, audio_file, occurrence],
        ensure_ascii=False,
        separators=(",", ":"),
    )
    return str(uuid.uuid5(HISTORY_ID_NAMESPACE, framed))


def _replacement_history_id(
    original_id: str,
    occurrence: int,
    entry: dict,
    used_ids: set[str],
) -> str:
    salt = 0
    while True:
        framed = json.dumps(
            [
                "duplicate-id",
                original_id,
                occurrence,
                entry.get("timestamp"),
                entry.get("audio_file"),
                salt,
            ],
            ensure_ascii=False,
            separators=(",", ":"),
        )
        candidate = str(uuid.uuid5(HISTORY_ID_NAMESPACE, framed))
        if candidate not in used_ids:
            return candidate
        salt += 1


def _atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("w", encoding="utf-8", newline="") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _read_history_lines() -> list[str]:
    try:
        return HISTORY_PATH.read_text(encoding="utf-8").splitlines(keepends=True)
    except FileNotFoundError:
        return []


def _parse_history_line(line: str) -> dict | None:
    try:
        entry = json.loads(line)
    except (json.JSONDecodeError, UnicodeError):
        return None
    return entry if isinstance(entry, dict) else None


def _serialize_entry(entry: dict, original_line: str) -> str:
    newline = "\n" if original_line.endswith("\n") else ""
    return json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + newline


def _migrate_history_locked() -> list[str]:
    lines = _read_history_lines()
    _reconcile_staged_audio_locked(lines)
    migrated = list(lines)
    changed = False
    parsed = [_parse_history_line(line) for line in lines]
    existing_ids = [
        entry["id"]
        for entry in parsed
        if entry is not None and isinstance(entry.get("id"), str)
    ]
    used_ids = set(existing_ids)
    seen_ids: dict[str, int] = {}
    missing_occurrences: dict[tuple[str, str], int] = {}
    for index, line in enumerate(lines):
        entry = parsed[index]
        if entry is None:
            continue

        existing_id = entry.get("id")
        if isinstance(existing_id, str):
            occurrence = seen_ids.get(existing_id, 0)
            seen_ids[existing_id] = occurrence + 1
            if occurrence == 0:
                continue
            generated_id = _replacement_history_id(
                existing_id, occurrence, entry, used_ids
            )
        elif "id" in entry:
            continue
        else:
            timestamp = entry.get("timestamp")
            audio_file = entry.get("audio_file")
            if not isinstance(timestamp, str) or not isinstance(audio_file, str):
                continue
            key = (timestamp, audio_file)
            occurrence = missing_occurrences.get(key, 0)
            missing_occurrences[key] = occurrence + 1
            generated_id = _history_id(entry, occurrence)
        if generated_id is None:
            continue
        while generated_id in used_ids:
            occurrence += 1
            generated_id = _history_id(entry, occurrence)
            if generated_id is None:
                break
        if generated_id is None:
            continue
        entry["id"] = generated_id
        used_ids.add(generated_id)
        migrated[index] = _serialize_entry(entry, line)
        changed = True
    if changed:
        backup = HISTORY_PATH.with_name(HISTORY_PATH.name + ".bak")
        if not backup.exists():
            shutil.copyfile(HISTORY_PATH, backup)
        _atomic_write(HISTORY_PATH, "".join(migrated))
    return migrated


def migrate_history() -> None:
    with _history_lock:
        _migrate_history_locked()


def _audio_path(entry: dict) -> Path | None:
    value = entry.get("audio_file")
    if not isinstance(value, str) or not value:
        return None
    candidate = Path(value)
    if not candidate.is_absolute():
        candidate = ROOT / candidate
    try:
        resolved = candidate.resolve()
        resolved.relative_to(AUDIO_DIR.resolve())
    except (OSError, RuntimeError, ValueError):
        return None
    return resolved


def _staged_audio_path(original: Path) -> Path:
    encoded_name = base64.urlsafe_b64encode(original.name.encode("utf-8")).decode(
        "ascii"
    ).rstrip("=")
    return original.with_name(STAGED_AUDIO_PREFIX + encoded_name)


def _staged_original_path(staged: Path) -> Path | None:
    if not staged.name.startswith(STAGED_AUDIO_PREFIX):
        return None
    encoded_name = staged.name[len(STAGED_AUDIO_PREFIX):]
    try:
        padding = "=" * (-len(encoded_name) % 4)
        name = base64.urlsafe_b64decode(encoded_name + padding).decode("utf-8")
    except (ValueError, UnicodeError, binascii.Error):
        return None
    if not name or Path(name).name != name:
        return None
    original = (staged.parent / name).resolve()
    if _staged_audio_path(original) != staged.resolve():
        return None
    return original


def _reconcile_staged_audio_locked(lines: list[str]) -> None:
    if not AUDIO_DIR.exists():
        return
    referenced = {
        audio_path
        for line in lines
        if (entry := _parse_history_line(line)) is not None
        if (audio_path := _audio_path(entry)) is not None
    }
    for staged in AUDIO_DIR.rglob(STAGED_AUDIO_PREFIX + "*"):
        original = _staged_original_path(staged)
        if original is None:
            continue
        try:
            if original in referenced and not original.exists():
                os.replace(staged, original)
            else:
                staged.unlink()
        except OSError as exc:
            print(
                f"Staged audio reconciliation failed for {staged}: {exc!r}",
                flush=True,
            )


def _entry_with_audio_status(entry: dict) -> dict:
    result = dict(entry)
    audio_path = _audio_path(entry)
    result["audio_available"] = bool(audio_path and audio_path.is_file())
    return result


def _valid_api_history_entry(entry: dict) -> bool:
    if not isinstance(entry.get("id"), str) or not entry["id"]:
        return False
    string_fields = ("timestamp", "model", "text")
    if any(key in entry and not isinstance(entry[key], str) for key in string_fields):
        return False
    optional_strings = ("raw_text", "audio_file")
    if any(
        key in entry and entry[key] is not None and not isinstance(entry[key], str)
        for key in optional_strings
    ):
        return False
    seconds = entry.get("transcription_seconds")
    if "transcription_seconds" not in entry:
        return True
    if isinstance(seconds, bool) or not isinstance(seconds, (int, float)):
        return False
    try:
        return math.isfinite(seconds)
    except OverflowError:
        return False


def recent_history(limit: int = DEFAULT_HISTORY_LIMIT, query: str = "") -> list[dict]:
    limit = max(0, min(limit, MAX_HISTORY_LIMIT))
    folded_query = query.casefold()
    with _history_lock:
        lines = _migrate_history_locked()
    entries = []
    for line in reversed(lines):
        entry = _parse_history_line(line)
        if entry is None or not _valid_api_history_entry(entry):
            continue
        if folded_query and not any(
            folded_query in value.casefold()
            for key in ("text", "raw_text", "model")
            if isinstance((value := entry.get(key)), str)
        ):
            continue
        entries.append(_entry_with_audio_status(entry))
        if len(entries) == limit:
            break
    return entries


def _unreferenced_audio_paths(
    removed: list[dict], kept_lines: list[str]
) -> list[Path]:
    kept_paths = {
        audio_path
        for line in kept_lines
        if (entry := _parse_history_line(line)) is not None
        if (audio_path := _audio_path(entry)) is not None
    }
    removed_paths = {
        audio_path
        for entry in removed
        if (audio_path := _audio_path(entry)) is not None
    }
    return sorted(removed_paths - kept_paths)


def _restore_staged_audio(staged: list[tuple[Path, Path]]) -> None:
    first_error = None
    for original, temporary in reversed(staged):
        try:
            os.replace(temporary, original)
        except OSError as exc:
            first_error = first_error or exc
    if first_error is not None:
        raise first_error


def _stage_audio_deletions(
    removed: list[dict], kept_lines: list[str]
) -> list[tuple[Path, Path]]:
    staged = []
    try:
        for original in _unreferenced_audio_paths(removed, kept_lines):
            temporary = _staged_audio_path(original)
            try:
                os.replace(original, temporary)
            except FileNotFoundError:
                continue
            staged.append((original, temporary))
    except Exception:
        _restore_staged_audio(staged)
        raise
    return staged


def _commit_history_with_staged_audio(
    removed: list[dict], kept_lines: list[str]
) -> list[tuple[Path, Path]]:
    staged = _stage_audio_deletions(removed, kept_lines)
    try:
        _atomic_write(HISTORY_PATH, "".join(kept_lines))
    except Exception:
        _restore_staged_audio(staged)
        raise
    return staged


def _finalize_staged_audio(staged: list[tuple[Path, Path]]) -> None:
    for _, temporary in staged:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        except OSError as exc:
            print(
                f"Staged audio finalization failed for {temporary}: {exc!r}",
                flush=True,
            )


def delete_history_entry(entry_id: str) -> bool:
    with _history_lock:
        lines = _migrate_history_locked()
        removed_entry = None
        kept = []
        for line in lines:
            entry = _parse_history_line(line)
            if removed_entry is None and entry is not None and entry.get("id") == entry_id:
                removed_entry = entry
            else:
                kept.append(line)
        if removed_entry is None:
            return False
        staged = _commit_history_with_staged_audio([removed_entry], kept)
        _finalize_staged_audio(staged)
    return True


def _parse_timestamp(value: object) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def load_retention_days() -> int:
    try:
        payload = json.loads(RETENTION_PATH.read_text(encoding="utf-8"))
        days = payload.get("days") if isinstance(payload, dict) else None
    except (OSError, UnicodeError, json.JSONDecodeError):
        return 0
    return days if days in RETENTION_DAYS else 0


def _persist_retention_days(days: int) -> None:
    _atomic_write(RETENTION_PATH, json.dumps({"days": days}) + "\n")


def apply_retention(days: int | None = None, now: datetime | None = None) -> int:
    current = now or datetime.now(timezone.utc)
    if current.tzinfo is None:
        current = current.replace(tzinfo=timezone.utc)
    with _history_lock:
        if days is None:
            days = load_retention_days()
        if days == 0:
            return 0
        cutoff = current.astimezone(timezone.utc).timestamp() - days * 86400
        lines = _migrate_history_locked()
        kept = []
        removed = []
        for line in lines:
            entry = _parse_history_line(line)
            timestamp = _parse_timestamp(entry.get("timestamp")) if entry else None
            if entry is not None and timestamp is not None and timestamp.timestamp() < cutoff:
                removed.append(entry)
            else:
                kept.append(line)
        if removed:
            staged = _commit_history_with_staged_audio(removed, kept)
            _finalize_staged_audio(staged)
    return len(removed)


def set_retention(days: int, now: datetime | None = None) -> int:
    if days not in RETENTION_DAYS:
        raise ValueError("days must be one of 0, 7, 30, or 90")
    current = now or datetime.now(timezone.utc)
    if current.tzinfo is None:
        current = current.replace(tzinfo=timezone.utc)
    cutoff = current.astimezone(timezone.utc).timestamp() - days * 86400
    with _history_lock:
        lines = _migrate_history_locked()
        kept = []
        removed = []
        if days:
            for line in lines:
                entry = _parse_history_line(line)
                timestamp = _parse_timestamp(entry.get("timestamp")) if entry else None
                if (
                    entry is not None
                    and timestamp is not None
                    and timestamp.timestamp() < cutoff
                ):
                    removed.append(entry)
                else:
                    kept.append(line)
        else:
            kept = lines

        retention_existed = RETENTION_PATH.exists()
        try:
            previous_retention = RETENTION_PATH.read_text(encoding="utf-8")
        except FileNotFoundError:
            previous_retention = ""
        _persist_retention_days(days)
        try:
            if removed:
                staged = _commit_history_with_staged_audio(removed, kept)
        except Exception:
            if retention_existed:
                _atomic_write(RETENTION_PATH, previous_retention)
            else:
                try:
                    RETENTION_PATH.unlink()
                except FileNotFoundError:
                    pass
            raise
        if removed:
            _finalize_staged_audio(staged)
        return len(removed)


def json_response(
    handler: BaseHTTPRequestHandler,
    payload: dict,
    status: HTTPStatus = HTTPStatus.OK,
) -> None:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def decode_pcm_wav(wav_bytes: bytes, expected_sample_rate: int = SAMPLE_RATE) -> array:
    with wave.open(io.BytesIO(wav_bytes), "rb") as recording:
        if recording.getnchannels() != 1:
            raise ValueError("Expected a mono WAV recording")
        if recording.getsampwidth() != 2:
            raise ValueError("Expected a 16-bit PCM WAV recording")
        if recording.getframerate() != expected_sample_rate:
            raise ValueError(
                f"Expected {expected_sample_rate} Hz audio, "
                f"received {recording.getframerate()} Hz"
            )
        samples = array("h")
        samples.frombytes(recording.readframes(recording.getnframes()))

    if os.sys.byteorder != "little":
        samples.byteswap()
    if not samples:
        raise ValueError("Recording contains no audio samples")
    return samples


def _load_model(model_key: str):
    global _model, _model_id
    if model_key not in MODELS:
        raise ValueError(f"Unknown transcription model: {model_key}")
    selected = MODELS[model_key]
    wanted_id = selected["id"]

    if _model is None or _model_id != wanted_id:
        if _model is not None:
            _model = None
            _model_id = None
            gc.collect()
            import mlx.core as mx

            mx.clear_cache()
        MODEL_HUB_CACHE.mkdir(parents=True, exist_ok=True)
        if selected["backend"] == "qwen":
            from mlx_audio.stt import load

            _model = load(wanted_id)
        else:
            from parakeet_mlx import from_pretrained

            _model = from_pretrained(wanted_id, cache_dir=str(MODEL_HUB_CACHE))
        _model_id = wanted_id
    return _model, selected


def preload_model(model_key: str) -> dict[str, str]:
    with _operation_lock:
        _, selected = _load_model(model_key)
    return {"loaded_model": selected["id"]}


def transcribe(wav_bytes: bytes, model_key: str) -> dict:
    samples = decode_pcm_wav(wav_bytes)

    started = time.perf_counter()
    with _operation_lock:
        model, selected = _load_model(model_key)
        import mlx.core as mx

        audio = mx.array(samples, dtype=mx.float32) / 32768.0
        if selected["backend"] == "qwen":
            result = model.generate(audio, language="English")
        else:
            from parakeet_mlx.audio import get_logmel

            mel = get_logmel(audio, model.preprocessor_config)
            result = model.generate(mel)[0]
    elapsed = time.perf_counter() - started

    AUDIO_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    audio_path = AUDIO_DIR / f"{stamp}.wav"
    audio_path.write_bytes(wav_bytes)
    raw_text = result.text.strip()
    entry = {
        "id": str(uuid.uuid4()),
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "model": selected["id"],
        "audio_file": str(audio_path.relative_to(ROOT)),
        "transcription_seconds": round(elapsed, 3),
        "text": apply_vocabulary(raw_text, load_vocabulary()),
    }
    if entry["text"] != raw_text:
        entry["raw_text"] = raw_text
    with _history_lock:
        HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
        lines = _migrate_history_locked()
        with HISTORY_PATH.open("a", encoding="utf-8") as history:
            if lines and not lines[-1].endswith("\n"):
                history.write("\n")
            history.write(json.dumps(entry, ensure_ascii=False) + "\n")
    try:
        apply_retention()
    except Exception as exc:
        print(f"Retention maintenance failed; will retry later: {exc!r}", flush=True)
    return entry


class TiroHandler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args) -> None:
        print(f"[{self.log_date_time_string()}] {format % args}", flush=True)

    def _authorized(self) -> bool:
        return shutdown_is_authorized(self.headers.get("X-Tiro-Worker-Token", ""))

    def _read_json_body(self) -> dict:
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            raise HTTPError(HTTPStatus.LENGTH_REQUIRED, "Content-Length is required")
        try:
            length = int(raw_length)
        except ValueError as exc:
            raise ValueError("Content-Length must be an integer") from exc
        if length <= 0:
            raise ValueError("JSON body is required")
        if length > MAX_JSON_BODY_BYTES:
            raise HTTPError(
                HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
                f"JSON body exceeds {MAX_JSON_BODY_BYTES} bytes",
            )
        try:
            payload = json.loads(self.rfile.read(length))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ValueError("Body must be valid JSON") from exc
        if not isinstance(payload, dict):
            raise ValueError("JSON body must be an object")
        return payload

    def _send_audio(self, entry_id: str) -> bool:
        with _history_lock:
            lines = _migrate_history_locked()
        for line in reversed(lines):
            entry = _parse_history_line(line)
            if entry is None or entry.get("id") != entry_id:
                continue
            audio_path = _audio_path(entry)
            if audio_path is None or not audio_path.is_file():
                return False
            try:
                body = audio_path.read_bytes()
            except OSError:
                return False
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return True
        return False

    def do_GET(self) -> None:
        parsed_url = urlparse(self.path)
        path = parsed_url.path
        if path == "/api/status":
            json_response(
                self,
                {
                    "api_version": API_VERSION,
                    "ready": True,
                    "loaded_model": _model_id,
                    "models": MODELS,
                    "history_file": str(HISTORY_PATH),
                },
            )
            return
        if path == "/api/history":
            parameters = parse_qs(parsed_url.query, keep_blank_values=True)
            query = parameters.get("q", [""])[-1]
            raw_limit = parameters.get("limit", [str(DEFAULT_HISTORY_LIMIT)])[-1]
            try:
                limit = int(raw_limit)
                if limit < 1:
                    raise ValueError
            except ValueError:
                json_response(
                    self,
                    {"error": "limit must be a positive integer"},
                    HTTPStatus.BAD_REQUEST,
                )
                return
            json_response(self, {"entries": recent_history(limit, query)})
            return
        if path == "/api/history/audio":
            entry_id = parse_qs(parsed_url.query).get("id", [""])[-1]
            if not entry_id or not self._send_audio(entry_id):
                json_response(self, {"error": "Audio not found"}, HTTPStatus.NOT_FOUND)
            return
        json_response(self, {"error": "Not found"}, HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        if path == "/api/shutdown":
            received = self.headers.get("X-Tiro-Worker-Token", "")
            if not shutdown_is_authorized(received):
                json_response(self, {"error": "Forbidden"}, HTTPStatus.FORBIDDEN)
                return
            json_response(self, {"stopping": True})
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return

        if path in {"/api/history/delete", "/api/history/retention"}:
            if not self._authorized():
                json_response(self, {"error": "Forbidden"}, HTTPStatus.FORBIDDEN)
                return
            try:
                payload = self._read_json_body()
                if path == "/api/history/delete":
                    entry_id = payload.get("id")
                    if not isinstance(entry_id, str) or not entry_id:
                        raise ValueError("id must be a non-empty string")
                    if not delete_history_entry(entry_id):
                        json_response(
                            self,
                            {"error": "History entry not found"},
                            HTTPStatus.NOT_FOUND,
                        )
                        return
                    json_response(self, {"deleted": True})
                else:
                    days = payload.get("days")
                    if isinstance(days, bool) or not isinstance(days, int):
                        raise ValueError("days must be one of 0, 7, 30, or 90")
                    json_response(self, {"days": days, "pruned": set_retention(days)})
            except HTTPError as exc:
                json_response(self, {"error": str(exc)}, exc.status)
            except ValueError as exc:
                json_response(self, {"error": str(exc)}, HTTPStatus.BAD_REQUEST)
            except OSError as exc:
                print(f"History mutation failed: {exc!r}", flush=True)
                json_response(
                    self,
                    {"error": "History mutation failed."},
                    HTTPStatus.INTERNAL_SERVER_ERROR,
                )
            return

        if path == "/api/preload":
            try:
                model_key = self.headers.get("X-Parakeet-Model", "compact")
                json_response(self, preload_model(model_key))
            except ValueError as exc:
                json_response(self, {"error": str(exc)}, HTTPStatus.BAD_REQUEST)
            except Exception as exc:
                print(f"Model preload failed: {exc!r}", flush=True)
                json_response(
                    self,
                    {"error": "Could not preload the transcription model."},
                    HTTPStatus.INTERNAL_SERVER_ERROR,
                )
            return

        if path != "/api/transcribe":
            json_response(self, {"error": "Not found"}, HTTPStatus.NOT_FOUND)
            return

        try:
            raw_length = self.headers.get("Content-Length")
            if raw_length is None:
                raise HTTPError(
                    HTTPStatus.LENGTH_REQUIRED, "Content-Length is required"
                )
            length = int(raw_length)
            if length > MAX_RECORDING_BYTES:
                raise HTTPError(
                    HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "Recording is too large"
                )
            if length <= 44 or length > MAX_RECORDING_BYTES:
                raise ValueError("Recording is empty or too large")
            model_key = self.headers.get("X-Parakeet-Model", "compact")
            entry = transcribe(self.rfile.read(length), model_key)
            json_response(self, entry)
        except HTTPError as exc:
            json_response(self, {"error": str(exc)}, exc.status)
        except (ValueError, wave.Error) as exc:
            json_response(self, {"error": str(exc)}, HTTPStatus.BAD_REQUEST)
        except Exception as exc:
            print(f"Transcription failed: {exc!r}", flush=True)
            json_response(
                self,
                {"error": "Local transcription failed. See data/worker.log for details."},
                HTTPStatus.INTERNAL_SERVER_ERROR,
            )


def main() -> None:
    os.environ.setdefault("HF_HOME", str(MODEL_CACHE))
    try:
        migrate_history()
    except OSError as exc:
        print(f"History startup maintenance failed: {exc!r}", flush=True)
    host = "127.0.0.1"
    port = int(os.environ.get("TIRO_PORT", "8767"))
    server = ThreadingHTTPServer((host, port), TiroHandler)
    server.daemon_threads = True
    print(f"Tiro worker is running at http://{host}:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
