# audictl

A cross-platform audio-device control CLI for macOS and Linux, built for
humans at a terminal and for AI agents driving it as a tool. Audictl uses
CoreAudio on macOS and PipeWire/ALSA on Linux, with stable JSON output for
scripts and agents.

On **macOS**, audictl replaces the audio-device half of **Audio MIDI Setup**:

- list / inspect devices, switch default input/output/system device
- volume and mute, per-device and per-channel
- **sample-rate control** (no CLI tool did this before)
- **full aggregate-device lifecycle**: create, destroy, add/remove sub-devices,
  pick the clock device, toggle per-sub-device drift compensation
- multi-output devices with Audio-MIDI-Setup-style drift defaults

On **Linux**, audictl provides native audio-session and virtual-device tools:

- list / inspect PipeWire devices and switch default input/output devices
- create persistent multi-output sinks
- discover ALSA virtual drivers even while they are hidden from PipeWire
- install `snd_aloop` and expose or hide its safe PipeWire endpoints

macOS requires macOS 13+. Linux requires PipeWire, `pipewire-pulse`,
WirePlumber, systemd user services, and the `pactl` client. Install `pactl`
with `pkgs.pulseaudio` on NixOS, `pulseaudio-utils` on Debian/Ubuntu, or
`libpulse` on Arch. Only the client tools are needed; the PulseAudio daemon
stays unused under PipeWire. Native PulseAudio is detected and reported as
unsupported for virtual-device management.

On NixOS, a one-off command can run without a system rebuild:

```sh
nix-shell -p pulseaudio --run 'audictl list'
```

## Install

```sh
npm install -g @agora-build/audictl
# or:
curl -fsSL https://dl.agora.build/audictl/install.sh | bash
```

Or build from source on macOS:

```sh
swift build -c release
cp .build/release/audictl /usr/local/bin/
```

On Linux:

```sh
cargo build --release --manifest-path linux/Cargo.toml
cp linux/target/release/audictl ~/.local/bin/
```

## Usage

### Cross-platform commands

```sh
audictl list                          # table of all devices
audictl list --input                  # only devices with input channels
audictl info scarlett                 # fuzzy name matching everywhere
audictl default get output
audictl default set output "Built-in Audio"
audictl multi create --name "Everywhere" --devices "speakers,office hdmi"
audictl multi destroy "Everywhere"
```

Devices are addressed by UID, numeric ID, exact name, or unique name
substring — see `SCHEMA.md` for resolution order and the `--by-uid` /
`--by-id` / `--by-name` overrides.

### macOS controls and aggregate devices

```sh
audictl list --aggregate              # aggregates with members inline:
                                      #   58  Aggregate Device  18  18 ...
                                      #         └ BlackHole 2ch [clock]
                                      #         └ BlackHole 16ch drift

audictl volume set speakers 40        # 0-100 percent (or 0.0-1.0 with a decimal point)
audictl mute toggle minifuse --scope input

audictl rate get minifuse
audictl rate set minifuse 96k         # validates against supported rates,
                                      # waits for the device to settle

audictl aggregate                     # compositions of all aggregates (alias: aggregate show)
audictl aggregate show "Studio Rig"   # one composition: sub-devices, clock, drift
audictl aggregate create --name "Studio Rig" --devices "minifuse,BlackHole 2ch" --clock minifuse
audictl aggregate add "Studio Rig" "BlackHole 16ch" --drift
audictl aggregate set-clock "Studio Rig" "BlackHole 2ch"
audictl aggregate drift "Studio Rig" "BlackHole 16ch" off
audictl aggregate remove "Studio Rig" "BlackHole 16ch"
audictl aggregate destroy "Studio Rig"
```

### Aggregates and multi-output devices

`list` always prints one row per device (the Audio MIDI Setup sidebar);
`aggregate show` prints what's *inside* (the "Use" checkboxes) — bare
`audictl aggregate` does the same for all of them. A multi-output device is a
stacked aggregate — same CoreAudio
class, outputs mirrored instead of channels concatenated — so every
`aggregate` command (`show`, `add`, `remove`, `set-clock`, `drift`) works on
it; Audio MIDI Setup's "Primary Device" is the same field audictl shows as
`[clock]`. Sub-devices keep their friendly names even while the hardware is
unplugged, matching what the GUI displays.

