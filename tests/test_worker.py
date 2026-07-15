import io
import http.client
import json
import tempfile
import threading
import time
import types
import unittest
import uuid
import wave
from array import array
from contextlib import ExitStack, contextmanager
from datetime import datetime, timedelta, timezone
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import Mock, patch

import app
from scripts import worker_entry


def make_wav(*, channels=1, sample_width=2, sample_rate=16_000, frames=160):
    output = io.BytesIO()
    with wave.open(output, "wb") as recording:
        recording.setnchannels(channels)
        recording.setsampwidth(sample_width)
        recording.setframerate(sample_rate)
        recording.writeframes(array("h", [100] * frames * channels).tobytes())
    return output.getvalue()


@contextmanager
def history_environment():
    with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
        root = Path(directory)
        data = root / "data"
        audio = data / "audio"
        data.mkdir()
        audio.mkdir()
        stack.enter_context(patch.object(app, "ROOT", root))
        stack.enter_context(patch.object(app, "DATA_DIR", data))
        stack.enter_context(patch.object(app, "AUDIO_DIR", audio))
        stack.enter_context(patch.object(app, "HISTORY_PATH", data / "history.jsonl"))
        stack.enter_context(patch.object(app, "RETENTION_PATH", data / "retention.json"))
        stack.enter_context(patch.object(app, "VOCABULARY_PATH", data / "vocabulary.json"))
        stack.enter_context(patch.object(app, "PROFILES_PATH", data / "profiles.json"))
        stack.enter_context(patch.object(app, "SUGGESTIONS_PATH", data / "suggestions.json"))
        stack.enter_context(patch.object(app, "SNIPPETS_PATH", data / "snippets.json"))
        yield root, audio, app.HISTORY_PATH


@contextmanager
def worker_server(token="secret"):
    server = ThreadingHTTPServer(("127.0.0.1", 0), app.TiroHandler)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    try:
        with patch.dict(app.os.environ, {"TIRO_WORKER_TOKEN": token}):
            yield server.server_address
    finally:
        server.shutdown()
        thread.join(timeout=2)
        server.server_close()


def request(address, method, path, payload=None, token=None, headers=None):
    body = None if payload is None else json.dumps(payload).encode()
    request_headers = dict(headers or {})
    if body is not None:
        request_headers["Content-Type"] = "application/json"
    if token is not None:
        request_headers["X-Tiro-Worker-Token"] = token
    connection = http.client.HTTPConnection(*address, timeout=2)
    connection.request(method, path, body=body, headers=request_headers)
    response = connection.getresponse()
    content = response.read()
    connection.close()
    return response.status, dict(response.getheaders()), content


class DecodeWavTests(unittest.TestCase):
    def test_decodes_expected_format(self):
        self.assertEqual(len(app.decode_pcm_wav(make_wav())), 160)

    def test_rejects_stereo(self):
        with self.assertRaisesRegex(ValueError, "mono"):
            app.decode_pcm_wav(make_wav(channels=2))

    def test_rejects_wrong_sample_rate(self):
        with self.assertRaisesRegex(ValueError, "16000 Hz"):
            app.decode_pcm_wav(make_wav(sample_rate=44_100))


class HistoryTests(unittest.TestCase):
    def test_migration_is_stable_and_preserves_unknown_and_malformed_lines(self):
        with history_environment() as (_, _, history):
            original = (
                '{"timestamp":"2025-01-01T00:00:00+00:00",'
                '"audio_file":"data/audio/one.wav","unknown":{"x":1}}\n'
                "not-json at all\n"
            )
            history.write_text(original)
            app.migrate_history()
            first = history.read_text()
            entry = json.loads(first.splitlines()[0])
            expected = app._history_id({
                "timestamp": "2025-01-01T00:00:00+00:00",
                "audio_file": "data/audio/one.wav",
            })
            self.assertEqual(entry["id"], expected)
            self.assertEqual(entry["unknown"], {"x": 1})
            self.assertEqual(first.splitlines()[1], "not-json at all")
            self.assertEqual(history.with_name("history.jsonl.bak").read_text(), original)

            app.migrate_history()
            self.assertEqual(history.read_text(), first)
            self.assertEqual(history.with_name("history.jsonl.bak").read_text(), original)

    def test_migration_ids_are_framed_unique_and_duplicate_repair_is_stable(self):
        with history_environment() as (_, _, history):
            entries = [
                {"id": "keep", "text": "unique"},
                {"timestamp": "ab", "audio_file": "c"},
                {"timestamp": "a", "audio_file": "bc"},
                {"timestamp": "ab", "audio_file": "c"},
                {"id": "duplicate", "text": "first"},
                {"id": "duplicate", "text": "second"},
            ]
            history.write_text("".join(json.dumps(entry) + "\n" for entry in entries))

            app.migrate_history()
            migrated = [json.loads(line) for line in history.read_text().splitlines()]
            ids = [entry["id"] for entry in migrated]
            self.assertEqual(len(ids), len(set(ids)))
            self.assertEqual(migrated[0]["id"], "keep")
            self.assertNotEqual(migrated[1]["id"], migrated[2]["id"])
            self.assertNotEqual(migrated[1]["id"], migrated[3]["id"])
            self.assertEqual(migrated[4]["id"], "duplicate")
            self.assertNotEqual(migrated[5]["id"], "duplicate")

            first_migration = history.read_text()
            app.migrate_history()
            self.assertEqual(history.read_text(), first_migration)

    def test_invalid_object_without_migration_fields_is_preserved(self):
        with history_environment() as (_, _, history):
            original = '{"text":"missing migration fields","extra":true}\n'
            history.write_text(original)
            app.migrate_history()
            self.assertEqual(history.read_text(), original)
            self.assertFalse(history.with_name("history.jsonl.bak").exists())

    def test_search_is_unicode_case_insensitive_newest_first_and_limited(self):
        with history_environment() as (_, _, history):
            entries = [
                {"id": "1", "text": "STRASSE", "model": "old"},
                {"id": "2", "raw_text": "Straße", "model": "middle"},
                {"id": "3", "text": "unrelated", "model": "Straße model"},
            ]
            history.write_text("".join(json.dumps(entry) + "\n" for entry in entries))
            results = app.recent_history(limit=2, query="straße")
            self.assertEqual([entry["id"] for entry in results], ["3", "2"])
            self.assertTrue(all(entry["audio_available"] is False for entry in results))

    def test_history_limit_has_hard_cap(self):
        with history_environment() as (_, _, history):
            history.write_text("".join(
                json.dumps({"id": str(index), "text": "match"}) + "\n"
                for index in range(250)
            ))
            self.assertEqual(len(app.recent_history(1000)), 200)

    def test_audio_available_only_for_contained_existing_file(self):
        with history_environment() as (root, audio, history):
            recording = audio / "safe.wav"
            recording.write_bytes(make_wav())
            outside = root / "outside.wav"
            outside.write_bytes(make_wav())
            history.write_text("".join([
                json.dumps({"id": "safe", "audio_file": "data/audio/safe.wav"}) + "\n",
                json.dumps({"id": "outside", "audio_file": str(outside)}) + "\n",
            ]))
            results = {entry["id"]: entry for entry in app.recent_history(10)}
            self.assertTrue(results["safe"]["audio_available"])
            self.assertFalse(results["outside"]["audio_available"])

    def test_api_skips_wrong_typed_rows_without_rewriting_them(self):
        with history_environment() as (_, _, history):
            invalid = '{"id":"bad","text":42,"model":false}\n'
            valid = '{"id":"good","text":"hello","transcription_seconds":1.5}\n'
            history.write_text(invalid + valid)

            self.assertEqual([entry["id"] for entry in app.recent_history()], ["good"])
            self.assertEqual(history.read_text(), invalid + valid)


class HistoryMutationTests(unittest.TestCase):
    def test_delete_removes_exactly_one_duplicate_id_and_its_audio(self):
        with history_environment() as (_, audio, history):
            first_audio = audio / "first.wav"
            second_audio = audio / "second.wav"
            first_audio.write_bytes(b"first")
            second_audio.write_bytes(b"second")
            entries = [
                {"id": "same", "audio_file": "data/audio/first.wav"},
                {"id": "same", "audio_file": "data/audio/second.wav"},
            ]
            history.write_text("".join(json.dumps(entry) + "\n" for entry in entries))
            self.assertTrue(app.delete_history_entry("same"))
            self.assertFalse(first_audio.exists())
            self.assertTrue(second_audio.exists())
            self.assertEqual(len(history.read_text().splitlines()), 1)

    def test_delete_rejects_missing_id_without_rewrite(self):
        with history_environment() as (_, _, history):
            original = '{"id":"present"}\nmalformed\n'
            history.write_text(original)
            self.assertFalse(app.delete_history_entry("missing"))
            self.assertEqual(history.read_text(), original)

    def test_delete_never_unlinks_path_outside_audio_directory(self):
        with history_environment() as (root, _, history):
            outside = root / "outside.wav"
            outside.write_bytes(b"keep")
            history.write_text(json.dumps({
                "id": "unsafe",
                "audio_file": "data/audio/../../outside.wav",
            }) + "\n")
            self.assertTrue(app.delete_history_entry("unsafe"))
            self.assertTrue(outside.exists())

    def test_delete_keeps_audio_referenced_by_another_row(self):
        with history_environment() as (_, audio, history):
            shared = audio / "shared.wav"
            shared.write_bytes(b"shared")
            history.write_text("".join([
                '{"id":"remove","audio_file":"data/audio/shared.wav"}\n',
                '{"id":"keep","audio_file":"data/audio/shared.wav"}\n',
            ]))

            self.assertTrue(app.delete_history_entry("remove"))
            self.assertTrue(shared.exists())
            self.assertIn('"id":"keep"', history.read_text())

    def test_delete_restores_audio_when_history_write_fails(self):
        with history_environment() as (_, audio, history):
            recording = audio / "blocked.wav"
            recording.write_bytes(b"audio")
            original = '{"id":"blocked","audio_file":"data/audio/blocked.wav"}\n'
            history.write_text(original)

            with patch.object(
                app, "_atomic_write", side_effect=OSError("history write failed")
            ):
                with self.assertRaisesRegex(OSError, "history write failed"):
                    app.delete_history_entry("blocked")
            self.assertEqual(history.read_text(), original)
            self.assertTrue(recording.exists())
            self.assertEqual(recording.read_bytes(), b"audio")
            self.assertEqual(list(audio.rglob(app.STAGED_AUDIO_PREFIX + "*")), [])

    def test_reconciliation_restores_stage_left_before_history_commit(self):
        with history_environment() as (_, audio, history):
            recording = audio / "before commit.wav"
            recording.write_bytes(b"audio")
            original = (
                '{"id":"kept","audio_file":"data/audio/before commit.wav"}\n'
            )
            history.write_text(original)
            staged = app._staged_audio_path(recording.resolve())
            app.os.replace(recording, staged)

            self.assertEqual([entry["id"] for entry in app.recent_history()], ["kept"])
            self.assertEqual(recording.read_bytes(), b"audio")
            self.assertFalse(staged.exists())
            self.assertEqual(history.read_text(), original)

    def test_reconciliation_finalizes_stage_left_after_history_commit(self):
        with history_environment() as (_, audio, history):
            recording = audio / "after.wav"
            recording.write_bytes(b"audio")
            staged = app._staged_audio_path(recording.resolve())
            app.os.replace(recording, staged)
            history.write_text("")

            self.assertEqual(app.recent_history(), [])
            self.assertFalse(recording.exists())
            self.assertFalse(staged.exists())


