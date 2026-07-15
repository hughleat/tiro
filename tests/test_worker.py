import io
import json
import tempfile
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


if __name__ == "__main__":
    unittest.main()
