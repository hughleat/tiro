from __future__ import annotations

import json
import os
import threading
import time
import uuid
import wave
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from . import common, models, storage, text
from .common import (
    API_VERSION,
    DEFAULT_HISTORY_LIMIT,
    HTTPError,
    MAX_JSON_BODY_BYTES,
    MAX_ORIGIN_APP_NAME,
    MAX_ORIGIN_BUNDLE_ID,
    MAX_RECORDING_BYTES,
    MODELS,
)

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

class TiroHandler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args) -> None:
        status = args[1] if len(args) > 1 else "-"
        path = urlparse(self.path).path
        print(
            f'[{self.log_date_time_string()}] "{self.command} {path}" {status}',
            flush=True,
        )

    def _authorized(self) -> bool:
        return common.shutdown_is_authorized(self.headers.get("X-Tiro-Worker-Token", ""))

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
        with storage._history_lock:
            lines = storage._migrate_history_locked()
        for line in reversed(lines):
            entry = storage._parse_history_line(line)
            if entry is None or entry.get("id") != entry_id:
                continue
            audio_path = storage._audio_path(entry)
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
        if path == "/api/health":
            json_response(self, {"ready": True})
            return
        if not self._authorized():
            json_response(self, {"error": "Forbidden"}, HTTPStatus.FORBIDDEN)
            return
        if path == "/api/models":
            try:
                json_response(self, {"models": models.model_status()})
            except Exception as exc:
                common._log_exception("Model status failed", exc)
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
                    "loaded_model": models.loaded_model_id(),
                    "models": MODELS,
                    "history_file": str(common.HISTORY_PATH),
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
            json_response(self, {"entries": storage.recent_history(limit, query)})
            return
        if path == "/api/privacy":
            try:
                json_response(self, storage.load_privacy_settings())
            except (OSError, ValueError) as exc:
                common._log_exception("Privacy settings unavailable", exc)
                json_response(
                    self,
                    {"error": "Privacy settings are malformed or unavailable."},
                    HTTPStatus.INTERNAL_SERVER_ERROR,
                )
            return
        if path == "/api/history/audio":
            entry_id = parse_qs(parsed_url.query).get("id", [""])[-1]
            if not entry_id or not self._send_audio(entry_id):
                json_response(self, {"error": "Audio not found"}, HTTPStatus.NOT_FOUND)
            return
        if path == "/api/vocabulary/profiles":
            with storage._state_lock:
                json_response(self, text.load_profiles())
            return
        if path == "/api/snippets":
            with storage._state_lock:
                json_response(self, {"snippets": text.load_snippets()})
            return
        if path == "/api/suggestions":
            try:
                json_response(self, {"suggestions": text.get_suggestions()})
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
        if not self._authorized():
            json_response(self, {"error": "Forbidden"}, HTTPStatus.FORBIDDEN)
            return
        if path == "/api/shutdown":
            json_response(self, {"stopping": True})
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return

        mutation_paths = {
            "/api/history/delete",
            "/api/history/delete-all",
            "/api/history/correction",
            "/api/vocabulary/profiles",
            "/api/suggestions/accept",
            "/api/suggestions/dismiss",
            "/api/models/download",
            "/api/models/delete",
            "/api/models/compare",
            "/api/models/compare/cancel",
            "/api/snippets",
            "/api/snippets/delete",
            "/api/privacy",
        }
        if path in mutation_paths:
            try:
                payload = self._read_json_body()
                if path == "/api/history/delete":
                    entry_id = payload.get("id")
                    if not isinstance(entry_id, str) or not entry_id:
                        raise ValueError("id must be a non-empty string")
                    if not storage.delete_history_entry(entry_id):
                        json_response(
                            self,
                            {"error": "History entry not found"},
                            HTTPStatus.NOT_FOUND,
                        )
                        return
                    json_response(self, {"deleted": True})
                elif path == "/api/history/delete-all":
                    if set(payload) != {"confirm"} or payload["confirm"] is not True:
                        raise ValueError("confirm must be true")
                    storage.delete_all_history()
                    json_response(self, {"deleted": True})
                elif path == "/api/privacy":
                    json_response(self, storage.update_privacy_settings(payload))
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
                    if not text.correct_history_entry(entry_id, corrected_text):
                        json_response(
                            self,
                            {"error": "History entry not found"},
                            HTTPStatus.NOT_FOUND,
                        )
                        return
                    json_response(self, {"corrected": True})
                elif path == "/api/vocabulary/profiles":
                    json_response(self, text.save_profiles(payload))
                elif path == "/api/snippets":
                    json_response(self, text.save_snippet(payload), HTTPStatus.CREATED)
                elif path == "/api/snippets/delete":
                    snippet_id = payload.get("id")
                    if not isinstance(snippet_id, str) or not snippet_id:
                        raise ValueError("id must be a non-empty string")
                    json_response(self, {"deleted": text.delete_snippet(snippet_id)})
                elif path == "/api/models/download":
                    model_key = models._model_key(payload.get("key", payload.get("model")))
                    downloaded = models.download_model(model_key)
                    json_response(
                        self,
                        {"key": model_key, "downloaded": downloaded},
                    )
                elif path == "/api/models/delete":
                    model_key = models._model_key(payload.get("key", payload.get("model")))
                    freed = models.delete_model(model_key)
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
                    with models._comparison_registry_lock:
                        if comparison_id in models._comparison_cancellations:
                            raise HTTPError(HTTPStatus.CONFLICT, "Comparison is already running")
                        if models._pending_comparison_cancellations.pop(comparison_id, None) is not None:
                            cancellation.set()
                        models._comparison_cancellations[comparison_id] = cancellation
                    try:
                        response = models.compare_history_models(
                            payload.get("history_id"),
                            payload.get("model_keys", payload.get("models")),
                            cancellation,
                        )
                    finally:
                        with models._comparison_registry_lock:
                            models._comparison_cancellations.pop(comparison_id, None)
                    json_response(self, response)
                elif path == "/api/models/compare/cancel":
                    comparison_id = payload.get("comparison_id")
                    if not isinstance(comparison_id, str) or not comparison_id:
                        raise ValueError("comparison_id must be a non-empty string")
                    with models._comparison_registry_lock:
                        cancellation = models._comparison_cancellations.get(comparison_id)
                        if cancellation is None:
                            now = time.monotonic()
                            models._pending_comparison_cancellations[comparison_id] = now
                            expired = [
                                key for key, created in models._pending_comparison_cancellations.items()
                                if now - created > 60
                            ]
                            for key in expired:
                                models._pending_comparison_cancellations.pop(key, None)
                            while len(models._pending_comparison_cancellations) > 100:
                                models._pending_comparison_cancellations.pop(
                                    next(iter(models._pending_comparison_cancellations))
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
                    accepted_scope = text.accept_suggestion(suggestion_id, scope)
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
                    if not text.dismiss_suggestion(suggestion_id):
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
                common._log_exception("History or model mutation failed", exc)
                json_response(
                    self,
                    {"error": "History mutation failed."},
                    HTTPStatus.INTERNAL_SERVER_ERROR,
                )
            except Exception as exc:
                common._log_exception("Authenticated operation failed", exc)
                json_response(
                    self,
                    {"error": "Authenticated operation failed."},
                    HTTPStatus.INTERNAL_SERVER_ERROR,
                )
            return

        if path == "/api/preload":
            try:
                model_key = self.headers.get("X-Parakeet-Model", "compact")
                json_response(self, models.preload_model(model_key))
            except HTTPError as exc:
                json_response(self, {"error": str(exc)}, exc.status)
            except ValueError as exc:
                json_response(self, {"error": str(exc)}, HTTPStatus.BAD_REQUEST)
            except Exception as exc:
                common._log_exception("Model preload failed", exc)
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
            origin_bundle_id = text._origin_header(
                self.headers.get("X-Tiro-Origin-Bundle-ID"),
                MAX_ORIGIN_BUNDLE_ID,
                "X-Tiro-Origin-Bundle-ID",
            )
            origin_app_name = text._origin_header(
                self.headers.get("X-Tiro-Origin-App-Name"),
                MAX_ORIGIN_APP_NAME,
                "X-Tiro-Origin-App-Name",
            )
            mode = self.headers.get("X-Tiro-Mode", "standard")
            punctuation = self.headers.get("X-Tiro-Punctuation", "automatic")
            language = self.headers.get("X-Tiro-Language", "English")
            wav_bytes = self.rfile.read(length)
            if (mode, punctuation, language) == ("standard", "automatic", "English"):
                entry = models.transcribe(
                    wav_bytes, model_key, origin_bundle_id, origin_app_name
                )
            else:
                entry = models.transcribe(
                    wav_bytes, model_key, origin_bundle_id, origin_app_name,
                    mode, punctuation, language,
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
                {"error": "Local transcription failed. See Tiro's worker log for details."},
                HTTPStatus.INTERNAL_SERVER_ERROR,
            )


def _close_worker(server: ThreadingHTTPServer) -> None:
    models._model_executor.shutdown(wait=True, cancel_futures=True)
    server.server_close()


def main() -> None:
    os.umask(0o077)
    os.environ.setdefault("HF_HOME", str(common.MODEL_CACHE))
    common.ensure_private_paths()
    try:
        storage.migrate_history()
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
        _close_worker(server)


if __name__ == "__main__":
    main()

__all__ = ["TiroHandler", "json_response", "main"]