class RetentionTests(unittest.TestCase):
    def test_prunes_only_entries_older_than_boundary_and_cleans_audio(self):
        now = datetime(2026, 7, 15, 12, tzinfo=timezone.utc)
        with history_environment() as (_, audio, history):
            old_audio = audio / "old.wav"
            boundary_audio = audio / "boundary.wav"
            old_audio.write_bytes(b"old")
            boundary_audio.write_bytes(b"boundary")
            entries = [
                {"id": "old", "timestamp": (now - timedelta(days=7, seconds=1)).isoformat(), "audio_file": "data/audio/old.wav"},
                {"id": "boundary", "timestamp": (now - timedelta(days=7)).isoformat(), "audio_file": "data/audio/boundary.wav"},
                {"id": "invalid", "timestamp": "not-a-date"},
            ]
            history.write_text(
                json.dumps(entries[0]) + "\nmalformed\n" +
                json.dumps(entries[1]) + "\n" + json.dumps(entries[2]) + "\n"
            )
            self.assertEqual(app.set_retention(7, now), 1)
            self.assertFalse(old_audio.exists())
            self.assertTrue(boundary_audio.exists())
            remaining = history.read_text()
            self.assertIn("malformed", remaining)
            self.assertIn('"id": "boundary"', remaining)
            self.assertIn('"id": "invalid"', remaining)
            self.assertEqual(app.load_retention_days(), 7)

    def test_zero_disables_pruning_and_invalid_choice_is_rejected(self):
        with history_environment() as (_, _, history):
            history.write_text('{"id":"old","timestamp":"2000-01-01T00:00:00Z"}\n')
            self.assertEqual(app.set_retention(0), 0)
            self.assertIn("old", history.read_text())
            with self.assertRaisesRegex(ValueError, "one of"):
                app.set_retention(1)

    def test_audio_cleanup_does_not_escape_audio_directory(self):
        with history_environment() as (root, _, history):
            outside = root / "outside.wav"
            outside.write_bytes(b"keep")
            history.write_text(json.dumps({
                "id": "old",
                "timestamp": "2000-01-01T00:00:00Z",
                "audio_file": str(outside),
            }) + "\n")
            self.assertEqual(app.apply_retention(7), 1)
            self.assertTrue(outside.exists())

    def test_retention_keeps_audio_still_referenced_by_a_kept_row(self):
        with history_environment() as (_, audio, history):
            shared = audio / "shared.wav"
            shared.write_bytes(b"shared")
            history.write_text("".join([
                '{"id":"old","timestamp":"2000-01-01T00:00:00Z",'
                '"audio_file":"data/audio/shared.wav"}\n',
                '{"id":"new","timestamp":"2999-01-01T00:00:00Z",'
                '"audio_file":"data/audio/shared.wav"}\n',
            ]))

            self.assertEqual(app.set_retention(7), 1)
            self.assertTrue(shared.exists())
            self.assertIn('"id":"new"', history.read_text())

    def test_retention_rolls_back_every_audio_after_mid_stage_failure(self):
        with history_environment() as (_, audio, history):
            first = audio / "first.wav"
            second = audio / "second.wav"
            first.write_bytes(b"first")
            second.write_bytes(b"second")
            original = "".join([
                '{"id":"first","timestamp":"2000-01-01T00:00:00Z",'
                '"audio_file":"data/audio/first.wav"}\n',
                '{"id":"second","timestamp":"2000-01-01T00:00:00Z",'
                '"audio_file":"data/audio/second.wav"}\n',
            ])
            history.write_text(original)
            app._persist_retention_days(30)
            real_replace = app.os.replace

            def fail_second_stage(source, destination):
                if Path(source).resolve() == second.resolve():
                    raise PermissionError("second stage failed")
                return real_replace(source, destination)

            with patch.object(app.os, "replace", side_effect=fail_second_stage):
                with self.assertRaisesRegex(PermissionError, "second stage failed"):
                    app.set_retention(7)
            self.assertEqual(app.load_retention_days(), 30)
            self.assertEqual(history.read_text(), original)
            self.assertEqual(first.read_bytes(), b"first")
            self.assertEqual(second.read_bytes(), b"second")
            self.assertEqual(list(audio.rglob(app.STAGED_AUDIO_PREFIX + "*")), [])

    def test_apply_retention_restores_all_audio_when_history_write_fails(self):
        with history_environment() as (_, audio, history):
            first = audio / "first.wav"
            second = audio / "second.wav"
            first.write_bytes(b"first")
            second.write_bytes(b"second")
            original = "".join([
                '{"id":"first","timestamp":"2000-01-01T00:00:00Z",'
                '"audio_file":"data/audio/first.wav"}\n',
                '{"id":"second","timestamp":"2000-01-01T00:00:00Z",'
                '"audio_file":"data/audio/second.wav"}\n',
            ])
            history.write_text(original)

            with patch.object(
                app, "_atomic_write", side_effect=OSError("history write failed")
            ):
                with self.assertRaisesRegex(OSError, "history write failed"):
                    app.apply_retention(7)
            self.assertEqual(history.read_text(), original)
            self.assertEqual(first.read_bytes(), b"first")
            self.assertEqual(second.read_bytes(), b"second")
            self.assertEqual(list(audio.rglob(app.STAGED_AUDIO_PREFIX + "*")), [])

    def test_retention_rolls_back_setting_when_history_write_fails(self):
        with history_environment() as (_, audio, history):
            recording = audio / "old.wav"
            recording.write_bytes(b"old")
            original = (
                '{"id":"old","timestamp":"2000-01-01T00:00:00Z",'
                '"audio_file":"data/audio/old.wav"}\n'
            )
            history.write_text(original)
            app._persist_retention_days(30)
            real_atomic_write = app._atomic_write

            def fail_history(path, content):
                if path == app.HISTORY_PATH:
                    raise OSError("history write failed")
                return real_atomic_write(path, content)

            with patch.object(app, "_atomic_write", side_effect=fail_history):
                with self.assertRaisesRegex(OSError, "history write failed"):
                    app.set_retention(7)
            self.assertEqual(app.load_retention_days(), 30)
            self.assertEqual(history.read_text(), original)
            self.assertEqual(recording.read_bytes(), b"old")

    def test_concurrent_retention_updates_finish_with_last_setting_and_behavior(self):
        with history_environment() as (_, _, history):
            history.write_text('{"id":"old","timestamp":"2000-01-01T00:00:00Z"}\n')
            first_persisting = threading.Event()
            release_first = threading.Event()
            second_finished = threading.Event()
            real_persist = app._persist_retention_days

            def controlled_persist(days):
                if days == 0:
                    first_persisting.set()
                    release_first.wait(1)
                real_persist(days)

            with patch.object(app, "_persist_retention_days", side_effect=controlled_persist):
                first = threading.Thread(target=app.set_retention, args=(0,))
                second = threading.Thread(
                    target=lambda: (app.set_retention(7), second_finished.set())
                )
                first.start()
                self.assertTrue(first_persisting.wait(1))
                second.start()
                self.assertFalse(second_finished.wait(0.05))
                release_first.set()
                first.join(1)
                second.join(1)

            self.assertFalse(first.is_alive())
            self.assertFalse(second.is_alive())
            self.assertEqual(app.load_retention_days(), 7)
            self.assertNotIn('"id":"old"', history.read_text())


class TranscriptionHistoryTests(unittest.TestCase):
    def test_transcribe_requires_and_uses_installed_snapshot_without_downloading(self):
        snapshot = Path("/cache/qwen")
        with history_environment(), patch.object(
            app, "decode_pcm_wav", return_value=array("h", [1])
        ), patch.object(
            app, "_installed_model_snapshots", return_value={"qwen": snapshot}
        ), patch.object(
            app, "_generate_transcript", return_value="hello"
        ) as generate, patch.object(
            app, "apply_retention", return_value=0
        ), patch("huggingface_hub.snapshot_download") as download:
            app.transcribe(make_wav(), "qwen")

        generate.assert_called_once_with(array("h", [1]), "qwen", snapshot)
        download.assert_not_called()

    def test_new_entry_gets_uuid_and_applies_persisted_retention(self):
        class FakeAudio:
            def __truediv__(self, _divisor):
                return self

        class FakeModel:
            def generate(self, _audio, language):
                self.language = language
                return types.SimpleNamespace(text="hello")

        mlx = types.ModuleType("mlx")
        mlx_core = types.ModuleType("mlx.core")
        mlx_core.float32 = object()
        mlx_core.array = lambda _samples, dtype: FakeAudio()
        mlx.core = mlx_core
        model = FakeModel()
        selected = {"id": "test-model", "backend": "qwen"}

        with history_environment() as (_, _, history), patch.dict(
            "sys.modules", {"mlx": mlx, "mlx.core": mlx_core}
        ), patch.object(app, "decode_pcm_wav", return_value=array("h", [1])), patch.object(
            app, "_load_model", return_value=(model, selected)
        ), patch.object(app, "load_vocabulary", return_value=[]), patch.object(
            app, "apply_retention", return_value=0
        ) as retention:
            entry = app.transcribe(make_wav(), "qwen")
            self.assertEqual(uuid.UUID(entry["id"]).version, 4)
            self.assertEqual(json.loads(history.read_text())["id"], entry["id"])
            self.assertEqual(model.language, "English")
            retention.assert_called_once_with()

    def test_retention_failure_after_transcription_is_logged_and_does_not_fail(self):
        class FakeAudio:
            def __truediv__(self, _divisor):
                return self

        model = types.SimpleNamespace(
            generate=lambda _audio, language: types.SimpleNamespace(text="hello")
        )
        mlx = types.ModuleType("mlx")
        mlx_core = types.ModuleType("mlx.core")
        mlx_core.float32 = object()
        mlx_core.array = lambda _samples, dtype: FakeAudio()
        mlx.core = mlx_core
        selected = {"id": "test-model", "backend": "qwen"}

        with history_environment() as (_, _, history), patch.dict(
            "sys.modules", {"mlx": mlx, "mlx.core": mlx_core}
        ), patch.object(app, "decode_pcm_wav", return_value=array("h", [1])), patch.object(
            app, "_load_model", return_value=(model, selected)
        ), patch.object(app, "load_vocabulary", return_value=[]), patch.object(
            app, "apply_retention", side_effect=OSError("maintenance failed")
        ), patch("builtins.print") as output:
            entry = app.transcribe(make_wav(), "qwen")

            self.assertEqual(json.loads(history.read_text())["id"], entry["id"])
            self.assertIn("will retry later", output.call_args.args[0])

    def test_append_separates_entry_from_malformed_tail_without_newline(self):
        class FakeAudio:
            def __truediv__(self, _divisor):
                return self

        model = types.SimpleNamespace(
            generate=lambda _audio, language: types.SimpleNamespace(text="hello")
        )
        mlx = types.ModuleType("mlx")
        mlx_core = types.ModuleType("mlx.core")
        mlx_core.float32 = object()
        mlx_core.array = lambda _samples, dtype: FakeAudio()
        mlx.core = mlx_core
        selected = {"id": "test-model", "backend": "qwen"}

        with history_environment() as (_, _, history), patch.dict(
            "sys.modules", {"mlx": mlx, "mlx.core": mlx_core}
        ), patch.object(app, "decode_pcm_wav", return_value=array("h", [1])), patch.object(
            app, "_load_model", return_value=(model, selected)
        ), patch.object(app, "load_vocabulary", return_value=[]), patch.object(
            app, "apply_retention", return_value=0
        ):
            history.write_text("malformed-tail")
            entry = app.transcribe(make_wav(), "qwen")

            lines = history.read_text().splitlines()
            self.assertEqual(lines[0], "malformed-tail")
            self.assertEqual(json.loads(lines[1])["id"], entry["id"])

    def test_origin_is_persisted_and_selects_origin_vocabulary(self):
        class FakeAudio:
            def __truediv__(self, _divisor):
                return self

        model = types.SimpleNamespace(
            generate=lambda _audio, language: types.SimpleNamespace(text="hello yana")
        )
        mlx = types.ModuleType("mlx")
        mlx_core = types.ModuleType("mlx.core")
        mlx_core.float32 = object()
        mlx_core.array = lambda _samples, dtype: FakeAudio()
        mlx.core = mlx_core
        selected = {"id": "test-model", "backend": "qwen"}

        with history_environment() as (_, _, history), patch.dict(
            "sys.modules", {"mlx": mlx, "mlx.core": mlx_core}
        ), patch.object(app, "decode_pcm_wav", return_value=array("h", [1])), patch.object(
            app, "_load_model", return_value=(model, selected)
        ), patch.object(
            app,
            "vocabulary_for_origin",
            return_value=[{"spoken": "yana", "written": "Janne"}],
        ) as vocabulary, patch.object(app, "apply_retention", return_value=0):
            entry = app.transcribe(make_wav(), "qwen", "com.editor", "Editor")
            persisted = json.loads(history.read_text())

        vocabulary.assert_called_once_with("com.editor")
        self.assertEqual(entry["text"], "hello Janne")
        self.assertEqual(entry["raw_text"], "hello yana")
        self.assertEqual(entry["origin_bundle_id"], "com.editor")
        self.assertEqual(entry["origin_app_name"], "Editor")
        self.assertEqual(persisted["origin_bundle_id"], "com.editor")


