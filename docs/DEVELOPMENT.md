# Developing Tiro

Tiro is a native Swift package with no Python runtime or MLX dependency.

## Build and Test

```sh
./scripts/test_all.sh
open "dist/Tiro.app"
```

The complete check runs Swift tests, focused native assertions, a production
Core ML transcription, and mounted DMG verification. It can download model
assets and create a multi-gigabyte `.build` directory, so allow adequate free
disk space.

Local builds use the `Tiro Local Development` signing identity when available:

```sh
./scripts/setup_local_signing.sh
./scripts/build_native_app.sh development
```

## Package

Create the free GitHub release artifact with:

```sh
./scripts/build_native_app.sh dmg
```

Models are downloaded by the app and are not part of the app or DMG. See the
[release guide](RELEASING.md) for signed and notarized builds and the complete
publishing process.

Pushing a beta tag such as `vX.Y.Z-beta.N` runs the complete acceptance suite
and publishes the verified community DMG and SHA-256 checksum as a GitHub
prerelease. Stable `vX.Y.Z` tags publish a normal release.
