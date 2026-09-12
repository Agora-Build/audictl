# Audictl agent notes

## Architecture

- `Sources/` is the macOS 13+ Swift implementation backed by CoreAudio.
- `linux/` is the Linux Rust implementation. It shells out to the stable
  `pactl` interface provided by `pipewire-pulse` and inspects `/proc/asound`
  for virtual cards that PipeWire cannot see.
- Both binaries are named `audictl` and preserve the JSON envelope documented
  in `SCHEMA.md`. Additive platform fields do not require a schema bump.
- `npm/` and `scripts/install.sh` select the platform-specific release binary.

## Build and test

```sh
swift test
AUDICTL_INTEGRATION=1 swift test --filter IntegrationTests
cargo test --manifest-path linux/Cargo.toml
cargo clippy --manifest-path linux/Cargo.toml --all-targets -- -D warnings
```

CoreAudio integration claims require a real macOS run. PipeWire routing and
ALSA loopback claims require a real Linux audio-session run.

## Linux audio model

- PipeWire is the audio engine, WirePlumber is its session manager, and
  `pipewire-pulse` is the compatibility API used by Audictl and Chromium.
- `virtual list` reads ALSA first, so hidden `snd_aloop` cards remain visible.
- The raw `snd_aloop` card stays disabled in WirePlumber. `virtual show`
  creates explicit source/sink modules against PCM device 1; direct ALSA
  clients own device 0. Exposing the entire card through a Pro Audio profile
  produced selectable but silent nodes and must not be reintroduced.
- Default virtual names are `Audictl Audio Bridge`,
  `Audictl-Audio-Bridge-Input`, and `Audictl-Audio-Bridge-Output`; the stable ALSA ID is
  `AudictlBridge`.
- `virtual hide` unloads only PipeWire ALSA modules targeting the selected
  card's device 1. It never unloads `snd_aloop`, so direct ALSA access remains.
- `multi create` is a CoreAudio multi-output device on macOS and a PipeWire
  combined sink on Linux. Do not implement it using ALSA's `multi` plugin.
- NixOS system configuration is declarative. Print a configuration snippet;
  never mutate its generated `/etc` files.

## Release

A `v*` tag builds both platform implementations, publishes GitHub assets and
the npm wrapper, and mirrors artifacts to R2. npm versions cannot be reused
after publication.
