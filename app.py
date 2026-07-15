from __future__ import annotations

import base64
import binascii
import difflib
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
import traceback
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
PROFILES_PATH = DATA_DIR / "profiles.json"
SUGGESTIONS_PATH = DATA_DIR / "suggestions.json"
MODEL_CACHE = ROOT / ".cache" / "huggingface"


def _log_exception(context: str, exc: Exception) -> None:
    print(f"{context}: {exc!r}", flush=True)
    traceback.print_exc()
MODEL_HUB_CACHE = MODEL_CACHE / "hub"
SAMPLE_RATE = 16_000
MAX_RECORDING_BYTES = 100 * 1024 * 1024
API_VERSION = 5
MAX_JSON_BODY_BYTES = 16 * 1024
MAX_ORIGIN_BUNDLE_ID = 255
MAX_ORIGIN_APP_NAME = 200
MAX_VOCABULARY_ENTRIES = 500
MAX_PROFILES = 200
MAX_HISTORY_LIMIT = 200
DEFAULT_HISTORY_LIMIT = 20
MAX_COMPARISON_MODELS = 3
RETENTION_DAYS = {0, 7, 30, 90}
HISTORY_ID_NAMESPACE = uuid.UUID("99bb23a4-4c7b-4d82-85aa-a33a072950f7")
SUGGESTION_ID_NAMESPACE = uuid.UUID("ad2d6d17-a3ef-49df-bbd5-ed73ad9b81cb")
STAGED_AUDIO_PREFIX = ".tiro-delete-"

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

_model = None
_model_id: str | None = None
_operation_lock = threading.Lock()
_history_lock = threading.Lock()
_state_lock = threading.RLock()
_model_download_lock = threading.Lock()
_model_downloads: dict[str, dict[str, object]] = {}
_comparison_registry_lock = threading.Lock()
_comparison_run_lock = threading.Lock()
_comparison_cancellations: dict[str, threading.Event] = {}
_pending_comparison_cancellations: dict[str, float] = {}


def _validated_entries(value: object, *, strict: bool = False) -> list[dict[str, str]]:
    if not isinstance(value, list):
        if strict:
            raise ValueError("entries must be an array")
        return []
    if len(value) > MAX_VOCABULARY_ENTRIES:
        if strict:
            raise ValueError(f"entries may contain at most {MAX_VOCABULARY_ENTRIES} rules")
        value = value[:MAX_VOCABULARY_ENTRIES]
    result = []
    for entry in value:
        valid = (
            isinstance(entry, dict)
            and isinstance(entry.get("spoken"), str)
            and isinstance(entry.get("written"), str)
            and bool(entry["spoken"].strip())
            and bool(entry["written"].strip())
            and len(entry["spoken"]) <= 200
            and len(entry["written"]) <= 500
        )
        if not valid:
            if strict:
                raise ValueError("each entry needs bounded non-empty spoken and written strings")
            continue
        result.append({"spoken": entry["spoken"].strip(), "written": entry["written"].strip()})
    return result


