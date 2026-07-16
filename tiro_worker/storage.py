from __future__ import annotations

import base64
import binascii
import json
import math
import os
import shutil
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path

from . import common
from .common import (
    DEFAULT_HISTORY_LIMIT,
    HISTORY_ID_NAMESPACE,
    MAX_HISTORY_LIMIT,
    RETENTION_DAYS,
    STAGED_AUDIO_PREFIX,
)

_history_lock = threading.Lock()
_state_lock = threading.RLock()

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

def _read_history_lines() -> list[str]:
    try:
        return common.HISTORY_PATH.read_text(encoding="utf-8").splitlines(keepends=True)
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
        backup = common.HISTORY_PATH.with_name(common.HISTORY_PATH.name + ".bak")
        if not backup.exists():
            shutil.copyfile(common.HISTORY_PATH, backup)
        common._atomic_write(common.HISTORY_PATH, "".join(migrated))
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
        candidate = common.ROOT / candidate
    try:
        resolved = candidate.resolve()
        resolved.relative_to(common.AUDIO_DIR.resolve())
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
    if not common.AUDIO_DIR.exists():
        return
    referenced = {
        audio_path
        for line in lines
        if (entry := _parse_history_line(line)) is not None
        if (audio_path := _audio_path(entry)) is not None
    }
    for staged in common.AUDIO_DIR.rglob(STAGED_AUDIO_PREFIX + "*"):
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
    optional_strings = (
        "raw_text",
        "audio_file",
        "corrected_text",
        "origin_bundle_id",
        "origin_app_name",
    )
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
            for key in (
                "text",
                "raw_text",
                "corrected_text",
                "model",
                "origin_app_name",
            )
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
        common._atomic_write(common.HISTORY_PATH, "".join(kept_lines))
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
        from .text import _refresh_suggestions_after_history_locked

        _refresh_suggestions_after_history_locked(kept)
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
        payload = json.loads(common.RETENTION_PATH.read_text(encoding="utf-8"))
        days = payload.get("days") if isinstance(payload, dict) else None
    except (OSError, UnicodeError, json.JSONDecodeError):
        return 0
    return days if days in RETENTION_DAYS else 0


def _persist_retention_days(days: int) -> None:
    common._atomic_write(common.RETENTION_PATH, json.dumps({"days": days}) + "\n")


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
            from .text import _refresh_suggestions_after_history_locked

            _refresh_suggestions_after_history_locked(kept)
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

        retention_existed = common.RETENTION_PATH.exists()
        try:
            previous_retention = common.RETENTION_PATH.read_text(encoding="utf-8")
        except FileNotFoundError:
            previous_retention = ""
        _persist_retention_days(days)
        try:
            if removed:
                staged = _commit_history_with_staged_audio(removed, kept)
        except Exception:
            if retention_existed:
                common._atomic_write(common.RETENTION_PATH, previous_retention)
            else:
                try:
                    common.RETENTION_PATH.unlink()
                except FileNotFoundError:
                    pass
            raise
        if removed:
            _finalize_staged_audio(staged)
            from .text import _refresh_suggestions_after_history_locked

            _refresh_suggestions_after_history_locked(kept)
        return len(removed)
