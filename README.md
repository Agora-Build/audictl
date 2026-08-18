# audictl

A scriptable replacement for the audio-device half of macOS **Audio MIDI
Setup** — built for humans at a terminal and for AI agents driving it as a
tool. Everything the GUI does for audio devices, as composable commands with
stable JSON output:

- list / inspect devices, switch default input/output/system device
- volume and mute, per-device and per-channel
- **sample-rate control** (no CLI tool did this before)
- **full aggregate-device lifecycle**: create, destroy, add/remove sub-devices,
  pick the clock device, toggle per-sub-device drift compensation
- multi-output devices with Audio-MIDI-Setup-style drift defaults

Requires macOS 13+. No dependencies beyond the system CoreAudio framework.

## Install

```sh
curl -fsSL https://dl.agora.build/audictl/install.sh | bash
# or:
npm install -g @agora-build/audictl
```

Or build from source:

```sh
swift build -c release
cp .build/release/audictl /usr/local/bin/
```

## Usage

```sh
audictl list                          # table of all devices
audictl list --aggregate              # aggregates with members inline:
                                      #   58  Aggregate Device  18  18 ...
                                      #         └ BlackHole 2ch [clock]
                                      #         └ BlackHole 16ch drift
audictl list --input                  # only devices with input channels
audictl info scarlett                 # fuzzy name matching everywhere
audictl default get output
audictl default set output "MacBook Pro Speakers"

audictl volume set speakers 40        # 0-100 percent (or 0.0-1.0 with a decimal point)
audictl mute toggle minifuse --scope input

audictl rate get minifuse
audictl rate set minifuse 96k         # validates against supported rates,
                                      # waits for the device to settle

audictl aggregate create --name "Studio Rig" --devices "minifuse,BlackHole 2ch" --clock minifuse
audictl aggregate add "Studio Rig" "BlackHole 16ch" --drift
audictl aggregate set-clock "Studio Rig" "BlackHole 2ch"
audictl aggregate drift "Studio Rig" "BlackHole 16ch" off
audictl aggregate remove "Studio Rig" "BlackHole 16ch"
audictl aggregate destroy "Studio Rig"

audictl multi create --name "Everywhere" --devices "speakers,office hdmi"
```

Devices are addressed by UID, numeric ID, exact name, or unique name
substring — see `SCHEMA.md` for resolution order and the `--by-uid` /
`--by-id` / `--by-name` overrides.

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
- Exit codes distinguish not-found (2), ambiguous (3), unsupported (4),
  CoreAudio errors (5), timeouts (6).
- Device **UIDs are durable**; numeric ids are session-scoped. Store UIDs.

`--quiet` suppresses output entirely (exit code only); `--timeout <s>` bounds
the wait for asynchronous device operations (creation, rate changes).

## Testing

```sh
swift test                                             # unit + CLI parsing (mocked HAL)
AUDICTL_INTEGRATION=1 swift test --filter IntegrationTests   # real CoreAudio
```

Integration tests build their aggregates as *private* devices (visible only to
the test process), so they never pollute the machine's device list.

## Not yet

- MIDI Studio features (CoreMIDI) — out of scope for v1
- `audictl mcp` (MCP server mode) — planned; the core library is already
  separated from the CLI for it
- Homebrew formula

## Release

Push a `v*` tag. CI builds arm64 + x86_64 binaries, runs the test suites,
creates a GitHub Release, publishes `@agora-build/audictl` to npm, and mirrors
the tarballs plus `install.sh` to `dl.agora.build/audictl/`.
