# @agora-build/audictl

Cross-platform audio-device control for macOS and Linux. Audictl uses
CoreAudio on macOS and PipeWire/ALSA on Linux, with human-readable output at
the terminal and stable JSON for scripts and agents.

```sh
npm install -g @agora-build/audictl
audictl list
```

The postinstall step downloads the prebuilt binary for your platform from
[GitHub Releases](https://github.com/Agora-Build/audictl/releases).

Audictl supports macOS 13+ and PipeWire-based Linux distributions on x64 and
arm64. See the full documentation for the platform command matrix and Linux
virtual-audio prerequisites.

Alternative install without npm:

```sh
curl -fsSL https://dl.agora.build/audictl/install.sh | bash
```

Full documentation: https://github.com/Agora-Build/audictl