def load_vocabulary() -> list[dict[str, str]]:
    try:
        payload = json.loads(VOCABULARY_PATH.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return []
    entries = payload.get("entries", []) if isinstance(payload, dict) else []
    return _validated_entries(entries)


def _load_vocabulary_document_strict() -> tuple[dict, list[dict[str, str]]]:
    try:
        payload = json.loads(VOCABULARY_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        payload = {"entries": []}
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError("vocabulary file is malformed; repair it before accepting") from exc
    if not isinstance(payload, dict):
        raise ValueError("vocabulary file must contain an object")
    entries = _validated_entries(payload.get("entries"), strict=True)
    return dict(payload), entries


def load_profiles() -> dict:
    try:
        payload = json.loads(PROFILES_PATH.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return {"version": 1, "profiles": []}
    if not isinstance(payload, dict) or payload.get("version") != 1:
        return {"version": 1, "profiles": []}
    profiles = payload.get("profiles")
    if not isinstance(profiles, list):
        return {"version": 1, "profiles": []}
    valid = []
    for profile in profiles[:MAX_PROFILES]:
        if not isinstance(profile, dict):
            continue
        bundle_id = profile.get("bundle_id")
        name = profile.get("name")
        if (
            not isinstance(bundle_id, str)
            or not bundle_id.strip()
            or len(bundle_id) > MAX_ORIGIN_BUNDLE_ID
            or not isinstance(name, str)
            or len(name) > MAX_ORIGIN_APP_NAME
            or not isinstance(profile.get("entries"), list)
        ):
            continue
        entries = _validated_entries(profile.get("entries"))
        valid.append({"bundle_id": bundle_id.strip(), "name": name.strip(), "entries": entries})
    return {"version": 1, "profiles": valid}


def _load_profiles_strict() -> dict:
    try:
        payload = json.loads(PROFILES_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"version": 1, "profiles": []}
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError("profiles file is malformed; repair it before accepting") from exc
    return validate_profiles(payload)


def validate_profiles(payload: object) -> dict:
    if not isinstance(payload, dict) or payload.get("version") != 1:
        raise ValueError("profiles document version must be 1")
    profiles = payload.get("profiles")
    if not isinstance(profiles, list) or len(profiles) > MAX_PROFILES:
        raise ValueError(f"profiles must be an array of at most {MAX_PROFILES} items")
    result = []
    for profile in profiles:
        if not isinstance(profile, dict):
            raise ValueError("each profile must be an object")
        bundle_id = profile.get("bundle_id")
        name = profile.get("name")
        if not isinstance(bundle_id, str) or not bundle_id.strip() or len(bundle_id) > MAX_ORIGIN_BUNDLE_ID:
            raise ValueError("bundle_id must be a bounded non-empty string")
        if not isinstance(name, str) or len(name) > MAX_ORIGIN_APP_NAME:
            raise ValueError("name must be a bounded string")
        result.append({
            "bundle_id": bundle_id.strip(),
            "name": name.strip(),
            "entries": _validated_entries(profile.get("entries"), strict=True),
        })
    return {"version": 1, "profiles": result}


def save_profiles(payload: object) -> dict:
    document = validate_profiles(payload)
    with _state_lock:
        _atomic_write(PROFILES_PATH, json.dumps(document, ensure_ascii=False, separators=(",", ":")) + "\n")
    return document


def vocabulary_for_origin(bundle_id: str | None) -> list[dict[str, str]]:
    global_entries = load_vocabulary()
    if not bundle_id:
        return global_entries
    matching = [profile for profile in load_profiles()["profiles"] if profile["bundle_id"] == bundle_id]
    if not matching:
        return global_entries
    profile_entries = matching[-1]["entries"]
    overridden = {entry["spoken"].casefold() for entry in profile_entries}
    return [entry for entry in global_entries if entry["spoken"].casefold() not in overridden] + profile_entries


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


def _origin_header(value: str | None, maximum: int, label: str) -> str | None:
    if value is None or not value.strip():
        return None
    value = value.strip()
    if len(value) > maximum:
        raise ValueError(f"{label} exceeds {maximum} characters")
    return value


def _word_tokens(text: str) -> list[str]:
    return re.findall(r"[^\W_]+(?:['’][^\W_]+)*", text, flags=re.UNICODE)


def _bounded_history_origin(value: object, maximum: int) -> str:
    if not isinstance(value, str):
        return ""
    value = value.strip()
    return value if value and len(value) <= maximum else ""


def _suggestion_candidate(entry: dict, corrected_text: str) -> dict | None:
    delivered = entry.get("text")
    if not isinstance(delivered, str):
        return None
    before = _word_tokens(delivered)
    after = _word_tokens(corrected_text)
    if not before or not after:
        return None
    matcher = difflib.SequenceMatcher(
        None, [word.casefold() for word in before], [word.casefold() for word in after]
    )
    changes = [opcode for opcode in matcher.get_opcodes() if opcode[0] != "equal"]
    if len(changes) != 1 or changes[0][0] != "replace":
        return None
    _, old_start, old_end, new_start, new_end = changes[0]
    old_words = before[old_start:old_end]
    new_words = after[new_start:new_end]
    if not (1 <= len(old_words) <= 3 and 1 <= len(new_words) <= 3):
        return None
    changed_words = max(len(old_words), len(new_words))
    if changed_words > 1 and changed_words * 2 > max(len(before), len(after)):
        return None
    folded_old = [word.casefold() for word in old_words]
    occurrences = sum(
        [word.casefold() for word in before][index:index + len(folded_old)] == folded_old
        for index in range(len(before) - len(folded_old) + 1)
    )
    if occurrences != 1:
        return None
    spoken_words = old_words
    raw_text = entry.get("raw_text")
    if isinstance(raw_text, str) and raw_text != delivered:
        raw_words = _word_tokens(raw_text)
        raw_to_delivered = difflib.SequenceMatcher(
            None,
            [word.casefold() for word in raw_words],
            [word.casefold() for word in before],
        )
        mapped = [
            raw_words[raw_start:raw_end]
            for tag, raw_start, raw_end, delivered_start, delivered_end
            in raw_to_delivered.get_opcodes()
            if tag == "replace"
            and delivered_start == old_start
            and delivered_end == old_end
            and 1 <= raw_end - raw_start <= 3
        ]
        if len(mapped) == 1:
            spoken_words = mapped[0]
    spoken = " ".join(spoken_words)
    written = " ".join(new_words)
    if len(spoken) > 100 or len(written) > 100:
        return None
    bundle_id = _bounded_history_origin(
        entry.get("origin_bundle_id"), MAX_ORIGIN_BUNDLE_ID
    )
    app_name = _bounded_history_origin(
        entry.get("origin_app_name"), MAX_ORIGIN_APP_NAME
    )
    return {
        "spoken": spoken,
        "written": written,
        "origin_bundle_id": bundle_id,
        "origin_app_name": app_name,
    }


def _candidate_is_covered(candidate: dict) -> bool:
    spoken = candidate["spoken"].casefold()
    written = candidate["written"].casefold()
    return any(
        rule["spoken"].casefold() == spoken
        and rule["written"].casefold() == written
        for rule in vocabulary_for_origin(candidate["origin_bundle_id"] or None)
    )


def _suggestion_id(candidate: dict) -> str:
    framed = json.dumps(
        [
            candidate["spoken"].casefold(),
            candidate["written"].casefold(),
            candidate["origin_bundle_id"],
        ],
        ensure_ascii=False,
        separators=(",", ":"),
    )
    return str(uuid.uuid5(SUGGESTION_ID_NAMESPACE, framed))


def _load_suggestions_locked() -> dict:
    try:
        payload = json.loads(SUGGESTIONS_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"version": 1, "suggestions": []}
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError("suggestions file is malformed; repair it before continuing") from exc
    if not isinstance(payload, dict) or payload.get("version") != 1:
        raise ValueError("suggestions document version must be 1")
    suggestions = payload.get("suggestions")
    if not isinstance(suggestions, list):
        raise ValueError("suggestions must be an array")
    valid = []
    for suggestion in suggestions:
        if not isinstance(suggestion, dict):
            raise ValueError("each suggestion must be an object")
        ids = suggestion.get("transcription_ids")
        if (
            not isinstance(suggestion.get("id"), str)
            or not suggestion["id"]
            or len(suggestion["id"]) > 200
            or not isinstance(suggestion.get("spoken"), str)
            or not suggestion["spoken"]
            or len(suggestion["spoken"]) > 100
            or not isinstance(suggestion.get("written"), str)
            or not suggestion["written"]
            or len(suggestion["written"]) > 100
            or not isinstance(suggestion.get("origin_bundle_id"), str)
            or len(suggestion["origin_bundle_id"]) > MAX_ORIGIN_BUNDLE_ID
            or not isinstance(suggestion.get("origin_app_name", ""), str)
            or len(suggestion.get("origin_app_name", "")) > MAX_ORIGIN_APP_NAME
            or not isinstance(ids, list)
            or len(ids) > 1000
            or any(
                not isinstance(value, str) or not value or len(value) > 200
                for value in ids
            )
        ):
            raise ValueError("suggestions file contains an invalid suggestion")
        accepted = suggestion.get("accepted", False)
        dismissed = suggestion.get("dismissed", False)
        accepted_scope = suggestion.get("accepted_scope")
        accepting_scope = suggestion.get("accepting_scope")
        if (
            not isinstance(accepted, bool)
            or not isinstance(dismissed, bool)
            or accepted and dismissed
            or accepted_scope is not None and accepted_scope not in {"global", "profile"}
            or accepting_scope is not None and accepting_scope not in {"global", "profile"}
            or accepted and accepted_scope is None
            or not accepted and accepted_scope is not None
            or (accepted or dismissed) and accepting_scope is not None
        ):
            raise ValueError("suggestions file contains an invalid terminal decision")
        clean_ids = list(dict.fromkeys(ids))
        clean = dict(suggestion)
        clean["origin_app_name"] = suggestion.get("origin_app_name", "")
        clean["transcription_ids"] = clean_ids
        clean["count"] = len(clean_ids)
        valid.append(clean)
    return {"version": 1, "suggestions": valid}


def _save_suggestions_locked(document: dict) -> None:
    _atomic_write(
        SUGGESTIONS_PATH,
        json.dumps(document, ensure_ascii=False, separators=(",", ":")) + "\n",
    )


def _reconcile_suggestions_locked(lines: list[str]) -> dict:
    previous = _load_suggestions_locked()
    decisions = {
        suggestion["id"]: suggestion
        for suggestion in previous["suggestions"]
        if suggestion.get("accepted")
        or suggestion.get("dismissed")
        or suggestion.get("accepting_scope")
    }
    evidence: dict[str, dict] = {}
    for line in lines:
        entry = _parse_history_line(line)
        if (
            entry is None
            or not isinstance(entry.get("id"), str)
            or not isinstance(entry.get("corrected_text"), str)
        ):
            continue
        candidate = _suggestion_candidate(entry, entry["corrected_text"])
        if candidate is None:
            continue
        suggestion_id = _suggestion_id(candidate)
        suggestion = evidence.setdefault(
            suggestion_id,
            {
                "id": suggestion_id,
                **candidate,
                "transcription_ids": [],
                "accepted": False,
                "dismissed": False,
            },
        )
        suggestion["transcription_ids"].append(entry["id"])

    reconciled = []
    for suggestion in evidence.values():
        suggestion["transcription_ids"] = list(
            dict.fromkeys(suggestion["transcription_ids"])
        )[:1000]
        suggestion["count"] = len(suggestion["transcription_ids"])
        if suggestion["id"] in decisions:
            decision = decisions.pop(suggestion["id"])
            suggestion["accepted"] = bool(decision.get("accepted"))
            suggestion["dismissed"] = bool(decision.get("dismissed"))
            if "accepted_scope" in decision:
                suggestion["accepted_scope"] = decision["accepted_scope"]
            if "accepting_scope" in decision:
                suggestion["accepting_scope"] = decision["accepting_scope"]
        reconciled.append(suggestion)
    for decision in decisions.values():
        decision = dict(decision)
        decision["transcription_ids"] = []
        decision["count"] = 0
        reconciled.append(decision)
    document = {"version": 1, "suggestions": reconciled}
    _save_suggestions_locked(document)
    return document


def _refresh_suggestions_after_history_locked(lines: list[str]) -> None:
    try:
        with _state_lock:
            _reconcile_suggestions_locked(lines)
    except (OSError, ValueError) as exc:
        print(f"Suggestion cache refresh deferred: {exc!r}", flush=True)


def get_suggestions() -> list[dict]:
    with _history_lock:
        lines = _migrate_history_locked()
        with _state_lock:
            suggestions = _reconcile_suggestions_locked(lines)["suggestions"]
    visible = []
    for suggestion in suggestions:
        if (
            suggestion["count"] < 2
            or suggestion.get("accepted")
            or suggestion.get("dismissed")
            or _candidate_is_covered(suggestion)
        ):
            continue
        public = {
            key: value
            for key, value in suggestion.items()
            if key != "transcription_ids"
        }
        public["origin_bundle_id"] = public["origin_bundle_id"] or None
        public["origin_app_name"] = public.get("origin_app_name") or None
        visible.append(public)
    return visible


def correct_history_entry(entry_id: str, corrected_text: str) -> bool:
    with _history_lock:
        lines = _migrate_history_locked()
        updated_lines = list(lines)
        matched = None
        for index, line in enumerate(lines):
            entry = _parse_history_line(line)
            if entry is None or entry.get("id") != entry_id:
                continue
            matched = dict(entry)
            matched["corrected_text"] = corrected_text
            updated_lines[index] = _serialize_entry(matched, line)
            break
        if matched is None:
            return False
        _atomic_write(HISTORY_PATH, "".join(updated_lines))
        _refresh_suggestions_after_history_locked(updated_lines)
    return True


def _replace_rule(entries: list[dict[str, str]], spoken: str, written: str) -> list[dict[str, str]]:
    normalized = spoken.casefold()
    replacing = any(entry["spoken"].casefold() == normalized for entry in entries)
    if not replacing and len(entries) >= MAX_VOCABULARY_ENTRIES:
        raise ValueError(
            f"vocabulary capacity is {MAX_VOCABULARY_ENTRIES} rules"
        )
    return [entry for entry in entries if entry["spoken"].casefold() != normalized] + [
        {"spoken": spoken, "written": written}
    ]


def _prepare_suggestion_acceptance(suggestion: dict, scope: str) -> tuple[Path, str]:
    if scope == "global":
        vocabulary, entries = _load_vocabulary_document_strict()
        vocabulary["entries"] = _replace_rule(
            entries, suggestion["spoken"], suggestion["written"]
        )
        return VOCABULARY_PATH, json.dumps(
            vocabulary, ensure_ascii=False, separators=(",", ":")
        ) + "\n"

    bundle_id = _bounded_history_origin(
        suggestion.get("origin_bundle_id"), MAX_ORIGIN_BUNDLE_ID
    )
    if not bundle_id:
        raise ValueError("profile scope requires a valid origin bundle ID")
    app_name = _bounded_history_origin(
        suggestion.get("origin_app_name"), MAX_ORIGIN_APP_NAME
    )
    profiles = _load_profiles_strict()
    matching_index = next(
        (
            index
            for index in range(len(profiles["profiles"]) - 1, -1, -1)
            if profiles["profiles"][index]["bundle_id"] == bundle_id
        ),
        None,
    )
    if matching_index is None:
        if len(profiles["profiles"]) >= MAX_PROFILES:
            raise ValueError(f"profile capacity is {MAX_PROFILES} profiles")
        profiles["profiles"].append(
            {"bundle_id": bundle_id, "name": app_name, "entries": []}
        )
        matching_index = len(profiles["profiles"]) - 1
    profile = profiles["profiles"][matching_index]
    profile["entries"] = _replace_rule(
        profile["entries"], suggestion["spoken"], suggestion["written"]
    )
    profiles = validate_profiles(profiles)
    return PROFILES_PATH, json.dumps(
        profiles, ensure_ascii=False, separators=(",", ":")
    ) + "\n"


def accept_suggestion(suggestion_id: str, scope: str) -> str | None:
    with _state_lock:
        document = _load_suggestions_locked()
        suggestion = next(
            (item for item in document["suggestions"] if item["id"] == suggestion_id),
            None,
        )
        if suggestion is None:
            return None
        if suggestion.get("dismissed"):
            raise ValueError("suggestion is already dismissed")
        if suggestion.get("accepted"):
            return suggestion.get("accepted_scope", scope)
        intended_scope = suggestion.get("accepting_scope") or scope
        if not suggestion.get("accepting_scope") and suggestion["count"] < 2:
            return None
        target, content = _prepare_suggestion_acceptance(suggestion, intended_scope)
        if not suggestion.get("accepting_scope"):
            suggestion["accepting_scope"] = intended_scope
            _save_suggestions_locked(document)
        _atomic_write(target, content)
        suggestion["accepted"] = True
        suggestion["dismissed"] = False
        suggestion["accepted_scope"] = intended_scope
        suggestion.pop("accepting_scope", None)
        _save_suggestions_locked(document)
    return intended_scope


def dismiss_suggestion(suggestion_id: str) -> bool:
    with _state_lock:
        document = _load_suggestions_locked()
        suggestion = next(
            (item for item in document["suggestions"] if item["id"] == suggestion_id),
            None,
        )
        if suggestion is None:
            return False
        if suggestion.get("accepted"):
            raise ValueError("suggestion is already accepted")
        if suggestion.get("accepting_scope"):
            raise ValueError("suggestion acceptance is already pending")
        if suggestion.get("dismissed"):
            return True
        suggestion["dismissed"] = True
        _save_suggestions_locked(document)
    return True


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
            _refresh_suggestions_after_history_locked(kept)
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


def _model_key(value: object) -> str:
    if not isinstance(value, str) or value not in MODELS:
        raise ValueError("model must be a canonical model key")
    return value


def _model_cache_info():
    from huggingface_hub import scan_cache_dir
    from huggingface_hub.errors import CacheNotFound

    try:
        return scan_cache_dir(MODEL_HUB_CACHE)
    except CacheNotFound:
        return None


def _cached_models(cache_info=None) -> dict[str, dict[str, object]]:
    if cache_info is None:
        cache_info = _model_cache_info()
    by_repo = {
        repo.repo_id: repo
        for repo in (cache_info.repos if cache_info is not None else ())
        if getattr(repo, "repo_type", "model") == "model"
    }
    result = {}
    for key, model in MODELS.items():
        repo = by_repo.get(model["id"])
        revisions = list(repo.revisions) if repo is not None else []
        revision = max(
            revisions,
            key=lambda item: (getattr(item, "last_modified", 0), item.commit_hash),
            default=None,
        )
        result[key] = {
            "repo": repo,
            "revision": revision,
            "installed": revision is not None,
            "installed_size_bytes": int(repo.size_on_disk) if repo is not None else 0,
            "snapshot_path": Path(revision.snapshot_path) if revision is not None else None,
        }
    return result


def model_status() -> list[dict[str, object]]:
    cached = _cached_models()
    with _model_download_lock:
        downloads = {key: dict(value) for key, value in _model_downloads.items()}
    result = []
    for key, model in MODELS.items():
        installed = bool(cached[key]["installed"])
        download = downloads.get(key, {})
        downloading = bool(download.get("downloading"))
        deleting = bool(download.get("deleting"))
        state = (
            "downloading" if downloading
            else "deleting" if deleting
            else "installed" if installed
            else "available"
        )
        if download.get("error") and not installed:
            state = "error"
        result.append({
            "key": key,
            **model,
            "installed": installed,
            "downloading": downloading,
            "deleting": deleting,
            "state": state,
            "size_bytes": cached[key]["installed_size_bytes"]
            or model["download_size_bytes"],
            "installed_size_bytes": cached[key]["installed_size_bytes"],
            "loaded": _model_id == model["id"],
        })
    return result


def download_model(model_key: str) -> bool:
    model_key = _model_key(model_key)
    with _model_download_lock:
        state = _model_downloads.get(model_key, {})
        if state.get("downloading") or state.get("deleting"):
            raise HTTPError(HTTPStatus.CONFLICT, "Model operation is already running")
        if _cached_models()[model_key]["installed"]:
            return False
        _model_downloads[model_key] = {
            "downloading": True,
            "deleting": False,
            "error": None,
        }
    try:
        from huggingface_hub import snapshot_download

        MODEL_HUB_CACHE.mkdir(parents=True, exist_ok=True)
        snapshot_download(
            repo_id=MODELS[model_key]["id"],
            cache_dir=MODEL_HUB_CACHE,
        )
    except Exception as exc:
        _log_exception(f"Model download failed for {model_key}", exc)
        with _model_download_lock:
            _model_downloads[model_key] = {
                "downloading": False,
                "deleting": False,
                "error": str(exc)[:500] or type(exc).__name__,
            }
        raise
    else:
        with _model_download_lock:
            _model_downloads[model_key] = {
                "downloading": False,
                "deleting": False,
                "error": None,
            }
        return True


def delete_model(model_key: str) -> int:
    model_key = _model_key(model_key)
    selected = MODELS[model_key]
    with _model_download_lock:
        state = _model_downloads.get(model_key, {})
        if state.get("downloading") or state.get("deleting"):
            raise HTTPError(HTTPStatus.CONFLICT, "Model operation is already running")
        _model_downloads[model_key] = {
            "downloading": False,
            "deleting": True,
            "error": None,
        }
    try:
        with _operation_lock:
            if _model_id == selected["id"]:
                raise HTTPError(HTTPStatus.CONFLICT, "Cannot delete the loaded model")
            cache_info = _model_cache_info()
            cached = _cached_models(cache_info)[model_key]
            repo = cached["repo"]
            if repo is None or cache_info is None:
                return 0
            strategy = cache_info.delete_revisions(
                *(revision.commit_hash for revision in repo.revisions)
            )
            freed = int(strategy.expected_freed_size)
            strategy.execute()
            return freed
    finally:
        with _model_download_lock:
            _model_downloads[model_key] = {
                "downloading": False,
                "deleting": False,
                "error": None,
            }


def _history_audio(entry_id: str) -> bytes | None:
    with _history_lock:
        lines = _read_history_lines()
        for line in reversed(lines):
            entry = _parse_history_line(line)
            if entry is None or entry.get("id") != entry_id:
                continue
            audio_path = _audio_path(entry)
            if audio_path is None or not audio_path.is_file():
                return None
            return audio_path.read_bytes()
    return None


def _installed_model_snapshots(model_keys: list[str]) -> dict[str, Path]:
    with _model_download_lock:
        busy = [
            key for key in model_keys
            if _model_downloads.get(key, {}).get("downloading")
            or _model_downloads.get(key, {}).get("deleting")
        ]
        if busy:
            raise HTTPError(
                HTTPStatus.CONFLICT,
                "Model operation is already running: " + ", ".join(busy),
            )
        cached = _cached_models()
        missing = [key for key in model_keys if not cached[key]["installed"]]
        if missing:
            raise HTTPError(
                HTTPStatus.CONFLICT,
                "Models must be installed before use: " + ", ".join(missing),
            )
        return {key: cached[key]["snapshot_path"] for key in model_keys}


def _clear_loaded_model() -> None:
    global _model, _model_id
    if _model is None:
        _model_id = None
        return
    _model = None
    _model_id = None
    gc.collect()
    import mlx.core as mx

    mx.clear_cache()


def _restore_loaded_model(model, model_id: str | None) -> None:
    global _model, _model_id
    if _model is model and _model_id == model_id:
        return
    try:
        _clear_loaded_model()
    finally:
        _model = model
        _model_id = model_id


def _load_model(model_key: str, source: str | Path):
    global _model, _model_id
    if model_key not in MODELS:
        raise ValueError(f"Unknown transcription model: {model_key}")
    selected = MODELS[model_key]
    wanted_id = selected["id"]
    load_source = str(Path(source))

    if _model is None or _model_id != wanted_id:
        _clear_loaded_model()
        if selected["backend"] == "qwen":
            from mlx_audio.stt import load

            _model = load(load_source)
        else:
            from parakeet_mlx import from_pretrained

            _model = from_pretrained(load_source, cache_dir=str(MODEL_HUB_CACHE))
        _model_id = wanted_id
    return _model, selected


def _generate_transcript(samples: array, model_key: str, source: str | Path) -> str:
    model, selected = _load_model(model_key, source)
    import mlx.core as mx

    audio = mx.array(samples, dtype=mx.float32) / 32768.0
    if selected["backend"] == "qwen":
        result = model.generate(audio, language="English")
    else:
        from parakeet_mlx.audio import get_logmel

        mel = get_logmel(audio, model.preprocessor_config)
        result = model.generate(mel)[0]
    return result.text.strip()


def preload_model(model_key: str) -> dict[str, str]:
    model_key = _model_key(model_key)
    with _operation_lock:
        source = _installed_model_snapshots([model_key])[model_key]
        _, selected = _load_model(model_key, source)
    return {"loaded_model": selected["id"]}


def compare_history_models(
    entry_id: str,
    model_keys: list[str],
    cancellation: threading.Event | None = None,
) -> dict:
    if not isinstance(entry_id, str) or not entry_id or len(entry_id) > 200:
        raise ValueError("history_id must be a bounded non-empty string")
    if (
        not isinstance(model_keys, list)
        or not 2 <= len(model_keys) <= MAX_COMPARISON_MODELS
        or any(not isinstance(key, str) for key in model_keys)
        or len(set(model_keys)) != len(model_keys)
    ):
        raise ValueError(
            f"models must contain 2 to {MAX_COMPARISON_MODELS} unique model keys"
        )
    model_keys = [_model_key(key) for key in model_keys]
    wav_bytes = _history_audio(entry_id)
    if wav_bytes is None:
        raise HTTPError(HTTPStatus.NOT_FOUND, "History audio not found")
    samples = decode_pcm_wav(wav_bytes)

    _installed_model_snapshots(model_keys)
    with _comparison_run_lock:
        with _operation_lock:
            restore_model, restore_model_id = _model, _model_id
        expected_model, expected_model_id = restore_model, restore_model_id
        results = []
        try:
            for index, key in enumerate(model_keys):
                if cancellation is not None and cancellation.is_set():
                    raise HTTPError(HTTPStatus.CONFLICT, "Model comparison was cancelled")
                started = time.perf_counter()
                with _operation_lock:
                    if cancellation is not None and cancellation.is_set():
                        raise HTTPError(HTTPStatus.CONFLICT, "Model comparison was cancelled")
                    if _model is not expected_model or _model_id != expected_model_id:
                        restore_model, restore_model_id = _model, _model_id
                    source = _installed_model_snapshots([key])[key]
                    try:
                        text = _generate_transcript(samples, key, source)
                    finally:
                        expected_model, expected_model_id = _model, _model_id
                results.append(
                    {
                        "key": key,
                        "id": MODELS[key]["id"],
                        "text": text,
                        "transcription_seconds": round(time.perf_counter() - started, 3),
                    }
                )
                if cancellation is not None and cancellation.is_set():
                    raise HTTPError(HTTPStatus.CONFLICT, "Model comparison was cancelled")
                if index + 1 < len(model_keys):
                    time.sleep(0.001)
        finally:
            with _operation_lock:
                if _model is not expected_model or _model_id != expected_model_id:
                    restore_model, restore_model_id = _model, _model_id
                _restore_loaded_model(restore_model, restore_model_id)
    return {"history_id": entry_id, "results": results}


def transcribe(
    wav_bytes: bytes,
    model_key: str,
    origin_bundle_id: str | None = None,
    origin_app_name: str | None = None,
) -> dict:
    samples = decode_pcm_wav(wav_bytes)

    started = time.perf_counter()
    with _operation_lock:
        model_key = _model_key(model_key)
        source = _installed_model_snapshots([model_key])[model_key]
        raw_text = _generate_transcript(samples, model_key, source)
        selected = MODELS[model_key]
    elapsed = time.perf_counter() - started

    AUDIO_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    audio_path = AUDIO_DIR / f"{stamp}.wav"
    audio_path.write_bytes(wav_bytes)
    entry = {
        "id": str(uuid.uuid4()),
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "model": selected["id"],
        "audio_file": str(audio_path.relative_to(ROOT)),
        "transcription_seconds": round(elapsed, 3),
        "text": apply_vocabulary(raw_text, vocabulary_for_origin(origin_bundle_id)),
    }
    if origin_bundle_id:
        entry["origin_bundle_id"] = origin_bundle_id
    if origin_app_name:
        entry["origin_app_name"] = origin_app_name
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
        if path == "/api/models":
            if not self._authorized():
                json_response(self, {"error": "Forbidden"}, HTTPStatus.FORBIDDEN)
                return
            try:
                json_response(self, {"models": model_status()})
            except Exception as exc:
                _log_exception("Model status failed", exc)
                json_response(
                    self,
                    {"error": "Could not inspect the local model cache."},
                    HTTPStatus.INTERNAL_SERVER_ERROR,
                )
            return
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
        if path == "/api/vocabulary/profiles":
            with _state_lock:
                json_response(self, load_profiles())
            return
        if path == "/api/suggestions":
            try:
                json_response(self, {"suggestions": get_suggestions()})
            except (OSError, ValueError) as exc:
                print(f"Suggestion state unavailable: {exc!r}", flush=True)
                json_response(
                    self,
                    {"error": "Suggestion state is malformed or unavailable."},
                    HTTPStatus.INTERNAL_SERVER_ERROR,
                )
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

        mutation_paths = {
            "/api/history/delete",
            "/api/history/retention",
            "/api/history/correction",
            "/api/vocabulary/profiles",
            "/api/suggestions/accept",
            "/api/suggestions/dismiss",
            "/api/models/download",
            "/api/models/delete",
            "/api/models/compare",
            "/api/models/compare/cancel",
        }
        if path in mutation_paths:
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
                elif path == "/api/history/retention":
                    days = payload.get("days")
                    if isinstance(days, bool) or not isinstance(days, int):
                        raise ValueError("days must be one of 0, 7, 30, or 90")
                    json_response(self, {"days": days, "pruned": set_retention(days)})
                elif path == "/api/history/correction":
                    entry_id = payload.get("id")
                    corrected_text = payload.get("corrected_text")
                    if not isinstance(entry_id, str) or not entry_id or len(entry_id) > 200:
                        raise ValueError("id must be a bounded non-empty string")
                    if (
                        not isinstance(corrected_text, str)
                        or not corrected_text.strip()
                        or len(corrected_text) > 10_000
                    ):
                        raise ValueError("corrected_text must be a bounded non-empty string")
                    if not correct_history_entry(entry_id, corrected_text):
                        json_response(
                            self,
                            {"error": "History entry not found"},
                            HTTPStatus.NOT_FOUND,
                        )
                        return
                    json_response(self, {"corrected": True})
                elif path == "/api/vocabulary/profiles":
                    json_response(self, save_profiles(payload))
                elif path == "/api/models/download":
                    model_key = _model_key(payload.get("key", payload.get("model")))
                    downloaded = download_model(model_key)
                    json_response(
                        self,
                        {"key": model_key, "downloaded": downloaded},
                    )
                elif path == "/api/models/delete":
                    model_key = _model_key(payload.get("key", payload.get("model")))
                    freed = delete_model(model_key)
                    json_response(
                        self,
                        {"model": model_key, "deleted": freed > 0, "freed_size_bytes": freed},
                    )
                elif path == "/api/models/compare":
                    comparison_id = payload.get("comparison_id")
                    if comparison_id is None:
                        comparison_id = str(uuid.uuid4())
                    if (
                        not isinstance(comparison_id, str)
                        or not comparison_id
                        or len(comparison_id) > 200
                    ):
                        raise ValueError("comparison_id must be a bounded non-empty string")
                    cancellation = threading.Event()
                    with _comparison_registry_lock:
                        if comparison_id in _comparison_cancellations:
                            raise HTTPError(HTTPStatus.CONFLICT, "Comparison is already running")
                        if _pending_comparison_cancellations.pop(comparison_id, None) is not None:
                            cancellation.set()
                        _comparison_cancellations[comparison_id] = cancellation
                    try:
                        response = compare_history_models(
                            payload.get("history_id"),
                            payload.get("model_keys", payload.get("models")),
                            cancellation,
                        )
                    finally:
                        with _comparison_registry_lock:
                            _comparison_cancellations.pop(comparison_id, None)
                    json_response(self, response)
                elif path == "/api/models/compare/cancel":
                    comparison_id = payload.get("comparison_id")
                    if not isinstance(comparison_id, str) or not comparison_id:
                        raise ValueError("comparison_id must be a non-empty string")
                    with _comparison_registry_lock:
                        cancellation = _comparison_cancellations.get(comparison_id)
                        if cancellation is None:
                            now = time.monotonic()
                            _pending_comparison_cancellations[comparison_id] = now
                            expired = [
                                key for key, created in _pending_comparison_cancellations.items()
                                if now - created > 60
                            ]
                            for key in expired:
                                _pending_comparison_cancellations.pop(key, None)
                            while len(_pending_comparison_cancellations) > 100:
                                _pending_comparison_cancellations.pop(
                                    next(iter(_pending_comparison_cancellations))
                                )
                        else:
                            cancellation.set()
                    json_response(self, {"cancelled": True})
                elif path == "/api/suggestions/accept":
                    suggestion_id = payload.get("id")
                    scope = payload.get("scope")
                    if not isinstance(suggestion_id, str) or not suggestion_id:
                        raise ValueError("id must be a non-empty string")
                    if scope not in {"profile", "global"}:
                        raise ValueError("scope must be 'profile' or 'global'")
                    accepted_scope = accept_suggestion(suggestion_id, scope)
                    if not accepted_scope:
                        json_response(
                            self,
                            {"error": "Suggestion not found"},
                            HTTPStatus.NOT_FOUND,
                        )
                        return
                    json_response(
                        self, {"accepted": True, "scope": accepted_scope}
                    )
                else:
                    suggestion_id = payload.get("id")
                    if not isinstance(suggestion_id, str) or not suggestion_id:
                        raise ValueError("id must be a non-empty string")
                    if not dismiss_suggestion(suggestion_id):
                        json_response(
                            self,
                            {"error": "Suggestion not found"},
                            HTTPStatus.NOT_FOUND,
                        )
                        return
                    json_response(self, {"dismissed": True})
            except HTTPError as exc:
                json_response(self, {"error": str(exc)}, exc.status)
            except ValueError as exc:
                json_response(self, {"error": str(exc)}, HTTPStatus.BAD_REQUEST)
            except OSError as exc:
                _log_exception("History or model mutation failed", exc)
                json_response(
                    self,
                    {"error": "History mutation failed."},
                    HTTPStatus.INTERNAL_SERVER_ERROR,
                )
            except Exception as exc:
                _log_exception("Authenticated operation failed", exc)
                json_response(
                    self,
                    {"error": "Authenticated operation failed."},
                    HTTPStatus.INTERNAL_SERVER_ERROR,
                )
            return

        if path == "/api/preload":
            try:
                model_key = self.headers.get("X-Parakeet-Model", "compact")
                json_response(self, preload_model(model_key))
            except HTTPError as exc:
                json_response(self, {"error": str(exc)}, exc.status)
            except ValueError as exc:
                json_response(self, {"error": str(exc)}, HTTPStatus.BAD_REQUEST)
            except Exception as exc:
                _log_exception("Model preload failed", exc)
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
            origin_bundle_id = _origin_header(
                self.headers.get("X-Tiro-Origin-Bundle-ID"),
                MAX_ORIGIN_BUNDLE_ID,
                "X-Tiro-Origin-Bundle-ID",
            )
            origin_app_name = _origin_header(
                self.headers.get("X-Tiro-Origin-App-Name"),
                MAX_ORIGIN_APP_NAME,
                "X-Tiro-Origin-App-Name",
            )
            entry = transcribe(
                self.rfile.read(length), model_key, origin_bundle_id, origin_app_name
            )
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
