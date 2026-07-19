from __future__ import annotations

import json
import math
import uuid
from datetime import datetime, timezone

from . import common, storage, text as text_rules


NATIVE_ENGINES = {
    "coreml-compact": {
        "model_key": "compact",
        "model_id": "parakeet-tdt-ctc-110m-coreml",
    },
}


def _validated_raw_transcript(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("raw_text must be a string")
    if len(value) > common.MAX_TRANSCRIPT_CHARS:
        raise ValueError(
            f"raw_text exceeds {common.MAX_TRANSCRIPT_CHARS} characters"
        )
    return value.strip()


def _validated_transcription_seconds(value: object) -> float:
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
        or value < 0
        or value > common.MAX_TRANSCRIPTION_SECONDS
    ):
        raise ValueError(
            "transcription_seconds must be a finite non-negative number "
            f"no greater than {common.MAX_TRANSCRIPTION_SECONDS}"
        )
    return float(value)


def finalize_transcription(
    *,
    wav_bytes: bytes,
    raw_text: str,
    model_key: str,
    model_id: str,
    transcription_seconds: float,
    origin_bundle_id: str | None = None,
    origin_app_name: str | None = None,
    mode: str = "standard",
    punctuation: str = "automatic",
    language: str = "English",
) -> dict:
    mode, punctuation, language = text_rules._transcription_options(
        model_key, mode, punctuation, language
    )
    origin_bundle_id = text_rules._origin_header(
        origin_bundle_id,
        common.MAX_ORIGIN_BUNDLE_ID,
        "origin_bundle_id",
    )
    origin_app_name = text_rules._origin_header(
        origin_app_name,
        common.MAX_ORIGIN_APP_NAME,
        "origin_app_name",
    )

    delivered_text = raw_text
    if mode == "standard":
        delivered_text = text_rules.apply_spoken_formatting(
            delivered_text, punctuation
        )
        delivered_text = text_rules.apply_vocabulary(
            delivered_text,
            text_rules.vocabulary_for_origin(origin_bundle_id),
        )
        delivered_text = text_rules.apply_snippets(
            delivered_text,
            text_rules.load_snippets(),
        )
    entry = {
        "id": str(uuid.uuid4()),
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "model": model_id,
        "transcription_seconds": round(transcription_seconds, 3),
        "text": delivered_text,
        "mode": mode,
        "punctuation": punctuation,
        "language": language,
    }
    if origin_bundle_id:
        entry["origin_bundle_id"] = origin_bundle_id
    if origin_app_name:
        entry["origin_app_name"] = origin_app_name
    if entry["text"] != raw_text:
        entry["raw_text"] = raw_text

    with storage._history_lock:
        privacy = storage._load_privacy_locked()
        if privacy["store_history"]:
            audio_path = None
            if privacy["store_recordings"]:
                common._ensure_private_directory(common.AUDIO_DIR)
                stamp = datetime.now(timezone.utc).strftime(
                    "%Y%m%dT%H%M%S.%fZ"
                )
                audio_path = common.AUDIO_DIR / f"{stamp}.wav"
                common._write_private_bytes(audio_path, wav_bytes)
                entry["audio_file"] = str(
                    audio_path.relative_to(common.ROOT)
                )
            try:
                common._ensure_private_directory(common.HISTORY_PATH.parent)
                lines = storage._migrate_history_locked()
                prefix = "\n" if lines and not lines[-1].endswith("\n") else ""
                common._append_private_text(
                    common.HISTORY_PATH,
                    prefix + json.dumps(entry, ensure_ascii=False) + "\n",
                )
            except Exception:
                if audio_path is not None:
                    try:
                        audio_path.unlink()
                    except OSError as exc:
                        print(
                            f"Could not remove uncommitted recording: {exc!r}",
                            flush=True,
                        )
                raise
    if privacy["store_history"]:
        try:
            storage.apply_retention()
        except Exception as exc:
            print(
                f"Retention maintenance failed; will retry later: {exc!r}",
                flush=True,
            )
    return entry


def validate_native_transcription(
    *,
    raw_text: str,
    engine: str,
    transcription_seconds: float,
    origin_bundle_id: str | None = None,
    origin_app_name: str | None = None,
    mode: str = "standard",
    punctuation: str = "automatic",
    language: str = "English",
) -> dict[str, object]:
    if not isinstance(engine, str):
        raise ValueError("engine must be a supported native engine")
    selected = NATIVE_ENGINES.get(engine)
    if selected is None:
        raise ValueError("engine must be a supported native engine")
    if not isinstance(mode, str):
        raise ValueError("mode must be a string")
    if not isinstance(punctuation, str):
        raise ValueError("punctuation must be a string")
    if not isinstance(language, str):
        raise ValueError("language must be a string")
    if origin_bundle_id is not None and not isinstance(
        origin_bundle_id, str
    ):
        raise ValueError("origin_bundle_id must be a string")
    if origin_app_name is not None and not isinstance(origin_app_name, str):
        raise ValueError("origin_app_name must be a string")
    raw_text = _validated_raw_transcript(raw_text)
    transcription_seconds = _validated_transcription_seconds(
        transcription_seconds
    )
    mode, punctuation, language = text_rules._transcription_options(
        selected["model_key"], mode, punctuation, language
    )
    origin_bundle_id = text_rules._origin_header(
        origin_bundle_id,
        common.MAX_ORIGIN_BUNDLE_ID,
        "origin_bundle_id",
    )
    origin_app_name = text_rules._origin_header(
        origin_app_name,
        common.MAX_ORIGIN_APP_NAME,
        "origin_app_name",
    )
    return {
        "raw_text": raw_text,
        "model_key": selected["model_key"],
        "model_id": selected["model_id"],
        "transcription_seconds": transcription_seconds,
        "origin_bundle_id": origin_bundle_id,
        "origin_app_name": origin_app_name,
        "mode": mode,
        "punctuation": punctuation,
        "language": language,
    }


def finalize_native_transcription(*, wav_bytes: bytes, **metadata) -> dict:
    validated = validate_native_transcription(**metadata)
    return finalize_transcription(wav_bytes=wav_bytes, **validated)
