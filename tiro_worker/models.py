from __future__ import annotations

import gc
import io
import json
import os
import threading
import time
import uuid
import wave
from array import array
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from http import HTTPStatus
from pathlib import Path

from . import common, storage, text as text_rules
from .parakeet_compat import mlx_mel_filter_as_librosa
from .common import (
    HTTPError,
    MAX_COMPARISON_MODELS,
    MODELS,
    QWEN_LANGUAGES,
    SAMPLE_RATE,
)

_model = None
_model_id: str | None = None
_model_generation = 0
_model_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="tiro-model")
_operation_lock = threading.Lock()
_model_download_lock = threading.Lock()
_model_downloads: dict[str, dict[str, object]] = {}
_comparison_registry_lock = threading.Lock()
_comparison_run_lock = threading.Lock()
_comparison_cancellations: dict[str, threading.Event] = {}
_pending_comparison_cancellations: dict[str, float] = {}


def loaded_model_id() -> str | None:
    return _model_id


def _run_model_operation(operation, *args):
    return _model_executor.submit(operation, *args).result()


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
        return scan_cache_dir(common.MODEL_HUB_CACHE)
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

        common._ensure_private_directory(common.MODEL_HUB_CACHE)
        snapshot_download(
            repo_id=MODELS[model_key]["id"],
            cache_dir=common.MODEL_HUB_CACHE,
        )
    except Exception as exc:
        common._log_exception(f"Model download failed for {model_key}", exc)
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
    with storage._history_lock:
        lines = storage._read_history_lines()
        for line in reversed(lines):
            entry = storage._parse_history_line(line)
            if entry is None or entry.get("id") != entry_id:
                continue
            audio_path = storage._audio_path(entry)
            if audio_path is None or not audio_path.is_file():
                return None
            return audio_path.read_bytes()
    return None


def _history_language(entry_id: str) -> str:
    with storage._history_lock:
        for line in reversed(storage._read_history_lines()):
            entry = storage._parse_history_line(line)
            if entry is None or entry.get("id") != entry_id:
                continue
            language = entry.get("language")
            if language == "auto" or language in QWEN_LANGUAGES:
                return language
            break
    return "English"


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
            with mlx_mel_filter_as_librosa():
                from parakeet_mlx import from_pretrained

                _model = from_pretrained(
                    load_source,
                    cache_dir=str(common.MODEL_HUB_CACHE),
                )
        _model_id = wanted_id
    return _model, selected


def _generate_transcript(
    samples: array, model_key: str, source: str | Path, language: str = "English"
) -> str:
    model, selected = _load_model(model_key, source)
    import mlx.core as mx

    audio = mx.array(samples, dtype=mx.float32) / 32768.0
    if selected["backend"] == "qwen":
        result = model.generate(audio, language=None if language == "auto" else language)
    else:
        from parakeet_mlx.audio import get_logmel

        mel = get_logmel(audio, model.preprocessor_config)
        result = model.generate(mel)[0]
    return result.text.strip()


def _preload_model(model_key: str) -> dict[str, str]:
    global _model_generation
    model_key = _model_key(model_key)
    with _operation_lock:
        source = _installed_model_snapshots([model_key])[model_key]
        _, selected = _load_model(model_key, source)
        _model_generation += 1
    return {"loaded_model": selected["id"]}


def preload_model(model_key: str) -> dict[str, str]:
    return _run_model_operation(_preload_model, model_key)


def _comparison_context() -> dict:
    with _operation_lock:
        return {
            "restore_model": _model,
            "restore_model_id": _model_id,
            "expected_model": _model,
            "expected_model_id": _model_id,
            "expected_generation": _model_generation,
        }


