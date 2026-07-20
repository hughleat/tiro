# Tiro

Tiro is a free, open-source, local dictation app for Apple Silicon Macs. It
records from the menu bar, transcribes on the Mac, copies the result, and can
paste it into the active application.

## Install

Tiro supports macOS 14 Sonoma or later. Download the latest DMG from
[GitHub Releases](https://github.com/hughleat/tiro/releases/latest), open it,
and drag Tiro to Applications.

Community builds are ad-hoc signed and are not Apple-notarized. On first
launch, try to open Tiro, then approve it under **System Settings > Privacy &
Security > Open Anyway**. Grant Microphone access for recording and
Accessibility access for the global shortcut and automatic paste. Speech
Recognition access is needed only when Apple Speech is selected.

Models are never bundled with the app. Tiro downloads only models selected by
the user, and all transcription remains local. Apple Speech uses macOS-managed
on-device recognition and language data.

## Controls

- Tap the configured shortcut, Right Command by default, to start or stop.
- Hold the shortcut for push-to-talk.
- Press Escape to cancel.
- Use the waveform menu-bar icon for recording, models, settings, and history.
- Choose **Transcribe Audio File...** or drop an audio file into its window.

Tiro includes automatic paste, searchable history, optional retained audio,
global and per-app vocabulary, learned vocabulary suggestions, reusable
snippets, spoken formatting, privacy controls, model comparison, speaker
identification, and text, Markdown, JSON, SRT, and VTT export.

Speaker identification is optional and currently available for imported files
whose transcription model supplies timestamps. Its additional local Core ML
model is installed separately from **Settings > Models**.

## Command Line

Settings > General includes **Install Command-Line Tool...**, which links the
small bundled helper at `/usr/local/bin/tiro`. The app remains responsible for
recording, model loading, transcription, history, and the clipboard, so the
command does not load a second copy of a model.

```sh
tiro transcribe meeting.m4a
tiro transcribe interview.m4a --diarize
tiro diarize interview.m4a --json
tiro transcribe meeting.m4a --copy --json
session="$(tiro record start)"
tiro record stop "$session" --copy
tiro status --json
tiro models
```

Use `--no-history` on `transcribe`, `diarize`, or `record start` for one-off
work. Plain output contains only the transcript. JSON transcription output also
contains timestamped segments and, when diarisation is enabled, speaker IDs.
Diagnostics use standard error output.

## Models

Tiro offers Apple Speech and native Core ML models through FluidAudio and
WhisperKit:

- Apple Speech: Apple's on-device recognizer, with no Tiro-managed download.
- Parakeet Compact: small, fast, and English-only.
- Parakeet 0.6B v2: larger English model.
- Parakeet 0.6B v3: larger multilingual model with automatic detection.
- Whisper Tiny, Base, and Small English: English-specialized versions.
- Whisper Tiny, Base, and Small: progressively more accurate multilingual models.
- Distil Whisper Large V3: fast, high-accuracy multilingual transcription.
- Whisper Large V3 and Large V3 Turbo: high-accuracy multilingual models.

English-only Parakeet models keep the language fixed to English. Parakeet v3
detects its supported languages automatically. Whisper supports automatic
detection or an explicit language choice. Apple Speech uses the selected
language, with Auto following the Mac's current locale. Tiro supplies up to 100
saved vocabulary terms as recognition hints to Apple Speech.

Downloaded models live under:

```text
~/Library/Application Support/Tiro/Models/coreml/
```

History, recordings, vocabulary, snippets, and privacy settings live under:

```text
~/Library/Application Support/Tiro/data/
```

Private data directories use owner-only permissions. Tiro can copy user data
from old checkout-local `data/` directories without overwriting or deleting
the source.

## Development

Tiro is a Swift Package and has no Python runtime or MLX dependency.

```sh
./scripts/test_all.sh
open "dist/Tiro.app"
```

The complete check runs Swift tests, focused native assertions, a production
Core ML transcription, and mounted DMG verification. Local builds use the
`Tiro Local Development` signing identity when available:

```sh
./scripts/setup_local_signing.sh
./scripts/build_native_app.sh development
```

Create the free GitHub release artifact with:

```sh
./scripts/build_native_app.sh dmg
```

Models are downloaded by the app and are not part of the app or DMG. See
[`docs/RELEASING.md`](docs/RELEASING.md) for signed and notarized builds.

## Optional sponsorship UI

Support links and reminders are compiled out by default. Maintainer builds can
include them explicitly with:

```sh
./scripts/build_native_app.sh development --enable-sponsorship
```

Sponsorship never unlocks features or changes how Tiro works. Tiro sends no
usage telemetry.

## License

Tiro is available under the [MIT License](LICENSE). Dependency and model
attributions are listed in [Third-Party Notices](THIRD_PARTY_NOTICES.md).
