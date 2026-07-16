from __future__ import annotations

import difflib
import json
import re
import unicodedata
import uuid
from pathlib import Path

from . import common, storage
from .common import (
    MAX_ORIGIN_APP_NAME,
    MAX_ORIGIN_BUNDLE_ID,
    MAX_PROFILES,
    MAX_SNIPPETS,
    MAX_SNIPPET_CONTENT,
    MAX_VOCABULARY_ENTRIES,
    MODELS,
    PUNCTUATION_MODES,
    QWEN_LANGUAGES,
    SUGGESTION_ID_NAMESPACE,
    TRANSCRIPTION_MODES,
)

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
        payload = json.loads(common.VOCABULARY_PATH.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return []
    entries = payload.get("entries", []) if isinstance(payload, dict) else []
    return _validated_entries(entries)


def _load_vocabulary_document_strict() -> tuple[dict, list[dict[str, str]]]:
    try:
        payload = json.loads(common.VOCABULARY_PATH.read_text(encoding="utf-8"))
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
        payload = json.loads(common.PROFILES_PATH.read_text(encoding="utf-8"))
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
        payload = json.loads(common.PROFILES_PATH.read_text(encoding="utf-8"))
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
    with storage._state_lock:
        common._atomic_write(common.PROFILES_PATH, json.dumps(document, ensure_ascii=False, separators=(",", ":")) + "\n")
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


def _validated_snippets(value: object, *, strict: bool = False) -> list[dict[str, str]]:
    if not isinstance(value, list):
        if strict:
            raise ValueError("snippets must be an array")
        return []
    if len(value) > MAX_SNIPPETS:
        if strict:
            raise ValueError(f"snippets may contain at most {MAX_SNIPPETS} items")
        value = value[:MAX_SNIPPETS]
    snippets = []
    triggers = set()
    ids = set()
    for item in value:
        trigger = item.get("trigger") if isinstance(item, dict) else None
        valid = (
            isinstance(item, dict)
            and isinstance(item.get("id"), str)
            and bool(item["id"].strip())
            and len(item["id"]) <= 200
            and item["id"].strip() not in ids
            and isinstance(trigger, str)
            and bool(trigger.strip())
            and len(trigger) <= 200
            and trigger.strip().casefold() not in triggers
            and isinstance(item.get("content"), str)
            and bool(item["content"].strip())
            and len(item["content"]) <= MAX_SNIPPET_CONTENT
        )
        if not valid:
            if strict:
                raise ValueError("each snippet needs a unique bounded trigger and non-empty id and content")
            continue
        triggers.add(trigger.strip().casefold())
        ids.add(item["id"].strip())
        snippets.append({
            "id": item["id"].strip(),
            "trigger": item["trigger"].strip(),
            "content": item["content"].strip(),
        })
    return snippets


def load_snippets() -> list[dict[str, str]]:
    try:
        payload = json.loads(common.SNIPPETS_PATH.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return []
    if not isinstance(payload, dict) or payload.get("version") != 1:
        return []
    return _validated_snippets(payload.get("snippets"))


def _load_snippets_strict() -> list[dict[str, str]]:
    try:
        payload = json.loads(common.SNIPPETS_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return []
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError("snippets file is malformed; repair it before accepting changes") from exc
    if not isinstance(payload, dict) or payload.get("version") != 1:
        raise ValueError("snippets document version must be 1")
    return _validated_snippets(payload.get("snippets"), strict=True)


def save_snippet(payload: object) -> dict[str, str]:
    if not isinstance(payload, dict):
        raise ValueError("snippet must be an object")
    snippet_id = payload.get("id") or str(uuid.uuid4())
    snippet = _validated_snippets([{
        "id": snippet_id,
        "trigger": payload.get("trigger"),
        "content": payload.get("content"),
    }], strict=True)[0]
    with storage._state_lock:
        snippets = _load_snippets_strict()
        replacing = any(item["id"] == snippet["id"] for item in snippets)
        if not replacing and len(snippets) >= MAX_SNIPPETS:
            raise ValueError(f"snippet capacity is {MAX_SNIPPETS} items")
        snippets = _validated_snippets(
            [item for item in snippets if item["id"] != snippet["id"]] + [snippet],
            strict=True,
        )
        common._atomic_write(common.SNIPPETS_PATH, json.dumps(
            {"version": 1, "snippets": snippets}, ensure_ascii=False, separators=(",", ":")
        ) + "\n")
    return snippet


def delete_snippet(snippet_id: str) -> bool:
    with storage._state_lock:
        snippets = _load_snippets_strict()
        kept = [item for item in snippets if item["id"] != snippet_id]
        if len(kept) == len(snippets):
            return False
        common._atomic_write(common.SNIPPETS_PATH, json.dumps(
            {"version": 1, "snippets": kept}, ensure_ascii=False, separators=(",", ":")
        ) + "\n")
    return True


def apply_snippets(text: str, snippets: list[dict[str, str]]) -> str:
    return apply_vocabulary(text, [
        {"spoken": item["trigger"], "written": item["content"]}
        for item in snippets
    ])


_FORMATTING_COMMANDS = {
    "new paragraph": "\n\n",
    "new line": "\n",
}
_PUNCTUATION_COMMANDS = {
    "question mark": "?",
    "exclamation mark": "!",
    "semicolon": ";",
    "colon": ":",
    "comma": ",",
    "full stop": ".",
    "period": ".",
}


def _without_punctuation(text: str) -> str:
    characters = []
    lexical_punctuation = {"'", "’", "ʼ", "-", "‐", "‑"}
    for index, character in enumerate(text):
        punctuation = unicodedata.category(character).startswith("P")
        inside_word = (
            character in lexical_punctuation
            and index > 0
            and index + 1 < len(text)
            and text[index - 1].isalnum()
            and text[index + 1].isalnum()
        )
        characters.append(" " if punctuation and not inside_word else character)
    return re.sub(r"[ \t]+", " ", "".join(characters)).strip()


def apply_spoken_formatting(text: str, punctuation: str) -> str:
    commands = dict(_FORMATTING_COMMANDS)
    if punctuation == "spoken":
        commands.update(_PUNCTUATION_COMMANDS)
    markers = {}
    for index, (spoken, written) in enumerate(commands.items()):
        marker = f"\x00{index}\x00"
        markers[marker] = written
        text = re.sub(rf"(?<!\w){re.escape(spoken)}(?!\w)", marker, text, flags=re.IGNORECASE)
    if punctuation in {"spoken", "none"}:
        text = _without_punctuation(text)
    for marker, written in markers.items():
        text = text.replace(marker, written)
    text = re.sub(r"[ \t]+([,.;:?!])", r"\1", text)
    text = re.sub(r"([,.;:?!])(?=\w)", r"\1 ", text)
    text = re.sub(r" *\n *", "\n", text)
    return text.strip(" \t\r")


def _transcription_options(
    model_key: str, mode: str, punctuation: str, language: str
) -> tuple[str, str, str]:
    from .models import _model_key

    if mode not in TRANSCRIPTION_MODES:
        raise ValueError("mode must be 'standard' or 'verbatim'")
    if punctuation not in PUNCTUATION_MODES:
        raise ValueError("punctuation must be 'automatic', 'spoken', or 'none'")
    canonical_language = "auto" if language.casefold() == "auto" else next(
        (name for name in QWEN_LANGUAGES if name.casefold() == language.casefold()), None
    )
    if canonical_language is None:
        raise ValueError("language must be 'auto' or a supported language name")
    if MODELS[_model_key(model_key)]["backend"] == "parakeet" and canonical_language not in {"auto", "English"}:
        raise ValueError("Parakeet models support only auto or English language")
    return mode, punctuation, canonical_language


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
        payload = json.loads(common.SUGGESTIONS_PATH.read_text(encoding="utf-8"))
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
    common._atomic_write(
        common.SUGGESTIONS_PATH,
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
        entry = storage._parse_history_line(line)
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
        with storage._state_lock:
            _reconcile_suggestions_locked(lines)
    except (OSError, ValueError) as exc:
        print(f"Suggestion cache refresh deferred: {exc!r}", flush=True)


def get_suggestions() -> list[dict]:
    with storage._history_lock:
        lines = storage._migrate_history_locked()
        with storage._state_lock:
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
    with storage._history_lock:
        lines = storage._migrate_history_locked()
        updated_lines = list(lines)
        matched = None
        for index, line in enumerate(lines):
            entry = storage._parse_history_line(line)
            if entry is None or entry.get("id") != entry_id:
                continue
            matched = dict(entry)
            matched["corrected_text"] = corrected_text
            updated_lines[index] = storage._serialize_entry(matched, line)
            break
        if matched is None:
            return False
        common._atomic_write(common.HISTORY_PATH, "".join(updated_lines))
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
        return common.VOCABULARY_PATH, json.dumps(
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
    return common.PROFILES_PATH, json.dumps(
        profiles, ensure_ascii=False, separators=(",", ":")
    ) + "\n"


def accept_suggestion(suggestion_id: str, scope: str) -> str | None:
    with storage._state_lock:
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
        common._atomic_write(target, content)
        suggestion["accepted"] = True
        suggestion["dismissed"] = False
        suggestion["accepted_scope"] = intended_scope
        suggestion.pop("accepting_scope", None)
        _save_suggestions_locked(document)
    return intended_scope


def dismiss_suggestion(suggestion_id: str) -> bool:
    with storage._state_lock:
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