def _compare_model(
    context: dict,
    samples: array,
    model_key: str,
    language: str,
    cancellation: threading.Event | None,
) -> str:
    with _operation_lock:
        if cancellation is not None and cancellation.is_set():
            raise HTTPError(HTTPStatus.CONFLICT, "Model comparison was cancelled")
        if (
            _model is not context["expected_model"]
            or _model_id != context["expected_model_id"]
            or _model_generation != context["expected_generation"]
        ):
            context["restore_model"] = _model
            context["restore_model_id"] = _model_id
            context["expected_generation"] = _model_generation
        source = _installed_model_snapshots([model_key])[model_key]
        try:
            if model_key == "qwen" and language != "English":
                return _generate_transcript(samples, model_key, source, language)
            return _generate_transcript(samples, model_key, source)
        finally:
            context["expected_model"] = _model
            context["expected_model_id"] = _model_id


def _restore_comparison_model(context: dict) -> None:
    with _operation_lock:
        if (
            _model is not context["expected_model"]
            or _model_id != context["expected_model_id"]
            or _model_generation != context["expected_generation"]
        ):
            context["restore_model"] = _model
            context["restore_model_id"] = _model_id
        _restore_loaded_model(
            context["restore_model"], context["restore_model_id"]
        )


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
    language = _history_language(entry_id)

    _installed_model_snapshots(model_keys)
    with _comparison_run_lock:
        context = _run_model_operation(_comparison_context)
        results = []
        try:
            for index, key in enumerate(model_keys):
                if cancellation is not None and cancellation.is_set():
                    raise HTTPError(HTTPStatus.CONFLICT, "Model comparison was cancelled")
                started = time.perf_counter()
                text = _run_model_operation(
                    _compare_model,
                    context,
                    samples,
                    key,
                    language,
                    cancellation,
                )
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
            _run_model_operation(_restore_comparison_model, context)
    return {"history_id": entry_id, "results": results}


def _transcribe(
    wav_bytes: bytes,
    model_key: str,
    origin_bundle_id: str | None = None,
    origin_app_name: str | None = None,
    mode: str = "standard",
    punctuation: str = "automatic",
    language: str = "English",
) -> dict:
    global _model_generation
    samples = decode_pcm_wav(wav_bytes)

    started = time.perf_counter()
    with _operation_lock:
        model_key = _model_key(model_key)
        mode, punctuation, language = text_rules._transcription_options(
            model_key, mode, punctuation, language
        )
        source = _installed_model_snapshots([model_key])[model_key]
        if language == "English":
            raw_text = _generate_transcript(samples, model_key, source)
        else:
            raw_text = _generate_transcript(samples, model_key, source, language)
        selected = MODELS[model_key]
        _model_generation += 1
    elapsed = time.perf_counter() - started

    delivered_text = raw_text
    if mode == "standard":
        delivered_text = text_rules.apply_spoken_formatting(delivered_text, punctuation)
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
        "model": selected["id"],
        "transcription_seconds": round(elapsed, 3),
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
                stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
                audio_path = common.AUDIO_DIR / f"{stamp}.wav"
                common._write_private_bytes(audio_path, wav_bytes)
                entry["audio_file"] = str(audio_path.relative_to(common.ROOT))
            try:
                common._ensure_private_directory(common.HISTORY_PATH.parent)
                lines = storage._migrate_history_locked()
                prefix = "\n" if lines and not lines[-1].endswith("\n") else ""
                common._append_private_text(
                    common.HISTORY_PATH, prefix + json.dumps(entry, ensure_ascii=False) + "\n"
                )
            except Exception:
                if audio_path is not None:
                    try:
                        audio_path.unlink()
                    except OSError as exc:
                        print(f"Could not remove uncommitted recording: {exc!r}", flush=True)
                raise
    if privacy["store_history"]:
        try:
            storage.apply_retention()
        except Exception as exc:
            print(f"Retention maintenance failed; will retry later: {exc!r}", flush=True)
    return entry


def transcribe(
    wav_bytes: bytes,
    model_key: str,
    origin_bundle_id: str | None = None,
    origin_app_name: str | None = None,
    mode: str = "standard",
    punctuation: str = "automatic",
    language: str = "English",
) -> dict:
    return _run_model_operation(
        _transcribe,
        wav_bytes,
        model_key,
        origin_bundle_id,
        origin_app_name,
        mode,
        punctuation,
        language,
    )
