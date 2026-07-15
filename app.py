from __future__ import annotations

import gc
import io
import json
import os
import re
import secrets
import threading
import time
import wave
from array import array
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parent
DATA_DIR = ROOT / "data"
AUDIO_DIR = DATA_DIR / "audio"
HISTORY_PATH = DATA_DIR / "history.jsonl"
VOCABULARY_PATH = DATA_DIR / "vocabulary.json"
MODEL_CACHE = ROOT / ".cache" / "huggingface"
MODEL_HUB_CACHE = MODEL_CACHE / "hub"
SAMPLE_RATE = 16_000
MAX_RECORDING_BYTES = 100 * 1024 * 1024
API_VERSION = 3

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
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "model": selected["id"],
        "audio_file": str(audio_path.relative_to(ROOT)),
        "transcription_seconds": round(elapsed, 3),
        "text": apply_vocabulary(raw_text, load_vocabulary()),
    }
    if entry["text"] != raw_text:
        entry["raw_text"] = raw_text
    with _history_lock:
        with HISTORY_PATH.open("a", encoding="utf-8") as history:
            history.write(json.dumps(entry, ensure_ascii=False) + "\n")
    return entry


def recent_history(limit: int = 20) -> list[dict]:
    if not HISTORY_PATH.exists():
        return []
    entries = []
    for line in HISTORY_PATH.read_text(encoding="utf-8").splitlines()[-limit:]:
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return list(reversed(entries))


class TiroHandler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args) -> None:
        print(f"[{self.log_date_time_string()}] {format % args}", flush=True)

    def do_GET(self) -> None:
        path = urlparse(self.path).path
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
            json_response(self, {"entries": recent_history()})
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
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 44 or length > MAX_RECORDING_BYTES:
                raise ValueError("Recording is empty or too large")
            model_key = self.headers.get("X-Parakeet-Model", "compact")
            entry = transcribe(self.rfile.read(length), model_key)
            json_response(self, entry)
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
