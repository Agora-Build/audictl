import ArgumentParser
import AudictlCore
import CoreAudio

private func volumeDTO(_ manager: DeviceManager, _ control: VolumeControl,
                       _ ref: DeviceRef, _ scope: ScopeArg) throws -> VolumeDTO {
    let (volume, perChannel) = try control.getVolume(ref.id, scope: scope.halScope)
    return VolumeDTO(
        device: ref,
        scope: scope.rawValue,
        volume: volume,
        perChannel: perChannel.map { Dictionary(uniqueKeysWithValues: $0.map { (String($0.key), $0.value) }) },
        muted: control.getMute(ref.id, scope: scope.halScope)
    )
}

private func describeVolume(_ dto: VolumeDTO) -> String {
    var parts: [String] = []
    if let v = dto.volume { parts.append(String(format: "%.0f%%", v * 100)) }
    if let per = dto.perChannel, per.count > 1 {
        let channels = per.sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
            .map { "ch\($0.key) \(String(format: "%.0f%%", $0.value * 100))" }
        parts.append("(" + channels.joined(separator: ", ") + ")")
    }
    if dto.muted == true { parts.append("[muted]") }
    return "\(dto.device.name) \(dto.scope): " + parts.joined(separator: " ")
}

struct VolumeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "volume",
        abstract: "Get or set device volume.",
        subcommands: [Get.self, Set.self]
    )

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get",
            abstract: "Read the volume of a device."
        )

        @OptionGroup var globals: GlobalOptions
        @OptionGroup var selector: SelectorOptions

        @Argument(help: "Device UID, numeric ID, or (partial) name.")
        var device: String

        @Option(help: "Which direction to read: input or output.")
        var scope: ScopeArg = .output

        func run() throws {
            try rendered(globals, human: { (dto: VolumeDTO, _) in describeVolume(dto) }) {
                let manager = DeviceManager()
                let ref = try DeviceSelector(manager: manager).resolve(device, mode: selector.mode)
                return (try volumeDTO(manager, VolumeControl(), ref, scope), nil)
            }
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Set the volume of a device.",
            discussion: "Values 0-100 are percent; values with a decimal point (0.0-1.0) are scalar."
        )

        @OptionGroup var globals: GlobalOptions
        @OptionGroup var selector: SelectorOptions

        @Argument(help: "Device UID, numeric ID, or (partial) name.")
        var device: String

        @Argument(help: "Volume: 0-100 or 0.0-1.0.")
        var value: String

        @Option(help: "Which direction to set: input or output.")
        var scope: ScopeArg = .output

        @Option(help: "Set one channel element instead of the main volume.")
        var channel: UInt32?

        func run() throws {
            let target = try parseVolumeValue(value)
            try rendered(globals, human: { (dto: VolumeDTO, _) in describeVolume(dto) }) {
                let manager = DeviceManager()
                let ref = try DeviceSelector(manager: manager).resolve(device, mode: selector.mode)
                let control = VolumeControl()
                let changed = try control.setVolume(ref.id, scope: scope.halScope, to: target, channel: channel)
                return (try volumeDTO(manager, control, ref, scope), changed)
            }
        }
    }
}

struct MuteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mute",
        abstract: "Get or change device mute state.",
        subcommands: [Get.self, On.self, Off.self, Toggle.self]
    )

    struct MuteArgs: ParsableArguments {
        @OptionGroup var globals: GlobalOptions
        @OptionGroup var selector: SelectorOptions

        @Argument(help: "Device UID, numeric ID, or (partial) name.")
        var device: String

        @Option(help: "Which direction: input or output.")
        var scope: ScopeArg = .output

        @Option(help: "Target one channel element instead of the main mute.")
        var channel: UInt32?

        func resolve() throws -> (DeviceManager, VolumeControl, DeviceRef) {
            let manager = DeviceManager()
            let ref = try DeviceSelector(manager: manager).resolve(device, mode: selector.mode)
            return (manager, VolumeControl(), ref)
        }

        func apply(muted: Bool?) throws {
            try rendered(globals, human: { (dto: VolumeDTO, _) in
                "\(dto.device.name) \(dto.scope): " + (dto.muted == true ? "muted" : "unmuted")
            }) {
                let (manager, control, ref) = try resolve()
                var changed: Bool? = nil
                if let muted {
                    changed = try control.setMute(ref.id, scope: scope.halScope, muted: muted, channel: channel)
                }
                return (try volumeDTO(manager, control, ref, scope), changed)
            }
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "get", abstract: "Read mute state.")
        @OptionGroup var args: MuteArgs
        func run() throws { try args.apply(muted: nil) }
    }

    struct On: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "on", abstract: "Mute the device.")
        @OptionGroup var args: MuteArgs
        func run() throws { try args.apply(muted: true) }
    }

    struct Off: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "off", abstract: "Unmute the device.")
        @OptionGroup var args: MuteArgs
        func run() throws { try args.apply(muted: false) }
    }

    struct Toggle: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "toggle", abstract: "Toggle mute state.")
        @OptionGroup var args: MuteArgs

        func run() throws {
            try rendered(args.globals, human: { (dto: VolumeDTO, _) in
                "\(dto.device.name) \(dto.scope): " + (dto.muted == true ? "muted" : "unmuted")
            }) {
                let (manager, control, ref) = try args.resolve()
                let current = control.getMute(ref.id, scope: args.scope.halScope) ?? false
                let changed = try control.setMute(ref.id, scope: args.scope.halScope,
                                                  muted: !current, channel: args.channel)
                return (try volumeDTO(manager, control, ref, args.scope), changed)
            }
        }
    }
}