On Linux, `multi create` presents the same interface but creates a persistent
PipeWire combined sink. PipeWire performs the mirroring, resampling, and clock
domain handling; an ALSA aggregate PCM is neither created nor required.

### Linux virtual audio

`list` shows endpoints currently exposed by PipeWire. `virtual list` reads
ALSA as well, so it also shows virtual cards hidden from PipeWire:

```sh
audictl virtual list
audictl virtual install                         # default: Audictl Audio Bridge
audictl virtual install --name "Browser Bridge"
audictl virtual show AudictlBridge
audictl virtual hide AudictlBridge
```

If `snd_aloop` is already installed, `virtual install` reports the existing
card and changes nothing. Otherwise Arch-derived and Ubuntu systems are
configured automatically. NixOS receives the exact `configuration.nix`
snippet it needs; audictl never edits generated NixOS system files.

The default card has ALSA ID `AudictlBridge`. When shown, applications see the
generic endpoints `Audictl-Audio-Bridge-Input` and
`Audictl-Audio-Bridge-Output`. Hiding removes the card's managed PipeWire
endpoints but leaves its ALSA PCMs available to direct ALSA applications.

To hear output and capture the same signal through the bridge:

```sh
audictl multi create \
  --name "Speakers + Audio Bridge" \
  --devices "Built-in Audio,Audictl-Audio-Bridge-Output"
audictl default set output "Speakers + Audio Bridge"
```

WirePlumber is PipeWire's session manager, not a competing audio pipeline.
`pipewire-pulse` lets applications such as Chromium use these PipeWire
endpoints through the PulseAudio API.

### Platform command support

| Command family | macOS | Linux |
| --- | --- | --- |
| `list`, `info`, `default` | CoreAudio | PipeWire |
| `multi create/destroy` | CoreAudio multi-output | PipeWire combined sink |
| `virtual` | - | ALSA + PipeWire |
| `volume`, `mute`, `rate` | CoreAudio | Planned |
| `aggregate` | CoreAudio | Not needed; use PipeWire routing |

## For agents and scripts

Add `--json` to any command for a stable envelope on stdout:

```sh
$ audictl default set output speakers --json
{"changed":false,"data":{"device":{...},"role":"output"},"ok":true,"schemaVersion":1}
```

The contract (`SCHEMA.md`):

- `ok` + `changed`: mutations are idempotent — re-running a command that is
  already satisfied returns `ok: true, changed: false`, exit 0.
- Mutating commands return the resulting state; no follow-up read needed.
- Machine-readable errors with typed codes and structured details — an
  `AMBIGUOUS_DEVICE` error lists the candidates so a retry can pin a UID.
- `MISSING_DEPENDENCY` identifies the missing command and includes a package
  installation hint when Audictl knows one.
- Exit codes distinguish not-found (2), ambiguous (3), unsupported (4),
  backend errors (5/6), and timeouts (6).
- Device **UIDs are durable**; numeric ids are session-scoped. Store UIDs.

`--quiet` suppresses output entirely (exit code only); `--timeout <s>` bounds
the wait for asynchronous device operations (creation, rate changes).

## Testing

```sh
swift test                                             # unit + CLI parsing (mocked HAL)
AUDICTL_INTEGRATION=1 swift test --filter IntegrationTests   # real CoreAudio
cargo test --manifest-path linux/Cargo.toml            # Linux backend
```

Integration tests build their aggregates as *private* devices (visible only to
the test process), so they never pollute the machine's device list.

## Not yet

- MIDI Studio features (CoreMIDI) — out of scope for v1
- `audictl mcp` (MCP server mode) — planned; the core library is already
  separated from the CLI for it
- Homebrew formula

## Release

Push a `v*` tag. CI builds macOS and static Linux arm64 + x86_64 binaries,
runs the test suites, creates a GitHub Release, publishes
`@agora-build/audictl` to npm, and mirrors the tarballs plus `install.sh` to
`dl.agora.build/audictl/`.
