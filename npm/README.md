# @agora-build/audictl

Manage macOS audio devices from the command line — a scriptable, agent-friendly
replacement for the audio-device half of Audio MIDI Setup.

```sh
npm install -g @agora-build/audictl
audictl list
```

The postinstall step downloads the prebuilt binary for your platform from
[GitHub Releases](https://github.com/Agora-Build/audictl/releases). macOS only.

Alternative install without npm:

```sh
curl -fsSL https://dl.agora.build/audictl/install.sh | bash
```

Full documentation: https://github.com/Agora-Build/audictl
