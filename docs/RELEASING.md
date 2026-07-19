# Releasing Tiro for macOS

Tiro has four native build modes:

- `development`: local app, using the local Tiro identity when available.
- `release`: optimized local app with the same signing policy.
- `dmg`: ad-hoc-signed community DMG and SHA-256 checksum.
- `distribution`: Developer ID signing, notarization, stapling, ZIP, and checksum.

All modes build a native arm64 macOS 14 app. No model, Python interpreter, MLX
runtime, or external service is packaged. FluidAudio and Argmax OSS license
files are copied into the app.

Sponsorship links and reminders are excluded unless the maintainer explicitly
passes `--enable-sponsorship`. Community and distribution builds should leave
this option off while sponsorship is unavailable.

## Community DMG

```sh
./scripts/build_native_app.sh dmg \
  --version 1.2.0 \
  --build-number 42
```

Outputs:

```text
dist/releases/Tiro-1.2.0-42-macOS-arm64.dmg
dist/releases/Tiro-1.2.0-42-macOS-arm64.dmg.sha256
```

The build mounts the image and verifies the app, Applications shortcut,
signature, entitlements, version, architecture, deployment target, licenses,
and absence of bundled models.

Because the community build has no Developer ID signature or notarization,
macOS requires **Open Anyway** approval for each downloaded update.

## Notarized Distribution

Store notarization credentials in the Keychain:

```sh
xcrun notarytool store-credentials tiro-notary
```

Build with:

```sh
./scripts/build_native_app.sh distribution \
  --version 1.2.0 \
  --build-number 42 \
  --signing-identity "Developer ID Application: Your Name (TEAMID)" \
  --notary-profile tiro-notary
```

`TIRO_SIGNING_IDENTITY` and `TIRO_NOTARY_PROFILE` may provide the corresponding
names. Do not store credentials in the repository.

For a signing rehearsal, use `--skip-notarization`. Its archive contains
`-unnotarized` and is not ready for distribution.

## Verification

```sh
./scripts/test_all.sh
./scripts/smoke_release.sh \
  --app dist/Tiro.app \
  --expected-version 1.2.0 \
  --expected-build 42
```

Before publishing, test the DMG on an Apple Silicon Mac running macOS 14:

1. Approve the first launch through Gatekeeper.
2. Complete Microphone and Accessibility onboarding.
3. Download and transcribe with at least one Parakeet and one Whisper model.
4. Test tap-to-toggle, push-to-talk, Escape, clipboard preservation, and auto-paste.
5. Test launch at login and replacing the app with the next build.

The bundle identifier remains `local.tiro.dictation`; changing it resets the
app identity and permission history.
