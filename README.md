<p align="center">
  <img src="native/Assets/TiroIcon.png" width="128" alt="Tiro app icon">
</p>

<h1 align="center">Tiro</h1>

<p align="center"><strong>Private, fast speech-to-text for Apple Silicon Macs.</strong></p>

<p align="center">
  <strong><a href="https://github.com/hughleat/tiro/releases/download/v0.1.0-beta.4/Tiro-0.1.0-beta.4-4-macOS-arm64.dmg">Download Tiro Public Beta (.dmg, 6.1 MB)</a></strong>
  · <a href="#install">Install</a>
  · <a href="#dictate">How to use</a>
  · <a href="https://github.com/hughleat/tiro/issues/new/choose">Feedback</a>
  · <a href="LICENSE">MIT License</a>
</p>

<p align="center"><sub>M1 or newer · macOS 14 Sonoma or later · 228 MB recommended starter model · no account</sub></p>

Tiro records from the menu bar, transcribes entirely on your Mac, copies the
result, and can paste it directly into the application you were using. It is
free, open source, and built natively for macOS.

<p align="center">
  <img src="docs/images/tiro-dictation-compact.png" width="820" alt="Tiro recording into a TextEdit document">
  <br><sub>Record from any application, then copy or paste the local transcript automatically.</sub>
</p>

## Install

1. [Download the current public beta](https://github.com/hughleat/tiro/releases/download/v0.1.0-beta.4/Tiro-0.1.0-beta.4-4-macOS-arm64.dmg), open the DMG, and drag Tiro to Applications.
2. Try to open Tiro. When macOS blocks the first launch, open **System Settings > Privacy & Security**, choose **Open Anyway**, then confirm **Open**.
3. Follow Tiro's setup: allow Microphone and Accessibility access, then choose a speech model. Parakeet Compact is a fast 228 MB starting point for English.

The DMG download is 6.1 MB. Speech models are not bundled; Tiro downloads only
models you explicitly choose to install. Apple Speech requires no Tiro-managed
model download. Speech Recognition permission is needed only when Apple Speech
is selected.

The one-time macOS warning appears because free community builds are ad-hoc
signed rather than Apple-notarized. Tiro is open source, and every release
includes a SHA-256 checksum. [View this release and its checksum](https://github.com/hughleat/tiro/releases/tag/v0.1.0-beta.4)
or browse [all releases](https://github.com/hughleat/tiro/releases).

<p align="center">
  <img src="docs/images/tiro-setup.png" width="602" alt="Tiro's private, local first-run setup">
</p>

## Dictate

Tiro lives in the menu bar and does not appear in the Dock. Look for its
waveform icon after setup.

- Tap Right Command to start recording, then tap it again to transcribe.
- Hold Right Command for push-to-talk; release it to transcribe.
- Press Escape to cancel a recording.
- Use the waveform menu-bar icon for recording, models, settings, and history.

Every completed transcript is copied to the clipboard. **Paste after
transcription** is on by default, putting the result directly into the
application you were using; you can change it in **Settings > General**.

## Do More

Choose **Transcribe Audio File...** from the menu bar, or drop an audio file
into the transcription window. Tiro can export text, Markdown, JSON, SRT, and
VTT files. Optional speaker identification is available for imported files
when the selected speech model supplies timestamps.

<p align="center">
  <img src="docs/images/tiro-file-transcription.png" width="560" alt="Tiro transcribing an audio file locally on a Mac">
  <br><sub>Transcribe existing audio and optionally identify speakers.</sub>
</p>

Vocabulary rules fix names and specialist terms automatically. Tiro also
supports reusable snippets, spoken formatting, learned suggestions, and
different vocabulary for individual applications.

<p align="center">
  <img src="docs/images/tiro-vocabulary.png" width="720" alt="Tiro's structured vocabulary replacement editor">
  <br><sub>Teach Tiro names, product terms, and other custom spellings.</sub>
</p>

Turn on **Save transcription history** in **Settings > Privacy** to search,
copy, correct, or delete previous results. Keeping transcripts and original
audio is off by default; audio storage also enables replay and model
comparison.

<p align="center">
  <img src="docs/images/tiro-history.png" width="620" alt="Tiro's searchable local transcription history">
  <br><sub>Your transcription history stays on your Mac.</sub>
</p>

## Models

Start with the model that matches what you dictate most often:

| Need | Suggested model | Download |
| --- | --- | ---: |
| Fast English dictation | Parakeet Compact | 228 MB |
| Best English accuracy | Parakeet 0.6B v2 | 500 MB |
| Multilingual Parakeet | Parakeet 0.6B v3 | 520 MB |
| No Tiro-managed download | Apple Speech | None |

Tiro also offers English and multilingual Whisper Tiny, Base, and Small models,
plus Distil Whisper Large V3, Whisper Large V3, and Whisper Large V3 Turbo.
Install only the models you want and switch at any time. The comparison view
can run one recording through several installed models.

<p align="center">
  <img src="docs/images/tiro-models.png" width="720" alt="Tiro's local transcription model library">
  <br><sub>Download, select, compare, and remove local speech models.</sub>
</p>

## Privacy

Transcription is local. Tiro has no account system and sends no telemetry.
While running, it uses the internet only when you request a model download or
click **Settings > About > Check for Updates**.

Downloaded models live in `~/Library/Application Support/Tiro/Models/coreml/`.
History, optional recordings, vocabulary, snippets, and privacy settings live
in `~/Library/Application Support/Tiro/data/`. Tiro's diagnostics report
excludes transcripts, audio, clipboard contents, vocabulary, file paths, and
application names.

## More

- [Use Tiro from the command line](docs/COMMAND_LINE.md)
- [Build Tiro from source](docs/DEVELOPMENT.md)
- [Report a bug or suggest an improvement](https://github.com/hughleat/tiro/issues/new/choose)
- [Read the beta testing guide](docs/BETA_TESTING.md)
- [Review security and privacy reporting](SECURITY.md)

## License

Tiro is available under the [MIT License](LICENSE). Dependency and model
attributions are listed in [Third-Party Notices](THIRD_PARTY_NOTICES.md).