class VocabularyTests(unittest.TestCase):
    def test_loads_only_valid_entries(self):
        with tempfile.TemporaryDirectory() as directory:
            vocabulary = Path(directory) / "vocabulary.json"
            vocabulary.write_text(json.dumps({"entries": [
                {"spoken": " yana ", "written": " Janne "},
                {"spoken": "unfinished", "written": ""},
                {"spoken": 42, "written": "ignored"},
            ]}))
            with patch.object(app, "VOCABULARY_PATH", vocabulary):
                self.assertEqual(
                    app.load_vocabulary(),
                    [{"spoken": "yana", "written": "Janne"}],
                )

    def test_json_vocabulary_preserves_equals_signs(self):
        with tempfile.TemporaryDirectory() as directory:
            vocabulary = Path(directory) / "vocabulary.json"
            vocabulary.write_text(json.dumps({"entries": [
                {"spoken": "equals = sign", "written": "a=b"},
            ]}))
            with patch.object(app, "VOCABULARY_PATH", vocabulary):
                self.assertEqual(
                    app.load_vocabulary(),
                    [{"spoken": "equals = sign", "written": "a=b"}],
                )

    def test_unreadable_text_is_ignored(self):
        with tempfile.TemporaryDirectory() as directory:
            vocabulary = Path(directory) / "vocabulary.json"
            vocabulary.write_bytes(b"\xff\xfe")
            with patch.object(app, "VOCABULARY_PATH", vocabulary):
                self.assertEqual(app.load_vocabulary(), [])

    def test_replaces_whole_words_without_chaining(self):
        entries = [
            {"spoken": "yana", "written": "Janne"},
            {"spoken": "Janne", "written": "Someone else"},
        ]
        self.assertEqual(
            app.apply_vocabulary("Yana met yanas yesterday.", entries),
            "Janne met yanas yesterday.",
        )

    def test_last_duplicate_rule_wins(self):
        entries = [
            {"spoken": "yana", "written": "First"},
            {"spoken": "Yana", "written": "Janne"},
        ]
        self.assertEqual(app.apply_vocabulary("yana", entries), "Janne")

    def test_prefers_longer_phrases(self):
        entries = [
            {"spoken": "new", "written": "old"},
            {"spoken": "new york", "written": "New York"},
        ]
        self.assertEqual(app.apply_vocabulary("new york", entries), "New York")

    def test_unusual_unicode_case_match_does_not_crash(self):
        entries = [{"spoken": "i", "written": "me"}]
        self.assertEqual(app.apply_vocabulary("İ", entries), "İ")

    def test_matches_unicode_case_fold_expansions(self):
        entries = [{"spoken": "Straße", "written": "Street"}]
        self.assertEqual(app.apply_vocabulary("STRAẞE", entries), "Street")


class TranscriptionOptionTests(unittest.TestCase):
    def test_validates_models_modes_punctuation_and_languages(self):
        self.assertEqual(
            app._transcription_options("qwen", "standard", "spoken", "french"),
            ("standard", "spoken", "French"),
        )
        self.assertEqual(
            app._transcription_options("compact", "verbatim", "none", "auto"),
            ("verbatim", "none", "auto"),
        )
        with self.assertRaisesRegex(ValueError, "Parakeet"):
            app._transcription_options("compact", "standard", "automatic", "French")
        for mode, punctuation, language in (
            ("edited", "automatic", "English"),
            ("standard", "sometimes", "English"),
            ("standard", "automatic", "Klingon"),
        ):
            with self.assertRaises(ValueError):
                app._transcription_options("qwen", mode, punctuation, language)

    def test_qwen_auto_and_named_language_reach_model(self):
        class FakeAudio:
            def __truediv__(self, _divisor):
                return self

        model = Mock()
        model.generate.return_value = types.SimpleNamespace(text=" bonjour ")
        mlx = types.ModuleType("mlx")
        mlx_core = types.ModuleType("mlx.core")
        mlx_core.float32 = object()
        mlx_core.array = lambda _samples, dtype: FakeAudio()
        mlx.core = mlx_core
        selected = {"id": "test", "backend": "qwen"}
        with patch.dict("sys.modules", {"mlx": mlx, "mlx.core": mlx_core}), patch.object(
            app, "_load_model", return_value=(model, selected)
        ):
            self.assertEqual(app._generate_transcript(array("h", [1]), "qwen", "/x", "auto"), "bonjour")
            self.assertEqual(app._generate_transcript(array("h", [1]), "qwen", "/x", "French"), "bonjour")
        self.assertEqual(
            [call.kwargs["language"] for call in model.generate.call_args_list],
            [None, "French"],
        )

    def test_spoken_commands_and_punctuation_modes(self):
        self.assertEqual(
            app.apply_spoken_formatting(
                "Hello, comma world period new paragraph next question mark", "spoken"
            ),
            "Hello, world.\n\nnext?",
        )
        self.assertEqual(
            app.apply_spoken_formatting("Hello, world! new line Next.", "none"),
            "Hello world\nNext",
        )
        self.assertEqual(
            app.apply_spoken_formatting("Hello, new line world!", "automatic"),
            "Hello,\nworld!",
        )
        self.assertEqual(app.apply_spoken_formatting("new paragraph", "automatic"), "\n\n")
        self.assertEqual(app.apply_spoken_formatting("new line hello", "automatic"), "\nhello")
        self.assertEqual(app.apply_spoken_formatting("hello new line", "automatic"), "hello\n")
        self.assertEqual(
            app.apply_spoken_formatting("don't stop l’amour state-of-the-art!", "none"),
            "don't stop l’amour state-of-the-art",
        )

    def test_standard_applies_vocabulary_snippets_and_commands_but_verbatim_does_not(self):
        with history_environment(), patch.object(
            app, "decode_pcm_wav", return_value=array("h", [1])
        ), patch.object(
            app, "_installed_model_snapshots", return_value={"qwen": Path("/cache/qwen")}
        ), patch.object(
            app, "_generate_transcript", return_value="yana signature new line thanks period"
        ), patch.object(
            app, "vocabulary_for_origin", return_value=[{"spoken": "yana", "written": "Janne"}]
        ), patch.object(
            app, "load_snippets", return_value=[{"id": "one", "trigger": "signature", "content": "Best regards"}]
        ), patch.object(app, "apply_retention", return_value=0):
            standard = app.transcribe(
                make_wav(), "qwen", mode="standard", punctuation="spoken"
            )
            verbatim = app.transcribe(
                make_wav(), "qwen", mode="verbatim", punctuation="none"
            )
        self.assertEqual(standard["text"], "Janne Best regards\nthanks.")
        self.assertEqual(standard["raw_text"], "yana signature new line thanks period")
        self.assertEqual(verbatim["text"], "yana signature new line thanks period")
        self.assertNotIn("raw_text", verbatim)

    def test_commands_do_not_rewrite_vocabulary_or_snippet_content(self):
        text = app.apply_spoken_formatting("signature new line name", "automatic")
        text = app.apply_vocabulary(text, [{"spoken": "name", "written": "new paragraph"}])
        text = app.apply_snippets(text, [{
            "id": "one", "trigger": "signature", "content": "first new line second",
        }])
        self.assertEqual(text, "first new line second\nnew paragraph")


class SnippetTests(unittest.TestCase):
    def test_crud_persists_atomically_and_applies_longest_trigger(self):
        with history_environment():
            first = app.save_snippet({"trigger": "my address", "content": "1 Main Street"})
            second = app.save_snippet({"id": "short", "trigger": "address", "content": "wrong"})
            self.assertEqual(app.load_snippets(), [first, second])
            self.assertEqual(
                app.apply_snippets("Send to my address.", app.load_snippets()),
                "Send to 1 Main Street.",
            )
            updated = app.save_snippet({
                "id": first["id"], "trigger": "home address", "content": "2 Side Street"
            })
            self.assertEqual(len(app.load_snippets()), 2)
            self.assertEqual(app.load_snippets()[-1], updated)
            self.assertTrue(app.delete_snippet("short"))
            self.assertFalse(app.delete_snippet("missing"))
            self.assertEqual(app.load_snippets(), [updated])

    def test_malformed_store_is_not_overwritten(self):
        with history_environment():
            app.SNIPPETS_PATH.write_text("not json")
            self.assertEqual(app.load_snippets(), [])
            with self.assertRaisesRegex(ValueError, "malformed"):
                app.save_snippet({"trigger": "hello", "content": "world"})
            self.assertEqual(app.SNIPPETS_PATH.read_text(), "not json")

    def test_duplicate_triggers_are_rejected_case_insensitively(self):
        with history_environment():
            app.save_snippet({"id": "one", "trigger": "Straße", "content": "First"})
            with self.assertRaisesRegex(ValueError, "unique"):
                app.save_snippet({"id": "two", "trigger": " STRASSE ", "content": "Second"})
            self.assertEqual([item["id"] for item in app.load_snippets()], ["one"])

    def test_duplicate_ids_make_store_read_only(self):
        with history_environment():
            app.SNIPPETS_PATH.write_text(json.dumps({"version": 1, "snippets": [
                {"id": "same", "trigger": "one", "content": "First"},
                {"id": "same", "trigger": "two", "content": "Second"},
            ]}))
            with self.assertRaisesRegex(ValueError, "unique"):
                app.save_snippet({"id": "new", "trigger": "three", "content": "Third"})


class WorkerEntryTests(unittest.TestCase):
    def test_configure_paths_relocates_snippets_with_other_mutable_data(self):
        with history_environment(), tempfile.TemporaryDirectory() as directory, patch.dict(
            app.os.environ,
            {"TIRO_DATA_DIR": f"{directory}/data", "TIRO_MODEL_DIR": f"{directory}/models"},
        ):
            worker_entry.configure_paths()
            self.assertEqual(
                app.SNIPPETS_PATH, Path(directory).resolve() / "data/snippets.json"
            )


