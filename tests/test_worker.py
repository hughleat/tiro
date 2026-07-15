import io
import http.client
import json
import tempfile
import threading
import types
import unittest
import uuid
import wave
from array import array
from contextlib import ExitStack, contextmanager
from datetime import datetime, timedelta, timezone
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

import app


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


class PreloadTests(unittest.TestCase):
    def test_preload_loads_requested_model(self):
        selected = {"id": app.MODELS["compact"]["id"]}
        with patch.object(app, "_load_model", return_value=(object(), selected)) as loader:
            payload = app.preload_model("compact")
        loader.assert_called_once_with("compact")
        self.assertEqual(payload, {"loaded_model": selected["id"]})

    def test_preload_uses_the_inference_operation_lock(self):
        started = threading.Event()

        def load(_):
            started.set()
            return object(), {"id": "test-model"}

        with patch.object(app, "_load_model", side_effect=load):
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
        with self.assertRaisesRegex(ValueError, "Unknown transcription model"):
            app.preload_model("missing")


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


class WorkerProtocolTests(unittest.TestCase):
    def test_protocol_version_is_current(self):
        self.assertEqual(app.API_VERSION, 5)

    def test_status_reports_protocol_version(self):
        with history_environment(), worker_server() as address:
            status, _, body = request(address, "GET", "/api/status")
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body)["api_version"], 5)

    def test_shutdown_requires_the_worker_token(self):
        with patch.dict(app.os.environ, {"TIRO_WORKER_TOKEN": "secret"}):
            self.assertFalse(app.shutdown_is_authorized(""))
            self.assertFalse(app.shutdown_is_authorized("wrong"))
            self.assertTrue(app.shutdown_is_authorized("secret"))


if __name__ == "__main__":
    unittest.main()
