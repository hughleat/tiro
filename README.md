# Tiro

Tiro is a private, local dictation app for Apple Silicon Macs. A native menu-bar app records microphone audio, sends a 16 kHz mono WAV to a local Python worker, copies the transcript, and optionally pastes it into the active application.

## Controls

- Tap Right Command to start or stop recording.
- Hold Right Command for push-to-talk.
- Press Escape to cancel a recording.
- Use the waveform menu-bar icon to record, select a model, change automatic paste, or view history.

Add personal vocabulary in Settings using one `heard phrase = written phrase` rule per line. Tiro applies these rules locally before copying, pasting, and saving the transcript.

The global shortcut and automatic paste require macOS Accessibility permission. Recording requires Microphone permission. Tiro shows the shortcut permission state in its menu.

## Models

- `mlx-community/parakeet-tdt_ctc-110m`: compact English model; the default.
- `mlx-community/parakeet-tdt-0.6b-v2`: larger English model with stronger punctuation.
- `mlx-community/Qwen3-ASR-0.6B-4bit`: compact multilingual model.

Models are loaded through MLX and cached under `.cache/huggingface`. Recordings and JSONL history remain under `data/`; both directories are excluded from Git.

## Development

Python 3.11 or newer and the project-local virtual environment are required.

```sh
.venv/bin/python -m unittest discover -s tests
./scripts/build_native_app.sh
open "dist/Tiro.app"
```

The app expects to run from `dist/Tiro.app` and locates the worker relative to the project root. Set `TIRO_PROJECT_ROOT` when launching it to override that location.

The build uses a stable designated requirement for local ad-hoc signing. This prevents ordinary rebuilds from invalidating Tiro's Accessibility permission.