class ProfileVocabularyTests(unittest.TestCase):
    def test_global_fallback_and_exact_bundle_override(self):
        with history_environment():
            app.VOCABULARY_PATH.write_text(json.dumps({"entries": [
                {"spoken": "yana", "written": "Global"},
                {"spoken": "shared", "written": "Everywhere"},
            ]}))
            app.PROFILES_PATH.write_text(json.dumps({"version": 1, "profiles": [{
                "bundle_id": "com.example.editor",
                "name": "Editor",
                "entries": [{"spoken": "YANA", "written": "Profile"}],
            }]}))

            self.assertEqual(
                app.apply_vocabulary(
                    "yana shared", app.vocabulary_for_origin("com.example.editor")
                ),
                "Profile Everywhere",
            )
            self.assertEqual(
                app.apply_vocabulary(
                    "yana shared", app.vocabulary_for_origin("com.example.other")
                ),
                "Global Everywhere",
            )

    def test_last_duplicate_profile_and_entry_wins(self):
        with history_environment():
            app.PROFILES_PATH.write_text(json.dumps({"version": 1, "profiles": [
                {"bundle_id": "app", "name": "Old", "entries": [
                    {"spoken": "term", "written": "Old"},
                ]},
                {"bundle_id": "app", "name": "New", "entries": [
                    {"spoken": "term", "written": "First"},
                    {"spoken": "TERM", "written": "Last"},
                ]},
            ]}))
            self.assertEqual(
                app.apply_vocabulary("term", app.vocabulary_for_origin("app")),
                "Last",
            )

    def test_malformed_profiles_and_entries_are_ignored(self):
        with history_environment():
            app.PROFILES_PATH.write_text(json.dumps({"version": 1, "profiles": [
                "bad",
                {"bundle_id": 4, "name": "Bad", "entries": []},
                {"bundle_id": "valid", "name": "Valid", "entries": [
                    {"spoken": "ok", "written": "Good"},
                    {"spoken": "bad", "written": ""},
                ]},
            ]}))
            self.assertEqual(app.load_profiles(), {"version": 1, "profiles": [{
                "bundle_id": "valid",
                "name": "Valid",
                "entries": [{"spoken": "ok", "written": "Good"}],
            }]})
            app.PROFILES_PATH.write_text("not json")
            self.assertEqual(app.load_profiles(), {"version": 1, "profiles": []})

    def test_profile_replacement_validates_and_writes_atomically(self):
        with history_environment():
            document = {"version": 1, "profiles": [{
                "bundle_id": " app ", "name": " Name ",
                "entries": [{"spoken": " old ", "written": " new "}],
            }]}
            saved = app.save_profiles(document)
            self.assertEqual(saved["profiles"][0]["bundle_id"], "app")
            self.assertEqual(json.loads(app.PROFILES_PATH.read_text()), saved)
            with self.assertRaisesRegex(ValueError, "version"):
                app.save_profiles({"version": 2, "profiles": []})


class CorrectionSuggestionTests(unittest.TestCase):
    def _write_entry(self, entry_id, text, bundle_id="app", name="Editor"):
        entry = {
            "id": entry_id,
            "text": text,
            "raw_text": "model output",
            "model": "model-id",
            "origin_bundle_id": bundle_id,
            "origin_app_name": name,
            "unknown": {"kept": True},
        }
        with app.HISTORY_PATH.open("a", encoding="utf-8") as output:
            output.write(json.dumps(entry) + "\n")

    def test_correction_preserves_raw_model_unknown_and_malformed_lines(self):
        with history_environment():
            app.HISTORY_PATH.write_text("malformed line\n")
            self._write_entry("one", "hello yana")
            self.assertTrue(app.correct_history_entry("one", "hello Janne"))
            lines = app.HISTORY_PATH.read_text().splitlines()
            self.assertEqual(lines[0], "malformed line")
            updated = json.loads(lines[1])
            self.assertEqual(updated["corrected_text"], "hello Janne")
            self.assertEqual(updated["raw_text"], "model output")
            self.assertEqual(updated["model"], "model-id")
            self.assertEqual(updated["unknown"], {"kept": True})

    def test_repetition_deduplicates_and_counts_distinct_transcriptions(self):
        with history_environment():
            self._write_entry("one", "hello yana")
            self._write_entry("two", "hello yana")
            app.correct_history_entry("one", "hello Janne")
            app.correct_history_entry("one", "hello Janne")
            self.assertEqual(app.get_suggestions(), [])
            app.correct_history_entry("two", "hello janne")
            suggestions = app.get_suggestions()
            self.assertEqual(len(suggestions), 1)
            self.assertEqual(suggestions[0]["count"], 2)
            self.assertEqual(suggestions[0]["spoken"], "yana")
            self.assertEqual(suggestions[0]["origin_bundle_id"], "app")

    def test_same_replacement_in_different_apps_does_not_merge(self):
        with history_environment():
            for entry_id, bundle in (("one", "app.one"), ("two", "app.two")):
                self._write_entry(entry_id, "hello yana", bundle)
                app.correct_history_entry(entry_id, "hello Janne")
            document = json.loads(app.SUGGESTIONS_PATH.read_text())
            self.assertEqual(len(document["suggestions"]), 2)
            self.assertTrue(all(item["count"] == 1 for item in document["suggestions"]))

    def test_correction_folds_an_id_out_of_its_previous_candidate(self):
        with history_environment():
            self._write_entry("one", "hello yana")
            app.correct_history_entry("one", "hello Janne")
            app.correct_history_entry("one", "hello Yana")
            self.assertEqual(json.loads(app.SUGGESTIONS_PATH.read_text())["suggestions"], [])

    def test_rejects_insert_delete_punctuation_long_ambiguous_and_multiple_changes(self):
        cases = [
            ("hello world", "hello brave world"),
            ("hello brave world", "hello world"),
            ("hello world", "hello, world!"),
            ("one two three four", "five six seven eight"),
            ("yana and yana", "Janne and yana"),
            ("alpha middle omega", "beta middle delta"),
        ]
        with history_environment():
            for index, (before, after) in enumerate(cases):
                self._write_entry(str(index), before)
                app.correct_history_entry(str(index), after)
            self.assertEqual(json.loads(app.SUGGESTIONS_PATH.read_text())["suggestions"], [])

    def test_already_covered_vocabulary_is_not_suggested(self):
        with history_environment():
            app.VOCABULARY_PATH.write_text(json.dumps({"entries": [
                {"spoken": "yana", "written": "Janne"},
            ]}))
            self._write_entry("one", "hello yana")
            app.correct_history_entry("one", "hello Janne")
            self.assertEqual(app.get_suggestions(), [])

    def test_accept_global_writes_rule_and_hides_suggestion(self):
        with history_environment():
            for entry_id in ("one", "two"):
                self._write_entry(entry_id, "hello yana")
                app.correct_history_entry(entry_id, "hello Janne")
            suggestion_id = app.get_suggestions()[0]["id"]
            self.assertTrue(app.accept_suggestion(suggestion_id, "global"))
            self.assertEqual(app.load_vocabulary(), [{"spoken": "yana", "written": "Janne"}])
            self.assertEqual(app.get_suggestions(), [])

    def test_accept_profile_writes_exact_origin_rule(self):
        with history_environment():
            for entry_id in ("one", "two"):
                self._write_entry(entry_id, "hello yana", "com.editor", "Editor")
                app.correct_history_entry(entry_id, "hello Janne")
            suggestion_id = app.get_suggestions()[0]["id"]
            self.assertTrue(app.accept_suggestion(suggestion_id, "profile"))
            profile = app.load_profiles()["profiles"][0]
            self.assertEqual(profile["bundle_id"], "com.editor")
            self.assertEqual(profile["entries"], [{"spoken": "yana", "written": "Janne"}])
            self.assertEqual(app.load_vocabulary(), [])

    def test_dismiss_persists_and_hides_suggestion(self):
        with history_environment():
            for entry_id in ("one", "two"):
                self._write_entry(entry_id, "hello yana")
                app.correct_history_entry(entry_id, "hello Janne")
            suggestion_id = app.get_suggestions()[0]["id"]
            self.assertTrue(app.dismiss_suggestion(suggestion_id))
            self.assertEqual(app.get_suggestions(), [])
            stored = json.loads(app.SUGGESTIONS_PATH.read_text())["suggestions"][0]
            self.assertTrue(stored["dismissed"])

    def test_uses_raw_spoken_form_when_vocabulary_changed_delivered_text(self):
        with history_environment():
            app.VOCABULARY_PATH.write_text(json.dumps({"entries": [
                {"spoken": "yana", "written": "Jane"},
            ]}))
            for entry_id in ("one", "two"):
                self._write_entry(entry_id, "hello Jane")
            lines = [json.loads(line) for line in app.HISTORY_PATH.read_text().splitlines()]
            for entry in lines:
                entry["raw_text"] = "hello yana"
            app.HISTORY_PATH.write_text("".join(json.dumps(entry) + "\n" for entry in lines))
            app.correct_history_entry("one", "hello Janne")
            app.correct_history_entry("two", "hello Janne")

            suggestion = app.get_suggestions()[0]
            self.assertEqual((suggestion["spoken"], suggestion["written"]), ("yana", "Janne"))

    def test_terminal_decisions_are_idempotent_and_cannot_be_reversed(self):
        with history_environment():
            for entry_id in ("one", "two"):
                self._write_entry(entry_id, "hello yana")
                app.correct_history_entry(entry_id, "hello Janne")
            suggestion_id = app.get_suggestions()[0]["id"]

            self.assertEqual(app.accept_suggestion(suggestion_id, "global"), "global")
            self.assertEqual(app.accept_suggestion(suggestion_id, "profile"), "global")
            self.assertFalse(app.PROFILES_PATH.exists())
            app.delete_history_entry("one")
            app.delete_history_entry("two")
            self.assertEqual(app.accept_suggestion(suggestion_id, "profile"), "global")
            with self.assertRaisesRegex(ValueError, "already accepted"):
                app.dismiss_suggestion(suggestion_id)

        with history_environment():
            for entry_id in ("one", "two"):
                self._write_entry(entry_id, "hello yana")
                app.correct_history_entry(entry_id, "hello Janne")
            suggestion_id = app.get_suggestions()[0]["id"]
            self.assertTrue(app.dismiss_suggestion(suggestion_id))
            self.assertTrue(app.dismiss_suggestion(suggestion_id))
            with self.assertRaisesRegex(ValueError, "already dismissed"):
                app.accept_suggestion(suggestion_id, "global")

    def test_global_accept_rejects_capacity_and_malformed_source_without_changes(self):
        with history_environment():
            for entry_id in ("one", "two"):
                self._write_entry(entry_id, "hello yana")
                app.correct_history_entry(entry_id, "hello Janne")
            suggestion_id = app.get_suggestions()[0]["id"]
            full = {"entries": [
                {"spoken": f"term {index}", "written": f"value {index}"}
                for index in range(app.MAX_VOCABULARY_ENTRIES)
            ]}
            original = json.dumps(full)
            app.VOCABULARY_PATH.write_text(original)
            with self.assertRaisesRegex(ValueError, "capacity"):
                app.accept_suggestion(suggestion_id, "global")
            self.assertEqual(app.VOCABULARY_PATH.read_text(), original)

            malformed = '{"entries":[{"spoken":"broken"}]}'
            app.VOCABULARY_PATH.write_text(malformed)
            with self.assertRaisesRegex(ValueError, "spoken and written"):
                app.accept_suggestion(suggestion_id, "global")
            self.assertEqual(app.VOCABULARY_PATH.read_text(), malformed)

            over_limit = json.dumps({"entries": [
                {"spoken": f"term {index}", "written": f"value {index}"}
                for index in range(app.MAX_VOCABULARY_ENTRIES + 1)
            ]})
            app.VOCABULARY_PATH.write_text(over_limit)
            with self.assertRaisesRegex(ValueError, "at most"):
                app.accept_suggestion(suggestion_id, "global")
            self.assertEqual(app.VOCABULARY_PATH.read_text(), over_limit)

    def test_profile_accept_rejects_entry_and_profile_capacity_without_changes(self):
        with history_environment():
            for entry_id in ("one", "two"):
                self._write_entry(entry_id, "hello yana", "target", "Target")
                app.correct_history_entry(entry_id, "hello Janne")
            suggestion_id = app.get_suggestions()[0]["id"]
            full_entries = {"version": 1, "profiles": [{
                "bundle_id": "target",
                "name": "Target",
                "entries": [
                    {"spoken": f"term {index}", "written": f"value {index}"}
                    for index in range(app.MAX_VOCABULARY_ENTRIES)
                ],
            }]}
            original = json.dumps(full_entries)
            app.PROFILES_PATH.write_text(original)
            with self.assertRaisesRegex(ValueError, "capacity"):
                app.accept_suggestion(suggestion_id, "profile")
            self.assertEqual(app.PROFILES_PATH.read_text(), original)

            full_profiles = {"version": 1, "profiles": [
                {"bundle_id": f"app.{index}", "name": "App", "entries": []}
                for index in range(app.MAX_PROFILES)
            ]}
            original = json.dumps(full_profiles)
            app.PROFILES_PATH.write_text(original)
            with self.assertRaisesRegex(ValueError, "profile capacity"):
                app.accept_suggestion(suggestion_id, "profile")
            self.assertEqual(app.PROFILES_PATH.read_text(), original)

    def test_correction_recovers_when_suggestion_cache_write_is_interrupted(self):
        with history_environment():
            self._write_entry("one", "hello yana")
            self._write_entry("two", "hello yana")
            app.correct_history_entry("one", "hello Janne")
            with patch.object(
                app, "_save_suggestions_locked", side_effect=OSError("interrupted")
            ):
                self.assertTrue(app.correct_history_entry("two", "hello Janne"))
            persisted = [json.loads(line) for line in app.HISTORY_PATH.read_text().splitlines()]
            self.assertEqual(persisted[1]["corrected_text"], "hello Janne")
            self.assertEqual(app.get_suggestions()[0]["count"], 2)

    def test_accept_retry_in_another_scope_keeps_interrupted_intended_scope(self):
        with history_environment():
            for entry_id in ("one", "two"):
                self._write_entry(entry_id, "hello yana")
                app.correct_history_entry(entry_id, "hello Janne")
            suggestion_id = app.get_suggestions()[0]["id"]
            real_save = app._save_suggestions_locked
            save_count = 0

            def fail_terminal_save(document):
                nonlocal save_count
                save_count += 1
                if save_count == 2:
                    raise OSError("interrupted")
                return real_save(document)

            with patch.object(
                app, "_save_suggestions_locked", side_effect=fail_terminal_save
            ):
                with self.assertRaisesRegex(OSError, "interrupted"):
                    app.accept_suggestion(suggestion_id, "global")
            self.assertEqual(app.load_vocabulary(), [{"spoken": "yana", "written": "Janne"}])
            pending = json.loads(app.SUGGESTIONS_PATH.read_text())["suggestions"][0]
            self.assertEqual(pending["accepting_scope"], "global")
            self.assertEqual(app.get_suggestions(), [])
            self.assertEqual(app.accept_suggestion(suggestion_id, "profile"), "global")
            self.assertFalse(app.PROFILES_PATH.exists())
            stored = json.loads(app.SUGGESTIONS_PATH.read_text())["suggestions"][0]
            self.assertTrue(stored["accepted"])
            self.assertEqual(stored["accepted_scope"], "global")
            self.assertNotIn("accepting_scope", stored)

    def test_malformed_suggestion_state_fails_closed_without_erasing_decisions(self):
        with history_environment():
            for entry_id in ("one", "two"):
                self._write_entry(entry_id, "hello yana")
                app.correct_history_entry(entry_id, "hello Janne")
            suggestion_id = app.get_suggestions()[0]["id"]
            app.accept_suggestion(suggestion_id, "global")
            document = json.loads(app.SUGGESTIONS_PATH.read_text())
            document["suggestions"].append({"broken": True})
            corrupted = json.dumps(document)
            app.SUGGESTIONS_PATH.write_text(corrupted)

            with self.assertRaisesRegex(ValueError, "suggestion"):
                app.get_suggestions()
            self.assertEqual(app.SUGGESTIONS_PATH.read_text(), corrupted)
            self.assertTrue(document["suggestions"][0]["accepted"])

        with history_environment():
            for entry_id in ("one", "two"):
                self._write_entry(entry_id, "hello yana")
                app.correct_history_entry(entry_id, "hello Janne")
            suggestion_id = app.get_suggestions()[0]["id"]
            app.dismiss_suggestion(suggestion_id)
            original = app.SUGGESTIONS_PATH.read_text()
            app.SUGGESTIONS_PATH.write_text("not json")
            with self.assertRaisesRegex(ValueError, "malformed"):
                app.get_suggestions()
            self.assertEqual(app.SUGGESTIONS_PATH.read_text(), "not json")
            self.assertIn('"dismissed":true', original)

    def test_legacy_history_origins_cannot_create_invalid_profiles(self):
        with history_environment():
            for entry_id in ("one", "two"):
                self._write_entry(
                    entry_id,
                    "hello yana",
                    "x" * (app.MAX_ORIGIN_BUNDLE_ID + 1),
                    "y" * (app.MAX_ORIGIN_APP_NAME + 1),
                )
                app.correct_history_entry(entry_id, "hello Janne")
            suggestion = app.get_suggestions()[0]
            self.assertIsNone(suggestion["origin_bundle_id"])
            self.assertIsNone(suggestion["origin_app_name"])
            with self.assertRaisesRegex(ValueError, "valid origin bundle"):
                app.accept_suggestion(suggestion["id"], "profile")
            self.assertFalse(app.PROFILES_PATH.exists())

        with history_environment():
            for entry_id in ("one", "two"):
                self._write_entry(
                    entry_id,
                    "hello yana",
                    "com.valid",
                    "y" * (app.MAX_ORIGIN_APP_NAME + 1),
                )
                app.correct_history_entry(entry_id, "hello Janne")
            suggestion = app.get_suggestions()[0]
            self.assertIsNone(suggestion["origin_app_name"])
            self.assertEqual(app.accept_suggestion(suggestion["id"], "profile"), "profile")
            profiles = app._load_profiles_strict()
            self.assertEqual(profiles["profiles"][0]["name"], "")

    def test_delete_and_retention_remove_stale_suggestion_evidence(self):
        with history_environment():
            self._write_entry("one", "hello yana")
            self._write_entry("two", "hello yana")
            app.correct_history_entry("one", "hello Janne")
            app.correct_history_entry("two", "hello Janne")
            self.assertTrue(app.delete_history_entry("one"))
            stored = json.loads(app.SUGGESTIONS_PATH.read_text())["suggestions"][0]
            self.assertEqual(stored["transcription_ids"], ["two"])
            self.assertEqual(app.get_suggestions(), [])

        with history_environment():
            for entry_id in ("one", "two"):
                self._write_entry(entry_id, "hello yana")
                app.correct_history_entry(entry_id, "hello Janne")
            lines = [json.loads(line) for line in app.HISTORY_PATH.read_text().splitlines()]
            lines[0]["timestamp"] = "2000-01-01T00:00:00Z"
            lines[1]["timestamp"] = "2999-01-01T00:00:00Z"
            app.HISTORY_PATH.write_text("".join(json.dumps(entry) + "\n" for entry in lines))
            self.assertEqual(app.apply_retention(7), 1)
            stored = json.loads(app.SUGGESTIONS_PATH.read_text())["suggestions"][0]
            self.assertEqual(stored["transcription_ids"], ["two"])


