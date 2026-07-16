from __future__ import annotations

import base64
import binascii
import json
import math
import os
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
        common._atomic_write(common.HISTORY_PATH, "".join(migrated))
    backup = common.HISTORY_PATH.with_name(common.HISTORY_PATH.name + ".bak")
    try:
        backup.unlink()
    except FileNotFoundError:
        pass
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


def _refresh_suggestions_without_stale_evidence(kept_lines: list[str]) -> None:
    from . import text

    with _state_lock:
        try:
            text._reconcile_suggestions_locked(kept_lines)
        except (OSError, ValueError):
            common._atomic_write(
                common.SUGGESTIONS_PATH,
                '{"version":1,"suggestions":[]}\n',
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
        _refresh_suggestions_without_stale_evidence(kept)
    return True


def _parse_timestamp(value: object) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)
    except (OverflowError, ValueError):
        return None


_PRIVACY_FIELDS = {"store_history", "store_recordings", "retention_days"}
_NEW_INSTALL_PRIVACY = {
    "store_history": False,
    "store_recordings": False,
    "retention_days": 30,
}


def _validated_privacy(payload: object) -> dict:
    if not isinstance(payload, dict) or set(payload) != _PRIVACY_FIELDS:
        raise ValueError(
            "privacy settings require exactly store_history, store_recordings, "
            "and retention_days"
        )
    store_history = payload["store_history"]
    store_recordings = payload["store_recordings"]
    retention_days = payload["retention_days"]
    if not isinstance(store_history, bool) or not isinstance(store_recordings, bool):
        raise ValueError("store_history and store_recordings must be booleans")
    if isinstance(retention_days, bool) or retention_days not in RETENTION_DAYS:
        raise ValueError("retention_days must be one of 0, 1, 7, 30, or 90")
    if store_recordings and not store_history:
        raise ValueError("store_recordings requires store_history")
    return {
        "store_history": store_history,
        "store_recordings": store_recordings,
        "retention_days": retention_days,
    }


def _legacy_retention_days() -> int:
    try:
        payload = json.loads(common.RETENTION_PATH.read_text(encoding="utf-8"))
        days = payload.get("days") if isinstance(payload, dict) else None
    except (OSError, UnicodeError, json.JSONDecodeError):
        return 0
    return days if not isinstance(days, bool) and days in RETENTION_DAYS else 0


def _persist_privacy_locked(settings: dict) -> None:
    common._atomic_write(
        common.PRIVACY_PATH,
        json.dumps(settings, separators=(",", ":")) + "\n",
    )


def _load_privacy_locked() -> dict:
    try:
        payload = json.loads(common.PRIVACY_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        legacy = common.HISTORY_PATH.exists() or common.RETENTION_PATH.exists()
        settings = (
            {
                "store_history": True,
                "store_recordings": True,
                "retention_days": _legacy_retention_days(),
            }
            if legacy
            else dict(_NEW_INSTALL_PRIVACY)
        )
        _persist_privacy_locked(settings)
        return settings
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError("privacy settings are malformed or unavailable") from exc
    return _validated_privacy(payload)


def load_privacy_settings() -> dict:
    with _history_lock:
        return _load_privacy_locked()


def load_retention_days() -> int:
    return load_privacy_settings()["retention_days"]


def _retention_changes_locked(days: int, current: datetime) -> tuple[list[str], list[dict]]:
    lines = _migrate_history_locked()
    if days == 0:
        return lines, []
    cutoff = current.astimezone(timezone.utc).timestamp() - days * 86400
    kept = []
    removed = []
    for line in lines:
        entry = _parse_history_line(line)
        timestamp = _parse_timestamp(entry.get("timestamp")) if entry else None
        if entry is None:
            removed.append({})
        elif timestamp is None or timestamp.timestamp() < cutoff:
            removed.append(entry)
        else:
            kept.append(line)
    return kept, removed


def apply_retention(days: int | None = None, now: datetime | None = None) -> int:
    current = now or datetime.now(timezone.utc)
    if current.tzinfo is None:
        current = current.replace(tzinfo=timezone.utc)
    with _history_lock:
        if days is None:
            days = _load_privacy_locked()["retention_days"]
        if isinstance(days, bool) or days not in RETENTION_DAYS:
            raise ValueError("days must be one of 0, 1, 7, 30, or 90")
        if days == 0:
            return 0
        kept, removed = _retention_changes_locked(days, current)
        if removed:
            staged = _commit_history_with_staged_audio(removed, kept)
            _finalize_staged_audio(staged)
            _refresh_suggestions_without_stale_evidence(kept)
    return len(removed)


def set_retention(days: int, now: datetime | None = None) -> int:
    if isinstance(days, bool) or days not in RETENTION_DAYS:
        raise ValueError("days must be one of 0, 1, 7, 30, or 90")
    current = now or datetime.now(timezone.utc)
    if current.tzinfo is None:
        current = current.replace(tzinfo=timezone.utc)
    with _history_lock:
        settings = _load_privacy_locked()
        settings["retention_days"] = days
        return _update_privacy_locked(settings, current)["pruned"]


def update_privacy_settings(payload: object, now: datetime | None = None) -> dict:
    settings = _validated_privacy(payload)
    current = now or datetime.now(timezone.utc)
    if current.tzinfo is None:
        current = current.replace(tzinfo=timezone.utc)
    with _history_lock:
        return _update_privacy_locked(settings, current)


def _update_privacy_locked(settings: dict, current: datetime) -> dict:
    kept, removed = _retention_changes_locked(settings["retention_days"], current)
    existed = common.PRIVACY_PATH.exists()
    previous = common.PRIVACY_PATH.read_text(encoding="utf-8") if existed else ""
    _persist_privacy_locked(settings)
    try:
        if removed:
            staged = _commit_history_with_staged_audio(removed, kept)
    except Exception:
        if existed:
            common._atomic_write(common.PRIVACY_PATH, previous)
        else:
            try:
                common.PRIVACY_PATH.unlink()
            except FileNotFoundError:
                pass
        raise
    if removed:
        _finalize_staged_audio(staged)
        _refresh_suggestions_without_stale_evidence(kept)
    return {**settings, "pruned": len(removed)}


def delete_all_history() -> None:
    """Remove Tiro history monotonically; retries finish any partial cleanup."""
    with _history_lock:
        common._atomic_write(common.HISTORY_PATH, "")
        failures = []
        backup = common.HISTORY_PATH.with_name(common.HISTORY_PATH.name + ".bak")
        try:
            backup.unlink()
        except FileNotFoundError:
            pass
        except OSError as exc:
            failures.append(exc)

        for audio_directory in (common.AUDIO_DIR, common.TRANSIENT_AUDIO_DIR):
            if not audio_directory.exists():
                continue
            for directory, names, files in os.walk(audio_directory, topdown=False):
                folder = Path(directory)
                for name in files:
                    try:
                        (folder / name).unlink()
                    except FileNotFoundError:
                        pass
                    except OSError as exc:
                        failures.append(exc)
                for name in names:
                    child = folder / name
                    try:
                        child.unlink() if child.is_symlink() else child.rmdir()
                    except FileNotFoundError:
                        pass
                    except OSError as exc:
                        failures.append(exc)

        try:
            with _state_lock:
                common._atomic_write(
                    common.SUGGESTIONS_PATH,
                    '{"version":1,"suggestions":[]}\n',
                )
        except OSError as exc:
            failures.append(exc)
        if failures:
            raise failures[0]
