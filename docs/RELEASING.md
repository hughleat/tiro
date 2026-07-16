# Releasing Tiro for macOS

Tiro has three native build modes:

- `development` builds the native app only and uses the local Tiro signing identity when installed.
- `release` embeds the Python worker and uses the same local identity for testing.
- `distribution` embeds the worker, signs nested Mach-O code inside-out with a Developer ID Application identity and hardened runtime, notarizes and staples the app, verifies it with Gatekeeper, and emits a ZIP plus SHA-256 checksum.

Self-contained builds target arm64 macOS 14. The build creates `.build/release-venv`, synchronizes the exact lockfile there, and installs the lockfile's macOS 14 MLX wheel variants. It never reuses host-specific MLX binaries from `.venv` and never raises the deployment target to make an incompatible bundle pass.

The source `native/Info.plist` contains development defaults. Pass release metadata explicitly so the packaged copy is changed without rewriting source files:

```sh
./scripts/build_native_app.sh distribution \
  --version 1.2.0 \
  --build-number 42 \
  --signing-identity "Developer ID Application: Your Name (TEAMID)" \
  --notary-profile tiro-notary
```

The bundle identifier remains `local.tiro.dictation`. Do not change it as part of release packaging because doing so changes the app identity and permission history.

## One-time credentials

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

For a credentialed signing rehearsal without notarization, pass `--skip-notarization`. The resulting archive includes `-unnotarized` in its name and is not suitable for distribution. Local validation remains:

```sh
./scripts/build_native_app.sh release
./scripts/smoke_release.sh
```

Run release-script and login-item source assertions with `./scripts/test_release_engineering.sh`.

## Oldest-system acceptance

Before publishing, copy the notarized archive to a clean Apple Silicon Mac running macOS 14. Verify first launch through Gatekeeper, microphone and Accessibility onboarding, Parakeet and Qwen model download, tap and hold shortcuts, clipboard preservation, auto-paste, launch at login, and a second launch after replacing the app with the next signed build. The local compatibility scan proves the binaries' declared minimums; this clean-machine pass proves the complete user experience.
