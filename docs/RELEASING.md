# Releasing Tiro for macOS

Tiro has four native build modes:

- `development` builds the native app only and uses the local Tiro signing identity when installed.
- `release` embeds the Python worker and uses the same local identity for testing.
- `dmg` embeds the worker, ad-hoc signs it, verifies the packaged runtime, and emits a compressed DMG plus SHA-256 checksum without paid Apple credentials.
- `distribution` embeds the worker, signs nested Mach-O code inside-out with a Developer ID Application identity and hardened runtime, notarizes and staples the app, verifies it with Gatekeeper, and emits a ZIP plus SHA-256 checksum.

Self-contained builds target arm64 macOS 14. The app links the pinned
FluidAudio package for native Core ML recognition and includes its Apache 2.0
license and the model attribution notice. The build creates
`.build/release-venv`, synchronizes the exact lockfile there, and installs the
lockfile's macOS 14 MLX wheel variants for the optional fallback models. It
never reuses host-specific MLX binaries from `.venv` and never raises the
deployment target to make an incompatible bundle pass.

The source `native/Info.plist` contains development defaults. Pass release metadata explicitly so the packaged copy is changed without rewriting source files:

```sh
./scripts/build_native_app.sh distribution \
  --version 1.2.0 \
  --build-number 42 \
  --signing-identity "Developer ID Application: Your Name (TEAMID)" \
  --notary-profile tiro-notary
```

The bundle identifier remains `local.tiro.dictation`. Do not change it as part of release packaging because doing so changes the app identity and permission history.

## Free GitHub release

The primary free GitHub release is a DMG that requires no Apple Developer Program membership:

```sh
./scripts/build_native_app.sh dmg \
  --version 1.2.0 \
  --build-number 42
```

The image contains `Tiro.app` and an Applications shortcut. The build mounts the finished image, verifies both entries and the app signature, and writes:

```text
dist/releases/Tiro-1.2.0-42-macOS-arm64.dmg
dist/releases/Tiro-1.2.0-42-macOS-arm64.dmg.sha256
```

Because this build has no Developer ID signature or notarization, macOS blocks it after download. Copy Tiro to Applications, try to open it, choose **Open Anyway** for Tiro in **System Settings > Privacy & Security**, authenticate if prompted, then confirm **Open**. Repeat this approval for each downloaded update and re-enable Accessibility if macOS requests it. This is the explicit tradeoff for distributing without paid Apple credentials.

## Optional notarized distribution

Import a valid Developer ID Application certificate into the login keychain. Store notarization credentials in a named keychain profile; no Apple ID password or App Store Connect key belongs in this repository:

```sh
xcrun notarytool store-credentials tiro-notary
```

`TIRO_SIGNING_IDENTITY` and `TIRO_NOTARY_PROFILE` may be used instead of repeating the corresponding command-line options. These variables contain names, not secrets.

## Outputs and verification

Successful distribution builds create:

```text
dist/Tiro.app
dist/releases/Tiro-1.2.0-42-macOS-arm64.zip
dist/releases/Tiro-1.2.0-42-macOS-arm64.zip.sha256
```

The pipeline verifies that every bundled Mach-O contains arm64 and supports macOS 14, checks nested signatures and entitlements, executes a packaged MLX operation while importing both transcription backends, and starts the worker for an API smoke check. Distribution additionally waits for notarization, staples and validates the ticket, and asks Gatekeeper to assess the app. Re-run the final checks independently with:

```sh
./scripts/smoke_release.sh \
  --app dist/Tiro.app \
  --notarized \
  --expected-version 1.2.0 \
  --expected-build 42
```

For a credentialed signing rehearsal without notarization, pass `--skip-notarization`. The resulting archive includes `-unnotarized` in its name and is not suitable for distribution. Free release validation remains:

```sh
./scripts/build_native_app.sh dmg
```

To require all three configured models to load and transcribe from an existing
local cache while offline, run:

```sh
./scripts/smoke_release.sh \
  --app dist/Tiro.app \
  --model-dir "$HOME/Library/Application Support/Tiro/Models/huggingface"
```

Run release-script and login-item source assertions with `./scripts/test_release_engineering.sh`.

## Oldest-system acceptance

Every push to `main` and every pull request runs the complete DMG build and packaged MLX smoke test on GitHub's clean Apple Silicon macOS 14 runner. GitHub deprecated that image on 6 July 2026 and plans to remove it on 2 November 2026; before then, move oldest-system automation to a self-hosted Sonoma Mac or retain the following physical test as the release gate. Copy the DMG to a separate Apple Silicon Mac running macOS 14. Verify first launch through Gatekeeper, microphone and Accessibility onboarding, Parakeet and Qwen model download, tap and hold shortcuts, clipboard preservation, auto-paste, launch at login, and a second launch after replacing the app with the next build. Automation proves the clean build and runtime baseline; this short hands-on pass proves the permission-dependent user experience.
