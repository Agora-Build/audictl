# audictl JSON contract

This is the machine interface for agents and scripts. Pass `--json` to any
command; both success and error envelopes go to **stdout** so callers only
capture one stream.

Current `schemaVersion`: **1**

## Stability rules

- **Additive changes are free.** New keys may appear in any object at any time;
  consumers must ignore unknown keys.
- **Breaking changes bump `schemaVersion`** (key renamed/removed, type changed,
  meaning changed). The golden-file tests in `Tests/AudictlCoreTests/EnvelopeGoldenTests.swift`
  pin the current encoding; a diff there without a version bump is a bug.
- Keys are camelCase.
- **Device UIDs are the durable handle** — stable across reboots and replugs.
  Numeric `id` values (AudioObjectIDs) are session-scoped and can change any
  time (notably: editing an aggregate's composition re-publishes it under a new
  id). Store UIDs, never ids.

## Envelopes

Success:

```json
{
  "ok": true,
  "schemaVersion": 1,
  "changed": true,
  "data": { ... }
}
```

- `changed` appears only on mutating commands: `true` if the command altered
  state, `false` if it was an idempotent no-op (already set, already muted,
  already absent with `--if-absent-ok`, …). Either way `ok` is `true` and the
  exit code is 0.
- `data` of every mutating command contains the resulting state — no follow-up
  read needed.

Error:

```json
{
  "ok": false,
  "schemaVersion": 1,
  "error": {
    "code": "AMBIGUOUS_DEVICE",
    "message": "'usb' matches 2 devices",
    "details": { "query": "usb", "candidates": [ {"id": 130, "uid": "...", "name": "..."} ] }
  }
}
```

## Error codes and exit codes

| Exit | `error.code` | Meaning / details payload |
|------|--------------|---------------------------|
| 0 | — | success, including no-op success |
| 1 | `INTERNAL` | unexpected failure |
| 2 | `DEVICE_NOT_FOUND` | `details.query` |
| 3 | `AMBIGUOUS_DEVICE` | `details.query`, `details.candidates` (retry with a UID) |
| 4 | `UNSUPPORTED_OPERATION`, `NOT_AN_AGGREGATE`, `INVALID_SAMPLE_RATE`, `SUBDEVICE_NOT_IN_AGGREGATE` | operation impossible for this device; `INVALID_SAMPLE_RATE` carries `details.requested` + `details.available` |
| 5 | `HAL_ERROR` | CoreAudio failure; `details.osStatus`, `details.fourcc`, `details.operation` |
| 6 | `TIMEOUT` | async device operation didn't settle within `--timeout` |
| 64 | — | usage error (bad arguments; ArgumentParser prints to stderr) |

## Device addressing

Every `<device>` argument accepts one string, resolved in this order:

1. all-digits → session-scoped AudioObjectID (if a device with that id exists)
2. exact UID (case-sensitive)
3. exact name (case-insensitive)
4. unique case-insensitive substring of a name

Zero matches → exit 2; several matches at step 4 → exit 3 with candidates.
Pin the interpretation with `--by-uid`, `--by-id`, or `--by-name`.

## Value formats

- **Volume**: `0`–`100` are percent; values containing a decimal point are
  scalar `0.0`–`1.0`. Note `1` is 1 %, `1.0` is 100 %.
- **Sample rate**: hertz (`48000`), or k-shorthand (`44.1k`, `96kHz`).

## Data shapes

Representative `data` payloads (all fields shown; optional fields may be
absent rather than null):

- `list` → `{ "devices": [DeviceInfo] }`
- `info`, `default get/set` (wrapped with `role`) → `DeviceInfo`
- `volume`/`mute` → `{ "device": Ref, "scope": "output", "volume": 0.5, "perChannel": {"1": 0.5}, "muted": false }`
- `rate` → `{ "device": Ref, "sampleRate": 48000, "availableSampleRates": [44100, 48000] }`
- `aggregate show/create/add/remove/set-clock/drift`, `multi create` →
  `{ "id": 155, "uid": "...", "name": "...", "isMultiOutput": false, "isPrivate": false, "clockDeviceUID": "...", "subDevices": [{"uid": "...", "name": "...", "driftCompensation": true}] }`
- `aggregate show` with no device → `{ "aggregates": [Aggregate] }`
- `aggregate destroy`, `multi destroy` → `{ "uid": "...", "existed": true }`

`DeviceInfo`:

```json
{
  "id": 130, "uid": "AppleUSBAudioEngine:...", "name": "MiniFuse 2",
  "manufacturer": "ARTURIA", "transport": "usb",
  "input":  { "channels": 4, "volume": 0.8, "muted": false },
  "output": { "channels": 4, "volume": 0.8, "muted": false },
  "sampleRate": 44100, "availableSampleRates": [44100, 48000],
  "isDefaultInput": false, "isDefaultOutput": false, "isDefaultSystem": false,
  "isAggregate": false, "isMultiOutput": false,
  "isAlive": true, "isRunning": false
}
```

Aggregate and multi-output devices additionally carry their membership
(added in 0.1.1, additive):

```json
{
  "subDevices": [{"uid": "BlackHole2ch_UID", "name": "BlackHole 2ch", "driftCompensation": true}],
  "clockDeviceUID": "BlackHole2ch_UID"
}
```

Sub-device `name` prefers the live device name and falls back to the name
stored in the composition, so unplugged hardware keeps its friendly label
(matching Audio MIDI Setup).

`transport` values: `builtin`, `pci`, `usb`, `firewire`, `bluetooth`,
`bluetoothLE`, `hdmi`, `displayport`, `airplay`, `avb`, `thunderbolt`,
`aggregate`, `autoaggregate`, `virtual`, `continuityCaptureWired`,
`continuityCaptureWireless`, `unknown`, or a raw FourCC for values newer than
this build.
