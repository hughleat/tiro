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


class WorkerProtocolTests(unittest.TestCase):
    def test_protocol_version_is_current(self):
        self.assertEqual(app.API_VERSION, 4)

    def test_status_reports_protocol_version(self):
        with history_environment(), worker_server() as address:
            status, _, body = request(address, "GET", "/api/status")
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body)["api_version"], 4)

    def test_shutdown_requires_the_worker_token(self):
        with patch.dict(app.os.environ, {"TIRO_WORKER_TOKEN": "secret"}):
            self.assertFalse(app.shutdown_is_authorized(""))
            self.assertFalse(app.shutdown_is_authorized("wrong"))
            self.assertTrue(app.shutdown_is_authorized("secret"))


if __name__ == "__main__":
    unittest.main()
