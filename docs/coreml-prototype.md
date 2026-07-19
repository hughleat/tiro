# Core ML Parakeet Prototype

This probe measures native Compact Parakeet before it is connected to Tiro's
working dictation path. The shipping `Tiro` target does not link FluidAudio.

Build the probe:

```sh
swift build -c release --package-path Prototypes/CoreML
```

Download the Core ML Compact model and transcribe a WAV file:

```sh
Prototypes/CoreML/.build/release/TiroCoreMLProbe --audio recording.wav --download
```

Later runs are offline by default:

```sh
Prototypes/CoreML/.build/release/TiroCoreMLProbe --audio recording.wav
```

The probe emits JSON with the raw transcript, download time, model-load time,
transcription time, times-faster-than-real-time speed, wall-clock time, and
installed model size. Its model lives separately from the current MLX cache at:

```text
~/Library/Application Support/Tiro/Models/coreml-prototype/
```

Use the same recording with Tiro's existing Model Comparison view to compare
the raw transcript and timings. Do not commit personal recordings.

## First measurement

On a 16 GB M4 MacBook Air running macOS 26.5.2, a synthetic 5.13-second
English clip:

- Transcribed in 0.046 seconds (112 times faster than real time).
- Loaded the cached model in 0.13 seconds in a fresh probe process.
- Used 220 MiB of separately downloaded model data.
- Produced a 7.0 MiB optimized probe executable.

The raw result was accurate except that it heard "Tiro" as "TRO". Tiro's
existing vocabulary processor could correct that with a `TRO` to `Tiro` entry
after a production integration.

FluidAudio 0.15.5 also logs a warning about its optional CTC vocabulary model
when loading the base model offline. The base transcription is complete and
succeeds; the prototype deliberately does not download that additional model.

Before production integration, Tiro must include FluidAudio's Apache-2.0
notice and model attribution, and must serialize FluidAudio's process-global
offline setting with any other native model downloads.