class ModelExecutorTests(unittest.TestCase):
    def test_preload_and_transcription_share_one_model_thread(self):
        caller_threads = []
        model_threads = []

        def record_preload(_):
            model_threads.append(threading.get_ident())
            return {"loaded_model": "test-model"}

        def record_transcription(*_):
            model_threads.append(threading.get_ident())
            return {"text": "hello"}

        def call_preload():
            caller_threads.append(threading.get_ident())
            app.preload_model("compact")

        def call_transcription():
            caller_threads.append(threading.get_ident())
            app.transcribe(b"wav", "compact")

        with patch.object(app, "_preload_model", side_effect=record_preload), \
             patch.object(app, "_transcribe", side_effect=record_transcription):
            preload_thread = threading.Thread(target=call_preload)
            transcription_thread = threading.Thread(target=call_transcription)
            preload_thread.start()
            preload_thread.join(timeout=1)
            transcription_thread.start()
            transcription_thread.join(timeout=1)

        self.assertFalse(preload_thread.is_alive())
        self.assertFalse(transcription_thread.is_alive())
        self.assertEqual(len(set(model_threads)), 1)
        self.assertNotIn(model_threads[0], caller_threads)

    def test_worker_closes_executor_before_releasing_port(self):
        events = []
        executor = Mock()
        executor.shutdown.side_effect = lambda **_: events.append("executor")
        server = Mock()
        server.server_close.side_effect = lambda: events.append("server")

        with patch.object(app, "_model_executor", executor):
            app._close_worker(server)

        executor.shutdown.assert_called_once_with(wait=True, cancel_futures=True)
        server.server_close.assert_called_once_with()
        self.assertEqual(events, ["executor", "server"])

    def test_queued_transcription_runs_between_comparison_models(self):
        first_model_started = threading.Event()
        transcription_queued = threading.Event()
        release_first_model = threading.Event()
        prior_model = object()
        compact_model = object()
        qwen_model = object()
        order = []
        errors = []

        def generate(_samples, model_key, _source):
            app._model = compact_model if model_key == "compact" else qwen_model
            app._model_id = app.MODELS[model_key]["id"]
            order.append(model_key)
            if model_key == "compact":
                first_model_started.set()
                self.assertTrue(release_first_model.wait(1))
            return model_key

        def transcribe(*_):
            self.assertIs(app._model, compact_model)
            app._model_generation += 1
            order.append("transcription")
            return {"text": "hello"}

        original_submit = app._model_executor.submit

        def submit(operation, *args):
            future = original_submit(operation, *args)
            if operation is transcribe:
                transcription_queued.set()
            return future

        def compare():
            try:
                app.compare_history_models("entry", ["compact", "qwen"])
            except Exception as exc:
                errors.append(exc)

        with patch.object(app, "_history_audio", return_value=make_wav()), \
             patch.object(app, "_history_language", return_value="English"), \
             patch.object(
                 app,
                 "_installed_model_snapshots",
                 side_effect=lambda keys: {key: Path("/cache") for key in keys},
             ), patch.object(app, "_generate_transcript", side_effect=generate), \
             patch.object(app, "_transcribe", new=transcribe), \
             patch.object(app._model_executor, "submit", side_effect=submit), \
             patch.object(app, "_model", prior_model), \
             patch.object(app, "_model_id", "prior-model"), \
             patch.object(app, "_model_generation", 0), \
             patch.object(
                 app,
                 "_clear_loaded_model",
                 side_effect=lambda: (
                     setattr(app, "_model", None),
                     setattr(app, "_model_id", None),
                 ),
             ):
            comparison_thread = threading.Thread(target=compare)
            comparison_thread.start()
            self.assertTrue(first_model_started.wait(1))
            transcription_thread = threading.Thread(
                target=app.transcribe, args=(b"wav", "compact")
            )
            transcription_thread.start()
            self.assertTrue(transcription_queued.wait(1))
            release_first_model.set()
            comparison_thread.join(timeout=2)
            transcription_thread.join(timeout=2)
            self.assertIs(app._model, compact_model)
            self.assertEqual(app._model_id, app.MODELS["compact"]["id"])

        self.assertFalse(comparison_thread.is_alive())
        self.assertFalse(transcription_thread.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(order, ["compact", "transcription", "qwen"])


class PreloadTests(unittest.TestCase):
    def test_preload_loads_requested_model(self):
        selected = {"id": app.MODELS["compact"]["id"]}
        snapshot = Path("/cache/compact")
        with patch.object(
            app, "_installed_model_snapshots", return_value={"compact": snapshot}
        ), patch.object(app, "_load_model", return_value=(object(), selected)) as loader:
            payload = app.preload_model("compact")
        loader.assert_called_once_with("compact", snapshot)
        self.assertEqual(payload, {"loaded_model": selected["id"]})

    def test_preload_uses_the_inference_operation_lock(self):
        started = threading.Event()

        def load(_, __):
            started.set()
            return object(), {"id": "test-model"}

        with patch.object(
            app,
            "_installed_model_snapshots",
            return_value={"compact": Path("/cache/compact")},
        ), patch.object(app, "_load_model", side_effect=load):
            app._operation_lock.acquire()
            try:
                thread = threading.Thread(target=app.preload_model, args=("compact",))
                thread.start()
                self.assertFalse(started.wait(0.05))
            finally:
                app._operation_lock.release()
            thread.join(timeout=1)
        self.assertTrue(started.is_set())

    def test_preload_rejects_an_unknown_model(self):
        with self.assertRaisesRegex(ValueError, "canonical model key"):
            app.preload_model("missing")

    def test_preload_rejects_uninstalled_model_without_loading(self):
        with patch.object(app, "_cached_models", return_value={
            key: {"installed": False, "snapshot_path": None} for key in app.MODELS
        }), patch.object(app, "_load_model") as loader:
            with self.assertRaisesRegex(app.HTTPError, "installed before use"):
                app.preload_model("compact")
        loader.assert_not_called()


class ModelManagementTests(unittest.TestCase):
    def setUp(self):
        app._model_downloads.clear()

    def tearDown(self):
        app._model_downloads.clear()

    @staticmethod
    def cache_info(*keys):
        repos = []
        for index, key in enumerate(keys):
            revision = types.SimpleNamespace(
                commit_hash=f"commit-{key}",
                snapshot_path=Path(f"/cache/{key}"),
                last_modified=index,
            )
            repos.append(types.SimpleNamespace(
                repo_id=app.MODELS[key]["id"],
                repo_type="model",
                size_on_disk=1000 + index,
                revisions=[revision],
            ))
        return types.SimpleNamespace(repos=repos)

    def test_status_is_canonical_and_does_not_download(self):
        cache = self.cache_info("compact")
        app._model_downloads["qwen"] = {"downloading": True, "error": None}
        with patch.object(app, "_model_cache_info", return_value=cache), patch(
            "huggingface_hub.snapshot_download"
        ) as download, patch.object(app, "_model_id", app.MODELS["compact"]["id"]):
            models = app.model_status()

        self.assertEqual([model["key"] for model in models], list(app.MODELS))
        compact = models[0]
        self.assertTrue(compact["installed"])
        self.assertTrue(compact["loaded"])
        self.assertEqual(compact["installed_size_bytes"], 1000)
        self.assertGreater(compact["download_size_bytes"], 0)
        self.assertTrue(models[2]["downloading"])
        download.assert_not_called()

    def test_fresh_missing_cache_reports_available_and_first_download_works(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(
            app, "MODEL_HUB_CACHE", Path(directory) / "missing" / "hub"
        ), patch("huggingface_hub.snapshot_download") as download:
            models = app.model_status()
            downloaded = app.download_model("compact")

        self.assertTrue(downloaded)
        self.assertTrue(all(model["state"] == "available" for model in models))
        self.assertTrue(all(not model["installed"] for model in models))
        download.assert_called_once_with(
            repo_id=app.MODELS["compact"]["id"],
            cache_dir=Path(directory) / "missing" / "hub",
        )

    def test_download_uses_canonical_repo_and_cache(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(
            app, "MODEL_HUB_CACHE", Path(directory) / "hub"
        ), patch.object(app, "_cached_models", return_value={
            key: {"installed": False} for key in app.MODELS
        }), patch("huggingface_hub.snapshot_download") as download:
            self.assertTrue(app.download_model("compact"))

        download.assert_called_once_with(
            repo_id=app.MODELS["compact"]["id"],
            cache_dir=Path(directory) / "hub",
        )
        self.assertEqual(
            app._model_downloads["compact"],
            {"downloading": False, "deleting": False, "error": None},
        )

    def test_download_never_runs_for_installed_or_concurrent_model(self):
        with patch.object(app, "_cached_models", return_value={
            key: {"installed": key == "compact"} for key in app.MODELS
        }), patch("huggingface_hub.snapshot_download") as download:
            self.assertFalse(app.download_model("compact"))
            app._model_downloads["qwen"] = {"downloading": True, "error": None}
            with self.assertRaisesRegex(app.HTTPError, "operation is already running"):
                app.download_model("qwen")
        download.assert_not_called()

    def test_download_failure_clears_downloading_and_is_reported_as_state_only(self):
        missing = {
            key: {
                "installed": False,
                "installed_size_bytes": 0,
            }
            for key in app.MODELS
        }
        with patch.object(app, "_cached_models", return_value=missing), patch(
            "huggingface_hub.snapshot_download", side_effect=OSError("private path detail")
        ), patch("builtins.print"):
            with self.assertRaises(OSError):
                app.download_model("compact")
            models = app.model_status()

        self.assertFalse(app._model_downloads["compact"]["downloading"])
        compact = models[0]
        self.assertEqual(compact["state"], "error")
        self.assertNotIn("download_error", compact)

    def test_download_does_not_hold_inference_lock_and_blocks_delete(self):
        entered = threading.Event()
        release = threading.Event()

        def download_snapshot(**_):
            entered.set()
            self.assertTrue(release.wait(1))

        missing = {
            key: {"installed": False} for key in app.MODELS
        }
        with patch.object(app, "_cached_models", return_value=missing), patch(
            "huggingface_hub.snapshot_download", side_effect=download_snapshot
        ):
            thread = threading.Thread(target=app.download_model, args=("compact",))
            thread.start()
            self.assertTrue(entered.wait(1))
            self.assertTrue(app._operation_lock.acquire(blocking=False))
            app._operation_lock.release()
            with self.assertRaisesRegex(app.HTTPError, "operation is already running"):
                app.delete_model("compact")
            release.set()
            thread.join(1)
        self.assertFalse(thread.is_alive())

    def test_delete_claim_blocks_download_before_waiting_for_inference(self):
        cache = self.cache_info("compact")
        strategy = types.SimpleNamespace(expected_freed_size=10, execute=Mock())
        cache.delete_revisions = Mock(return_value=strategy)
        finished = threading.Event()

        app._operation_lock.acquire()
        try:
            with patch.object(app, "_model_id", None), patch.object(
                app, "_model_cache_info", return_value=cache
            ):
                thread = threading.Thread(
                    target=lambda: (app.delete_model("compact"), finished.set())
                )
                thread.start()
                for _ in range(100):
                    with app._model_download_lock:
                        if app._model_downloads.get("compact", {}).get("deleting"):
                            break
                    time.sleep(0.005)
                else:
                    self.fail("delete did not claim model state")
                with self.assertRaisesRegex(app.HTTPError, "operation is already running"):
                    app.download_model("compact")
                self.assertFalse(finished.is_set())
        finally:
            app._operation_lock.release()
        thread.join(1)
        self.assertTrue(finished.is_set())

    def test_local_snapshot_source_is_passed_to_both_backend_loaders(self):
        qwen_load = Mock(return_value=object())
        qwen_package = types.ModuleType("mlx_audio")
        qwen_stt = types.ModuleType("mlx_audio.stt")
        qwen_stt.load = qwen_load
        parakeet = types.ModuleType("parakeet_mlx")
        parakeet.from_pretrained = Mock(return_value=object())
        mlx = types.ModuleType("mlx")
        mlx_core = types.ModuleType("mlx.core")
        mlx_core.clear_cache = Mock()
        mlx.core = mlx_core

        with tempfile.TemporaryDirectory() as directory, patch.object(
            app, "MODEL_HUB_CACHE", Path(directory) / "hub"
        ), patch.object(app, "_model", None), patch.object(
            app, "_model_id", None
        ), patch.dict("sys.modules", {
            "mlx": mlx,
            "mlx.core": mlx_core,
            "mlx_audio": qwen_package,
            "mlx_audio.stt": qwen_stt,
            "parakeet_mlx": parakeet,
        }):
            app._load_model("qwen", Path("/snapshots/qwen"))
            app._load_model("compact", Path("/snapshots/compact"))

        qwen_load.assert_called_once_with("/snapshots/qwen")
        parakeet.from_pretrained.assert_called_once_with(
            "/snapshots/compact", cache_dir=str(Path(directory) / "hub")
        )

    def test_delete_refuses_loaded_or_downloading_model(self):
        with patch.object(app, "_model_id", app.MODELS["compact"]["id"]):
            with self.assertRaisesRegex(app.HTTPError, "loaded"):
                app.delete_model("compact")
        app._model_downloads["qwen"] = {"downloading": True, "error": None}
        with self.assertRaisesRegex(app.HTTPError, "operation is already running"):
            app.delete_model("qwen")

    def test_delete_uses_hugging_face_revision_strategy(self):
        cache = self.cache_info("compact")
        strategy = types.SimpleNamespace(expected_freed_size=987, execute=Mock())
        cache.delete_revisions = Mock(return_value=strategy)
        with patch.object(app, "_model_id", None), patch.object(
            app, "_model_cache_info", return_value=cache
        ):
            self.assertEqual(app.delete_model("compact"), 987)
        cache.delete_revisions.assert_called_once_with("commit-compact")
        strategy.execute.assert_called_once_with()

    def test_compare_uses_only_snapshot_paths_and_preserves_history(self):
        with history_environment() as (_, audio, history):
            (audio / "entry.wav").write_bytes(make_wav())
            original = '{"id":"entry","audio_file":"data/audio/entry.wav","extra":1}\n'
            history.write_text(original)
            cache = {
                key: {"installed": True, "snapshot_path": Path(f"/cache/{key}")}
                for key in app.MODELS
            }
            with patch.object(app, "_cached_models", return_value=cache), patch.object(
                app, "_generate_transcript", side_effect=["compact text", "qwen text"]
            ) as generate:
                payload = app.compare_history_models("entry", ["compact", "qwen"])

            self.assertEqual(history.read_text(), original)
            self.assertEqual([item["text"] for item in payload["results"]], [
                "compact text", "qwen text",
            ])
            self.assertEqual(
                [call.args[2] for call in generate.call_args_list],
                [Path("/cache/compact"), Path("/cache/qwen")],
            )

    def test_compare_reuses_recorded_qwen_language(self):
        with history_environment() as (_, audio, history):
            (audio / "entry.wav").write_bytes(make_wav())
            history.write_text(json.dumps({
                "id": "entry",
                "audio_file": "data/audio/entry.wav",
                "language": "French",
            }) + "\n")
            cache = {
                key: {"installed": True, "snapshot_path": Path(f"/cache/{key}")}
                for key in app.MODELS
            }
            with patch.object(app, "_cached_models", return_value=cache), patch.object(
                app, "_generate_transcript", return_value="bonjour"
            ) as generate:
                app.compare_history_models("entry", ["compact", "qwen"])
            self.assertEqual(generate.call_args_list[0].args, (
                app.decode_pcm_wav(make_wav()), "compact", Path("/cache/compact"),
            ))
            self.assertEqual(generate.call_args_list[1].args[1:], (
                "qwen", Path("/cache/qwen"), "French",
            ))

    def test_compare_releases_lock_between_runs_and_restores_prior_model(self):
        prior_model = object()
        contender_acquired = threading.Event()
        contender = None

        def generate(_samples, key, _source):
            nonlocal contender
            app._model = object()
            app._model_id = app.MODELS[key]["id"]
            if key == "compact":
                def contend():
                    with app._operation_lock:
                        contender_acquired.set()
                contender = threading.Thread(target=contend)
                contender.start()
            else:
                self.assertTrue(contender_acquired.wait(1))
            return key

        with history_environment() as (_, audio, history), patch.object(
            app, "_model", prior_model
        ), patch.object(app, "_model_id", "prior-model"), patch.object(
            app, "_clear_loaded_model", side_effect=lambda: setattr(app, "_model", None)
        ):
            (audio / "entry.wav").write_bytes(make_wav())
            history.write_text('{"id":"entry","audio_file":"data/audio/entry.wav"}\n')
            cache = {
                key: {"installed": True, "snapshot_path": Path(f"/cache/{key}")}
                for key in app.MODELS
            }
            with patch.object(app, "_cached_models", return_value=cache), patch.object(
                app, "_generate_transcript", side_effect=generate
            ):
                app.compare_history_models("entry", ["compact", "qwen"])

            self.assertIs(app._model, prior_model)
            self.assertEqual(app._model_id, "prior-model")
        contender.join(1)
        self.assertTrue(contender_acquired.is_set())

    def test_compare_restores_unloaded_state_after_failure(self):
        def fail_after_loading(_samples, key, _source):
            app._model = object()
            app._model_id = app.MODELS[key]["id"]
            raise RuntimeError("comparison failed")

        with history_environment() as (_, audio, history), patch.object(
            app, "_model", None
        ), patch.object(app, "_model_id", None), patch.object(
            app, "_clear_loaded_model", side_effect=lambda: (
                setattr(app, "_model", None), setattr(app, "_model_id", None)
            )
        ):
            (audio / "entry.wav").write_bytes(make_wav())
            history.write_text('{"id":"entry","audio_file":"data/audio/entry.wav"}\n')
            cache = {
                key: {"installed": True, "snapshot_path": Path(f"/cache/{key}")}
                for key in app.MODELS
            }
            with patch.object(app, "_cached_models", return_value=cache), patch.object(
                app, "_generate_transcript", side_effect=fail_after_loading
            ), self.assertRaisesRegex(RuntimeError, "comparison failed"):
                app.compare_history_models("entry", ["compact", "qwen"])
            self.assertIsNone(app._model)
            self.assertIsNone(app._model_id)

    def test_restore_reinstates_prior_state_even_if_cache_clear_fails(self):
        prior = object()
        with patch.object(app, "_model", object()), patch.object(
            app, "_model_id", "comparison-model"
        ), patch.object(
            app, "_clear_loaded_model", side_effect=RuntimeError("clear failed")
        ):
            with self.assertRaisesRegex(RuntimeError, "clear failed"):
                app._restore_loaded_model(prior, "prior-model")
            self.assertIs(app._model, prior)
            self.assertEqual(app._model_id, "prior-model")

    def test_compare_preserves_model_selected_between_runs(self):
        prior = object()
        selected_during_comparison = object()
        app._model = prior
        app._model_id = "prior-model"
        def generate(_samples, key, _source):
            app._model = object()
            app._model_id = app.MODELS[key]["id"]
            return key

        def select_model(_delay):
            app._model = selected_during_comparison
            app._model_id = "new-selection"

        with (
            patch.object(app, "_history_audio", return_value=make_wav()),
            patch.object(
                app,
                "_installed_model_snapshots",
                side_effect=lambda keys: {key: Path("/tmp/model") for key in keys},
            ),
            patch.object(app, "_generate_transcript", side_effect=generate),
            patch.object(app.time, "sleep", side_effect=select_model),
            patch.object(
                app,
                "_clear_loaded_model",
                side_effect=lambda: (setattr(app, "_model", None), setattr(app, "_model_id", None)),
            ),
        ):
            app.compare_history_models("entry", ["compact", "parakeet-v2"])

        self.assertIs(app._model, selected_during_comparison)
        self.assertEqual(app._model_id, "new-selection")

    def test_compare_preserves_model_selected_before_first_run(self):
        prior = object()
        selected_during_comparison = object()
        app._model = prior
        app._model_id = "prior-model"
        clock_calls = 0

        def clock():
            nonlocal clock_calls
            clock_calls += 1
            if clock_calls == 1:
                app._model = selected_during_comparison
                app._model_id = "new-selection"
            return float(clock_calls)

        def generate(_samples, key, _source):
            app._model = object()
            app._model_id = app.MODELS[key]["id"]
            return key

        with (
            patch.object(app, "_history_audio", return_value=make_wav()),
            patch.object(
                app,
                "_installed_model_snapshots",
                side_effect=lambda keys: {key: Path("/tmp/model") for key in keys},
            ),
            patch.object(app, "_generate_transcript", side_effect=generate),
            patch.object(app.time, "perf_counter", side_effect=clock),
            patch.object(
                app,
                "_clear_loaded_model",
                side_effect=lambda: (setattr(app, "_model", None), setattr(app, "_model_id", None)),
            ),
        ):
            app.compare_history_models("entry", ["compact", "parakeet-v2"])

        self.assertIs(app._model, selected_during_comparison)
        self.assertEqual(app._model_id, "new-selection")

    def test_compare_rejects_bad_selection_missing_audio_and_uninstalled(self):
        with history_environment() as (_, audio, history):
            for models in ([], ["compact"], ["compact", "compact"], ["unknown", "qwen"]):
                with self.assertRaises(ValueError):
                    app.compare_history_models("entry", models)
            with self.assertRaisesRegex(app.HTTPError, "not found"):
                app.compare_history_models("entry", ["compact", "qwen"])

            (audio / "entry.wav").write_bytes(make_wav())
            history.write_text('{"id":"entry","audio_file":"data/audio/entry.wav"}\n')
            cache = {
                key: {"installed": key != "qwen", "snapshot_path": Path(f"/cache/{key}")}
                for key in app.MODELS
            }
            with patch.object(app, "_cached_models", return_value=cache), patch.object(
                app, "_generate_transcript"
            ) as generate, self.assertRaisesRegex(app.HTTPError, "installed before use"):
                app.compare_history_models("entry", ["compact", "qwen"])
            generate.assert_not_called()

    def test_compare_honors_server_side_cancellation(self):
        cancellation = threading.Event()
        cancellation.set()
        with (
            patch.object(app, "_history_audio", return_value=make_wav()),
            patch.object(
                app,
                "_installed_model_snapshots",
                side_effect=lambda keys: {key: Path("/tmp/model") for key in keys},
            ),
            patch.object(app, "_generate_transcript") as generate,
            self.assertRaisesRegex(app.HTTPError, "cancelled"),
        ):
            app.compare_history_models(
                "entry",
                ["compact", "parakeet-v2"],
                cancellation,
            )
        generate.assert_not_called()


class ModelManagementEndpointTests(unittest.TestCase):
    def test_preload_preserves_current_unauthenticated_client_contract(self):
        with history_environment(), worker_server() as address, patch.object(
            app, "preload_model", return_value={"loaded_model": "local-model"}
        ) as preload:
            status, _, body = request(
                address,
                "POST",
                "/api/preload",
                headers={"X-Parakeet-Model": "compact"},
            )
        self.assertEqual(
            (status, json.loads(body)),
            (200, {"loaded_model": "local-model"}),
        )
        preload.assert_called_once_with("compact")

    def test_endpoints_require_authentication(self):
        with history_environment(), worker_server() as address, patch.object(
            app, "model_status", return_value=[]
        ):
            self.assertEqual(request(address, "GET", "/api/models")[0], 403)
            self.assertEqual(
                request(address, "GET", "/api/models", token="secret")[0], 200
            )
            for path, payload in (
                ("/api/models/download", {"model": "compact"}),
                ("/api/models/delete", {"model": "compact"}),
                ("/api/models/compare", {"history_id": "one", "models": ["compact"]}),
                ("/api/models/compare/cancel", {"comparison_id": "one"}),
            ):
                self.assertEqual(request(address, "POST", path, payload)[0], 403)

    def test_status_and_management_contracts(self):
        status_payload = [{"key": "compact", "installed": False}]
        with history_environment(), worker_server() as address, patch.object(
            app, "model_status", return_value=status_payload
        ), patch.object(app, "download_model", return_value=True), patch.object(
            app, "delete_model", return_value=123
        ), patch.object(app, "compare_history_models", return_value={
            "history_id": "one", "results": []
        }):
            status, _, body = request(
                address, "GET", "/api/models", token="secret"
            )
            self.assertEqual((status, json.loads(body)), (200, {"models": status_payload}))
            self.assertEqual(request(
                address, "POST", "/api/models/download", {"key": "compact"}, "secret"
            )[0], 200)
            status, _, body = request(
                address, "POST", "/api/models/delete", {"model": "compact"}, "secret"
            )
            self.assertEqual(json.loads(body)["freed_size_bytes"], 123)
            status, _, body = request(
                address, "POST", "/api/models/compare",
                {"history_id": "one", "model_keys": ["compact", "qwen"]}, "secret"
            )
            self.assertEqual((status, json.loads(body)), (200, {
                "history_id": "one", "results": [],
            }))
            cancellation = threading.Event()
            app._comparison_cancellations["one"] = cancellation
            try:
                status, _, body = request(
                    address,
                    "POST",
                    "/api/models/compare/cancel",
                    {"comparison_id": "one"},
                    "secret",
                )
                self.assertEqual((status, json.loads(body)), (200, {"cancelled": True}))
                self.assertTrue(cancellation.is_set())
            finally:
                app._comparison_cancellations.pop("one", None)

    def test_cancel_before_comparison_registration_is_honored(self):
        def compare(history_id, model_keys, cancellation):
            self.assertTrue(cancellation.is_set())
            raise app.HTTPError(409, "Model comparison was cancelled")

        with history_environment(), worker_server() as address, patch.object(
            app, "compare_history_models", side_effect=compare
        ):
            status, _, body = request(
                address,
                "POST",
                "/api/models/compare/cancel",
                {"comparison_id": "future"},
                "secret",
            )
            self.assertEqual((status, json.loads(body)), (200, {"cancelled": True}))
            status, _, body = request(
                address,
                "POST",
                "/api/models/compare",
                {
                    "comparison_id": "future",
                    "history_id": "one",
                    "model_keys": ["compact", "qwen"],
                },
                "secret",
            )
            self.assertEqual(status, 409)
            self.assertIn("cancelled", json.loads(body)["error"])

    def test_management_rejects_unknown_model(self):
        with history_environment(), worker_server() as address:
            for path in ("/api/models/download", "/api/models/delete"):
                status, _, body = request(
                    address, "POST", path, {"model": "not-canonical"}, "secret"
                )
                self.assertEqual(status, 400)
                self.assertIn("canonical", json.loads(body)["error"])


class HistoryEndpointTests(unittest.TestCase):
    def test_get_history_search_order_and_limit_cap(self):
        with history_environment() as (_, _, history), worker_server() as address:
            history.write_text("".join(
                json.dumps({"id": str(index), "text": "Straße"}) + "\n"
                for index in range(205)
            ))
            status, _, body = request(address, "GET", "/api/history?q=STRASSE&limit=999")
            payload = json.loads(body)
            self.assertEqual(status, 200)
            self.assertEqual(len(payload["entries"]), 200)
            self.assertEqual(payload["entries"][0]["id"], "204")

    def test_get_history_rejects_bad_limit(self):
        with history_environment(), worker_server() as address:
            status, _, body = request(address, "GET", "/api/history?limit=nope")
            self.assertEqual(status, 400)
            self.assertIn("positive integer", json.loads(body)["error"])

    def test_get_history_skips_invalid_typed_records_without_deleting_them(self):
        with history_environment() as (_, _, history), worker_server() as address:
            huge_integer = "1" + "0" * 400
            original = "".join([
                '{"id":"wrong-type","text":42}\n',
                '{"id":"not-finite","transcription_seconds":NaN}\n',
                f'{{"id":"huge","transcription_seconds":{huge_integer}}}\n',
                '{"id":"valid","text":"hello"}\n',
            ])
            history.write_text(original)

            status, _, body = request(address, "GET", "/api/history")
            self.assertEqual(status, 200)
            self.assertEqual(
                [entry["id"] for entry in json.loads(body)["entries"]],
                ["valid"],
            )
            self.assertEqual(history.read_text(), original)

    def test_get_audio_returns_wav_and_missing_is_404(self):
        with history_environment() as (_, audio, history), worker_server() as address:
            wav = make_wav()
            (audio / "entry.wav").write_bytes(wav)
            history.write_text(json.dumps({
                "id": "entry",
                "audio_file": "data/audio/entry.wav",
            }) + "\n")
            status, headers, body = request(address, "GET", "/api/history/audio?id=entry")
            self.assertEqual(status, 200)
            self.assertEqual(headers["Content-Type"], "audio/wav")
            self.assertEqual(body, wav)
            status, _, _ = request(address, "GET", "/api/history/audio?id=missing")
            self.assertEqual(status, 404)

    def test_delete_and_retention_require_valid_token(self):
        with history_environment() as (_, _, history), worker_server() as address:
            history.write_text('{"id":"entry"}\n')
            for path, payload in [
                ("/api/history/delete", {"id": "entry"}),
                ("/api/history/retention", {"days": 7}),
            ]:
                self.assertEqual(request(address, "POST", path, payload)[0], 403)
                self.assertEqual(request(address, "POST", path, payload, "wrong")[0], 403)

    def test_authenticated_delete_and_retention_responses(self):
        with history_environment() as (_, _, history), worker_server() as address:
            history.write_text("".join([
                '{"id":"delete-me"}\n',
                '{"id":"old","timestamp":"2000-01-01T00:00:00Z"}\n',
            ]))
            status, _, body = request(
                address, "POST", "/api/history/delete", {"id": "delete-me"}, "secret"
            )
            self.assertEqual((status, json.loads(body)), (200, {"deleted": True}))
            status, _, body = request(
                address, "POST", "/api/history/retention", {"days": 7}, "secret"
            )
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body), {"days": 7, "pruned": 1})

    def test_delete_succeeds_when_final_unlink_waits_for_reconciliation(self):
        with history_environment() as (_, audio, history), worker_server() as address:
            recording = audio / "retry.wav"
            recording.write_bytes(b"audio")
            history.write_text(
                '{"id":"retry","audio_file":"data/audio/retry.wav"}\n'
            )
            path_type = type(recording)
            real_unlink = path_type.unlink

            def fail_staged_unlink(path, *args, **kwargs):
                if path.name.startswith(app.STAGED_AUDIO_PREFIX):
                    raise PermissionError("retry later")
                return real_unlink(path, *args, **kwargs)

            with patch.object(path_type, "unlink", new=fail_staged_unlink), patch(
                "builtins.print"
            ) as output:
                status, _, body = request(
                    address, "POST", "/api/history/delete", {"id": "retry"}, "secret"
                )

            staged = app._staged_audio_path(recording.resolve())
            self.assertEqual((status, json.loads(body)), (200, {"deleted": True}))
            self.assertFalse(recording.exists())
            self.assertTrue(staged.exists())
            self.assertIn("finalization failed", output.call_args_list[0].args[0])

            app.migrate_history()
            self.assertFalse(staged.exists())

    def test_mutations_validate_json_and_bound_body(self):
        with history_environment(), worker_server() as address:
            status, _, body = request(
                address, "POST", "/api/history/delete", {}, "secret"
            )
            self.assertEqual(status, 400)
            self.assertIn("id", json.loads(body)["error"])

            connection = http.client.HTTPConnection(*address, timeout=2)
            oversized = b"x" * (app.MAX_JSON_BODY_BYTES + 1)
            connection.request(
                "POST",
                "/api/history/retention",
                body=oversized,
                headers={"X-Tiro-Worker-Token": "secret"},
            )
            response = connection.getresponse()
            response_body = response.read()
            connection.close()
            self.assertEqual(response.status, 413)
            self.assertIn("exceeds", json.loads(response_body)["error"])

    def test_mutation_without_content_length_is_411(self):
        with history_environment(), worker_server() as address:
            connection = http.client.HTTPConnection(*address, timeout=2)
            connection.putrequest("POST", "/api/history/delete")
            connection.putheader("X-Tiro-Worker-Token", "secret")
            connection.endheaders()
            response = connection.getresponse()
            body = response.read()
            connection.close()

            self.assertEqual(response.status, 411)
            self.assertIn("Content-Length", json.loads(body)["error"])

    def test_retention_rejects_bool_and_unsupported_days(self):
        with history_environment(), worker_server() as address:
            for days in (True, 8):
                status, _, body = request(
                    address, "POST", "/api/history/retention", {"days": days}, "secret"
                )
                self.assertEqual(status, 400)
                self.assertIn("0, 7, 30, or 90", json.loads(body)["error"])


class VocabularySuggestionEndpointTests(unittest.TestCase):
    def test_profiles_get_and_authenticated_replace(self):
        with history_environment(), worker_server() as address:
            status, _, body = request(address, "GET", "/api/vocabulary/profiles")
            self.assertEqual((status, json.loads(body)), (200, {"version": 1, "profiles": []}))
            document = {"version": 1, "profiles": [{
                "bundle_id": "app", "name": "App", "entries": [],
            }]}
            self.assertEqual(
                request(address, "POST", "/api/vocabulary/profiles", document)[0],
                403,
            )
            status, _, body = request(
                address, "POST", "/api/vocabulary/profiles", document, "secret"
            )
            self.assertEqual((status, json.loads(body)), (200, document))
            self.assertEqual(json.loads(app.PROFILES_PATH.read_text()), document)

    def test_profiles_post_rejects_malformed_document(self):
        with history_environment(), worker_server() as address:
            status, _, body = request(
                address,
                "POST",
                "/api/vocabulary/profiles",
                {"version": 1, "profiles": [{"bundle_id": "app"}]},
                "secret",
            )
            self.assertEqual(status, 400)
            self.assertIn("name", json.loads(body)["error"])

    def test_new_mutations_require_authentication(self):
        paths = [
            ("/api/history/correction", {"id": "one", "corrected_text": "text"}),
            ("/api/suggestions/accept", {"id": "one", "scope": "global"}),
            ("/api/suggestions/dismiss", {"id": "one"}),
        ]
        with history_environment(), worker_server() as address:
            for path, payload in paths:
                self.assertEqual(request(address, "POST", path, payload)[0], 403)
                self.assertEqual(request(address, "POST", path, payload, "wrong")[0], 403)

    def test_correction_and_suggestion_lifecycle_over_http(self):
        with history_environment(), worker_server() as address:
            app.HISTORY_PATH.write_text("".join([
                '{"id":"one","text":"hello yana","origin_bundle_id":"app"}\n',
                '{"id":"two","text":"hello yana","origin_bundle_id":"app"}\n',
            ]))
            for entry_id in ("one", "two"):
                status, _, body = request(
                    address,
                    "POST",
                    "/api/history/correction",
                    {"id": entry_id, "corrected_text": "hello Janne"},
                    "secret",
                )
                self.assertEqual((status, json.loads(body)), (200, {"corrected": True}))
            status, _, body = request(address, "GET", "/api/suggestions")
            suggestion = json.loads(body)["suggestions"][0]
            self.assertEqual((status, suggestion["count"]), (200, 2))
            status, _, body = request(
                address,
                "POST",
                "/api/suggestions/dismiss",
                {"id": suggestion["id"]},
                "secret",
            )
            self.assertEqual((status, json.loads(body)), (200, {"dismissed": True}))
            self.assertEqual(
                json.loads(request(address, "GET", "/api/suggestions")[2]),
                {"suggestions": []},
            )

    def test_accept_endpoint_validates_scope_and_writes_global_rule(self):
        with history_environment(), worker_server() as address:
            app.HISTORY_PATH.write_text("".join([
                '{"id":"one","text":"hello yana"}\n',
                '{"id":"two","text":"hello yana"}\n',
            ]))
            app.correct_history_entry("one", "hello Janne")
            app.correct_history_entry("two", "hello Janne")
            suggestion = app.get_suggestions()[0]
            self.assertIsNone(suggestion["origin_bundle_id"])
            suggestion_id = suggestion["id"]
            status, _, body = request(
                address,
                "POST",
                "/api/suggestions/accept",
                {"id": suggestion_id, "scope": "invalid"},
                "secret",
            )
            self.assertEqual(status, 400)
            status, _, body = request(
                address,
                "POST",
                "/api/suggestions/accept",
                {"id": suggestion_id, "scope": "global"},
                "secret",
            )
            self.assertEqual((status, json.loads(body)), (200, {"accepted": True, "scope": "global"}))
            self.assertEqual(app.load_vocabulary(), [{"spoken": "yana", "written": "Janne"}])

    def test_transcribe_passes_bounded_origin_headers(self):
        response_entry = {"id": "one", "text": "hello"}
        with history_environment(), worker_server() as address, patch.object(
            app, "transcribe", return_value=response_entry
        ) as transcribe:
            connection = http.client.HTTPConnection(*address, timeout=2)
            wav = make_wav()
            connection.request(
                "POST",
                "/api/transcribe",
                body=wav,
                headers={
                    "Content-Length": str(len(wav)),
                    "X-Tiro-Origin-Bundle-ID": "com.editor",
                    "X-Tiro-Origin-App-Name": "Editor",
                },
            )
            response = connection.getresponse()
            response.read()
            connection.close()
            self.assertEqual(response.status, 200)
            transcribe.assert_called_once_with(wav, "compact", "com.editor", "Editor")

    def test_transcribe_rejects_oversized_origin_header(self):
        with history_environment(), worker_server() as address, patch.object(
            app, "transcribe"
        ) as transcribe:
            connection = http.client.HTTPConnection(*address, timeout=2)
            wav = make_wav()
            connection.request(
                "POST",
                "/api/transcribe",
                body=wav,
                headers={"X-Tiro-Origin-Bundle-ID": "x" * (app.MAX_ORIGIN_BUNDLE_ID + 1)},
            )
            response = connection.getresponse()
            body = response.read()
            connection.close()
            self.assertEqual(response.status, 400)
            self.assertIn("exceeds", json.loads(body)["error"])
            transcribe.assert_not_called()


class FinalFeatureEndpointTests(unittest.TestCase):
    def test_snippet_crud_requires_authentication(self):
        with history_environment(), worker_server() as address:
            self.assertEqual(request(address, "GET", "/api/snippets")[0], 403)
            self.assertEqual(
                request(address, "POST", "/api/snippets", {"trigger": "sig", "content": "Regards"})[0],
                403,
            )
            status, _, body = request(
                address, "POST", "/api/snippets",
                {"trigger": "sig", "content": "Regards"}, "secret",
            )
            self.assertEqual(status, 201)
            snippet = json.loads(body)
            status, _, body = request(address, "GET", "/api/snippets", token="secret")
            self.assertEqual((status, json.loads(body)), (200, {"snippets": [snippet]}))

            self.assertEqual(request(
                address, "POST", "/api/snippets/delete", {"id": snippet["id"]}
            )[0], 403)
            status, _, body = request(
                address, "POST", "/api/snippets/delete", {"id": snippet["id"]}, "secret"
            )
            self.assertEqual((status, json.loads(body)), (200, {"deleted": True}))
            status, _, body = request(
                address, "POST", "/api/snippets/delete", {"id": snippet["id"]}, "secret"
            )
            self.assertEqual((status, json.loads(body)), (200, {"deleted": False}))
            self.assertEqual(app.load_snippets(), [])

    def test_transcribe_forwards_final_feature_headers(self):
        response_entry = {"id": "one", "text": "bonjour"}
        with history_environment(), worker_server() as address, patch.object(
            app, "transcribe", return_value=response_entry
        ) as transcribe:
            wav = make_wav()
            connection = http.client.HTTPConnection(*address, timeout=2)
            connection.request(
                "POST", "/api/transcribe", body=wav,
                headers={
                    "X-Parakeet-Model": "qwen",
                    "X-Tiro-Mode": "verbatim",
                    "X-Tiro-Punctuation": "none",
                    "X-Tiro-Language": "French",
                },
            )
            response = connection.getresponse()
            response.read()
            connection.close()
        self.assertEqual(response.status, 200)
        transcribe.assert_called_once_with(
            wav, "qwen", None, None, "verbatim", "none", "French"
        )


class WorkerProtocolTests(unittest.TestCase):
    def test_protocol_version_is_current(self):
        self.assertEqual(app.API_VERSION, 6)

    def test_status_reports_protocol_version(self):
        with history_environment(), worker_server() as address:
            status, _, body = request(address, "GET", "/api/status")
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body)["api_version"], 6)

    def test_shutdown_requires_the_worker_token(self):
        with patch.dict(app.os.environ, {"TIRO_WORKER_TOKEN": "secret"}):
            self.assertFalse(app.shutdown_is_authorized(""))
            self.assertFalse(app.shutdown_is_authorized("wrong"))
            self.assertTrue(app.shutdown_is_authorized("secret"))


if __name__ == "__main__":
    unittest.main()
