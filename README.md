# Tiro

Tiro is a private, local dictation app for Apple Silicon Macs. A native menu-bar app records microphone audio, sends a 16 kHz mono WAV to a local Python worker, copies the transcript, and optionally pastes it into the active application.

## Controls

- Tap the configured shortcut (Right Command by default) to start or stop recording.
- Hold the shortcut for push-to-talk.
- Press Escape to cancel a recording.
- Use the waveform menu-bar icon to record, select a model, change automatic paste, or view history.

Settings includes searchable history, model downloads and comparisons, global and per-app vocabulary, and reusable snippets. Tiro applies these local transformations before copying, pasting, and saving the transcript.

## Dictation

- **Standard** mode applies spoken formatting commands, vocabulary, and snippets. **Verbatim** preserves the model transcript.
- Punctuation can use the model output, spoken punctuation such as “comma” and “question mark,” or no punctuation.
- “New line” and “new paragraph” work as formatting commands in Standard mode.
- Qwen supports automatic language detection and 30 explicit languages. The Parakeet models remain English-only.
- Snippets use an editable “When Tiro hears” / “Tiro inserts” table and are stored locally.

The global shortcut and automatic paste require macOS Accessibility permission. Recording requires Microphone permission. Tiro shows the shortcut permission state in its menu.

Tiro can launch automatically at login from Settings. It also warms the selected transcription model in the background at startup so the first dictation does not pay the model-loading delay.

## Models

- `mlx-community/parakeet-tdt_ctc-110m`: compact English model; the default.
- `mlx-community/parakeet-tdt-0.6b-v2`: larger English model with stronger punctuation.
- `mlx-community/Qwen3-ASR-0.6B-4bit`: compact multilingual model.

## Data Locations

Tiro keeps mutable files outside the application bundle:

- History, optional recordings, vocabulary, privacy settings, token: `~/Library/Application Support/Tiro/data/`
- Downloaded model cache: `~/Library/Application Support/Tiro/Models/huggingface/`
- Worker output: `~/Library/Logs/Tiro/worker.log`

On first access, `AppPaths.migrateLegacyProjectDataIfNeeded()` recursively merges known files from the old checkout-local `data/` directory and `.cache/huggingface` model cache. It copies missing files with the native filesystem copy operation, never overwrites destination files, and never deletes the source. Keeping the `data/` component preserves audio references in existing history. A versioned completion marker is written only after every discovered source is resolved successfully; a copy error or file/directory conflict leaves migration retryable.

Development runs remember a validated checkout in `~/Library/Application Support/Tiro/.legacy-project-root`. Installed releases consult `TIRO_PROJECT_ROOT` first, then the running development layout, the remembered checkout, and conservative `~/Documents/code`, `~/Developer`, and `~/Code` fallbacks. Tests and local tooling may override destinations with `TIRO_DATA_DIR`, `TIRO_MODEL_DIR`, and `TIRO_LOG_DIR`; `TIRO_DATA_DIR` names the Application Support root, not its `data/` child, while `TIRO_MODEL_DIR` names the exact model-cache directory.

## Development

Install `uv`, then create the pinned project environment from the lockfile:

```sh
brew install uv
uv sync --python 3.14.6 --frozen --extra bundle
```

Build and test with:

```sh
./scripts/test_all.sh
open "dist/Tiro.app"
```

The aggregate check runs the worker suite, data-migration assertions, native shortcut and snippet-state assertions, and a signed development build.

The development app does not embed Python. It uses `.venv/bin/python scripts/worker_entry.py` from `TIRO_PROJECT_ROOT` (or the checkout inferred from `dist/Tiro.app`) so development and release share the same data-location behavior.

## Self-contained App

The release build uses PyInstaller `onedir` to embed the Python interpreter, `scripts/worker_entry.py`, MLX libraries, and their Python dependencies under `Tiro.app/Contents/Resources/worker/`. It synchronizes the project-local `.venv` exactly from `uv.lock`, including the `bundle` dependencies, then builds with:

```sh
./scripts/build_native_app.sh release
./scripts/smoke_release.sh
```

The build sync may download missing packages. The smoke check starts the packaged worker against temporary data, verifies API compatibility, and shuts it down. If the locked environment or runtime imports are unavailable, either command exits with an actionable error. Models themselves are not bundled; users explicitly download and remove them in Tiro's Models settings, and their files remain in Application Support.

`WorkerProcess` owns worker startup and compatibility checks. It selects the embedded worker in release builds and `.venv/bin/python scripts/worker_entry.py` during development, while `WorkerAPI` owns authenticated HTTP requests and `WorkerTransport` translates HTTP failures. The worker token and all mutable files are created with private permissions.

### macOS support policy

macOS 14 remains the native source baseline, but a self-contained release can only support the highest minimum required by all native libraries embedded from its Python environment. After PyInstaller runs, the build scans every bundled Mach-O `LC_BUILD_VERSION`, raises the built app's `LSMinimumSystemVersion` to that maximum, and validates the result before signing. This deliberately favors a truthful, runnable artifact over claiming compatibility that its MLX wheel cannot provide. With the dependencies currently installed on this macOS 26 machine, MLX requires macOS 26.2, so this machine can run the result and the release bundle will declare 26.2 rather than falsely declaring 14.0. Building on an environment whose complete native dependency set supports an older macOS version produces that lower truthful minimum, never below the macOS 14 baseline.

Run `scripts/setup_local_signing.sh` once before local development. It creates a code-signing-only certificate named `Tiro Local Development` in the login Keychain, allowing macOS to recognize rebuilt copies of Tiro as the same app and retain Accessibility permission. Development and local release builds use that identity automatically, with ad-hoc signing retained as a fallback on machines where it has not been installed.

Distribution builds use the hardened runtime and sign nested code inside-out. A distribution build can also submit to Apple's notary service, staple the accepted ticket, verify Gatekeeper acceptance, and emit a ZIP plus SHA-256 checksum. See [`docs/RELEASING.md`](docs/RELEASING.md) for the credentialed commands and release checklist.
