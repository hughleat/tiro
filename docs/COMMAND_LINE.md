# Tiro Command Line

Tiro includes a small command-line helper for scripts and terminal workflows.
The Tiro app remains responsible for recording, model loading, transcription,
history, and the clipboard, so the helper does not load a second copy of a
model.

## Install

Choose **Settings** from Tiro's waveform menu-bar icon, open **General**, find
**Command Line**, and select **Install...**. Tiro links the bundled helper at
`/usr/local/bin/tiro`.

## Examples

```sh
tiro transcribe meeting.m4a
tiro transcribe interview.m4a --diarize
tiro diarize interview.m4a --json
tiro transcribe meeting.m4a --copy --json
tiro record --copy
session="$(tiro record start)"
tiro record stop "$session" --copy
tiro status --json
tiro models
```

Speaker identification requires its separate local model from **Settings >
Models** and a speech model that supplies timestamps. Apple Speech cannot be
used for speaker identification.

Interactive `tiro record` records until Control-D, then transcribes. Control-C
cancels and discards the recording. Tiro also cancels if the terminal process
exits unexpectedly.

Use `--no-history` on `transcribe`, `diarize`, `record`, or `record start` for
one-off work. Plain output contains only the transcript. JSON transcription
output also contains timestamped segments and, when speaker identification is
enabled, speaker IDs. Diagnostics use standard error output.

Run `tiro help` for the complete syntax summary.
