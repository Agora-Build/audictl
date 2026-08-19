# Let Your AI Agent Be Your Audio Engineer

*Voice-testing rigs on macOS, wired by prompt — audictl + BlackHole + DialF.*

If you build or test voice things — AI voice agents, calling apps, meeting
bots — you eventually need to **record both what goes in and what comes out**
of your Mac's audio. And that's where the pain starts: Audio MIDI Setup,
checkboxes, aggregate devices, drift correction, "why is my recording at the
wrong sample rate", and twenty minutes of clicking you'll redo next week on
another machine.

The GUI can't be scripted, and your coding agent can't click checkboxes.

[`audictl`](https://github.com/Agora-Build/audictl) fixes that. It's a CLI
that does everything Audio MIDI Setup does for audio devices — list, inspect,
defaults, volume, **sample rates**, **aggregate and multi-output devices with
clock and drift control** — with stable JSON output, typed errors, and
idempotent commands. Which means the whole audio rig below is something you
can paste into a terminal, put in a Makefile, or hand to Claude/Codex as a
prompt: *"set up the audio environment for a voice eval."*

```sh
npm install -g @agora-build/audictl
# or: curl -fsSL https://dl.agora.build/audictl/install.sh | bash
```

The other two pieces of the kit:

- [**BlackHole**](https://existential.audio/blackhole/) — a virtual audio
  cable. Anything played into it can be captured from it. Install both the
  2ch and 16ch variants; two cables means input and output never collide.
- [**DialF**](https://www.npmjs.com/package/@agora-build/dialf)
  (`@agora-build/dialf`) — plays prompt audio, captures replies, and records
  tx/rx/mix on one clock. Built for phone-rig evals; works just as well fully
  virtual.

---

## Case 1 — Record both sides of a call (Bluetooth headset)

You're on AirPods (or any BT headset with a mic) and want one recording that
contains **what you said and what you heard**, in sync. No hardware mixer,
no holding a phone to a speaker.

Two virtual devices do it:

```
                        ┌──────────────────────────────┐
  the app's audio ────▶ │ Multi-Output "Hear+Tap"      │
  (Zoom, agent, …)      │  ├─▶ AirPods       (you hear)│
                        │  └─▶ BlackHole 2ch (the tap) │
                        └──────────────────────────────┘

  you speak ──▶ AirPods mic ──┐
                              ├─▶ Aggregate "Rec In" ──▶ recorder
  the tap ──▶ BlackHole 2ch ──┘     (mic + playback, one clock)
```

Wire it (fuzzy names are fine — audictl resolves them, and errors with
candidates if ambiguous):

```sh
# Output side: play to your ears AND into the tap
audictl multi create --name "Hear+Tap" --devices "AirPods,BlackHole 2ch" --primary "AirPods"
audictl default set output "Hear+Tap"

# Input side: mic + tap glued into one recordable device.
# BlackHole is the stable clock; drift-correct the Bluetooth side.
audictl aggregate create --name "Rec In" --devices "AirPods,BlackHole 2ch" \
        --clock "BlackHole 2ch" --drift "AirPods"

# Keep everyone on one rate
audictl rate set "BlackHole 2ch" 48k
```

Record from the aggregate — channel 1 is your mic, channels 2–3 are what you
heard:

```sh
sox -t coreaudio "Rec In" call.wav          # everything, in sync
sox call.wav mic.wav   remix 1              # split afterwards if you want
sox call.wav heard.wav remix 2,3
```

Or point DialF at it (`~/.config/dialf/config.yaml`) and let it manage the
recording files:

```yaml
audio:
  capture_device: "Rec In"
  record_dir: ~/recordings
  mix_recording: true
```

Tear it down when you're done — teardown is idempotent, safe to run twice:

```sh
audictl default set output "AirPods"
audictl aggregate destroy "Rec In" --if-exists
audictl multi destroy "Hear+Tap" --if-exists
```

---

## Case 2 — Eval a voice AI agent, no phone required

You have a voice agent running on (or reachable from) your Mac — a browser
tab, a softphone, a local process — and you want deterministic evals: play a
scripted prompt, capture the agent's reply, measure latency. No cellular in
the loop, so results are reproducible.

Two cables, one per direction:

```
  DialF plays prompt ──▶ BlackHole 2ch  ──▶ agent's microphone
  agent speaks       ──▶ BlackHole 16ch ──▶ DialF captures (rx)

  DialF records tx (what it played), rx (what the agent said),
  and a mix — all stamped on one clock.
```

### Preflight, agent-runnable

This is the part your coding agent can own. Every command is idempotent
(`changed:false` on re-run) and exit codes are meaningful, so the script is
safe to run before every eval:

```sh
#!/usr/bin/env bash
set -euo pipefail

# Devices present? (exit 2 = not found)
audictl info "BlackHole 2ch"  --quiet || { echo "install BlackHole 2ch";  exit 1; }
audictl info "BlackHole 16ch" --quiet || { echo "install BlackHole 16ch"; exit 1; }

# Match DialF's configured rate (validates against supported rates, exit 4 if not)
audictl rate set "BlackHole 2ch"  44.1k --quiet
audictl rate set "BlackHole 16ch" 44.1k --quiet

# If the agent app uses system defaults, point them at the cables:
audictl default set input  "BlackHole 2ch"  --quiet
audictl default set output "BlackHole 16ch" --quiet
```

(If the agent app has its own device picker, select the BlackHole devices
there instead of moving the system defaults.)

### DialF config

`~/.config/dialf/config.yaml`:

```yaml
audio:
  sample_rate: 44100
  channels: 1
  capture_device: "BlackHole 16ch"      # the agent's output
  playback_device: "BlackHole 2ch"      # the agent's input
  record_dir: ~/Dev/myEval/recordings
  mix_recording: true
  capture_cmd: ["/opt/homebrew/bin/sox", "-q", "-t", "coreaudio", "BlackHole 16ch",
                "-t", "raw", "-b", "16", "-e", "signed-integer",
                "-r", "{rate}", "-c", "{channels}", "-", "remix", "1"]
  playback_cmd: ["/opt/homebrew/bin/sox", "-q", "-V1", "{file}",
                 "-t", "coreaudio", "BlackHole 2ch"]
```

### The eval job

`jobs/audio-inject-record.yaml` — each turn plays a prompt (recorded as tx),
then waits for the agent to speak and stop (rx):

```yaml
- type: audio.play
  file: ./samples/EN_Responding_Latency_Samples_loop30_Interval_10s.wav
  description: turn 1 — prompt the agent

- type: log
  message: audio injection eval complete
```

```sh
dialf run jobs/audio-inject-record.yaml    # audio-only: no --device, no phone
```

Afterward, cross-correlate tx against rx: the gap between tx-end and rx-onset
is the agent's response latency, on a clean digital path. (For the real
earpiece/codec/acoustic path, keep the phone + sound-card rig; this setup
measures the agent itself.)

### Want to listen in while the eval runs?

The agent's output is going into a virtual cable — silent by default. Tap it
the same way as Case 1:

```sh
audictl multi create --name "Eval Monitor" --devices "BlackHole 16ch,MacBook Pro Speakers"
```

…and have the agent output to "Eval Monitor" instead: DialF still captures
from BlackHole 16ch, and your speakers get a copy.

---

## Notes for coding agents

If you are Claude, Codex, or any other coding agent reading this: audictl was
designed for you. The contract, in brief — full spec in
[SCHEMA.md](https://github.com/Agora-Build/audictl/blob/main/SCHEMA.md):

- Add `--json` to every command. You get
  `{"ok":true,"schemaVersion":1,"changed":…,"data":{…}}` on stdout — success
  and error envelopes both, so capture one stream only.
- **Mutations are idempotent** and return the resulting state. Re-running a
  satisfied command is `ok:true, changed:false`, exit 0 — build setup scripts
  that run unconditionally; don't pre-check.
- **Exit codes**: 2 device not found, 3 ambiguous selector, 4 unsupported
  (includes invalid sample rate, with the valid rates in
  `error.details.available`), 5 CoreAudio error, 6 timeout.
- On `AMBIGUOUS_DEVICE`, the error's `details.candidates` lists id/uid/name —
  retry with the UID. **Store UIDs, never numeric ids** (ids change; notably
  aggregates get a new id after every composition edit).
- `audictl list --json` is your discovery step; `audictl aggregate --json`
  shows every aggregate's members, clock, and drift flags.
- Clean up with `destroy --if-exists` / `remove --if-absent-ok` so teardown
  never fails on a half-torn-down rig.
- Rule of thumb for rigs: **BlackHole as the clock source, drift correction
  on Bluetooth/USB sub-devices**; set every device in a rig to one sample
  rate before recording.

## More scenarios

The two cases compose. Some obvious extensions:

- **Meeting recorder** — Case 1 with Zoom/Meet as the app; ch1 is you,
  ch2–3 are everyone else.
- **Agent-vs-agent** — two agents talking: one's output cable is the other's
  input cable, DialF taps both. 2ch and 16ch are independent cables; install
  more BlackHole variants for more parallel paths.
- **CI voice tests** — a Mac mini runner where the preflight script *is* the
  fixture; `--private` aggregates keep the runner's device list clean.
- **Whole-house audio** — `multi create` with every AirPlay/HDMI output;
  drift correction keeps rooms in sync.

Everything here is a prompt away: *"read
https://github.com/Agora-Build/audictl and set up Case 2 for a 48 kHz
agent."* Your audio engineer is in.
