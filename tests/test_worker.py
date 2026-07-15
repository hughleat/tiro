import io
import json
import tempfile
import threading
import unittest
import wave
from array import array
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
    def test_skips_malformed_history_lines(self):
        with tempfile.TemporaryDirectory() as directory:
            history = Path(directory) / "history.jsonl"
            history.write_text('{"text":"first"}\nnot-json\n{"text":"last"}\n')
            with patch.object(app, "HISTORY_PATH", history):
                self.assertEqual(
                    app.recent_history(),
                    [{"text": "last"}, {"text": "first"}],
                )


class VocabularyTests(unittest.TestCase):
    def test_loads_only_valid_entries(self):
        with tempfile.TemporaryDirectory() as directory:
            vocabulary = Path(directory) / "vocabulary.txt"
            vocabulary.write_text(" yana = Janne \nunfinished\n = ignored\n")
            with patch.object(app, "VOCABULARY_PATH", vocabulary):
                self.assertEqual(
                    app.load_vocabulary(),
                    [{"spoken": "yana", "written": "Janne"}],
                )

    def test_unreadable_text_is_ignored(self):
        with tempfile.TemporaryDirectory() as directory:
            vocabulary = Path(directory) / "vocabulary.txt"
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


if __name__ == "__main__":
    unittest.main()
