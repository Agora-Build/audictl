import ArgumentParser
import AudictlCore
import CoreAudio

@main
struct Audictl: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audictl",
        abstract: "Manage macOS audio devices from the command line.",
        discussion: """
            A scriptable replacement for the audio-device half of Audio MIDI Setup: \
            list and inspect devices, switch defaults, control volume and sample rates, \
            and manage aggregate / multi-output devices. Every command supports --json \
            with a stable envelope for agents and scripts (see SCHEMA.md).
            """,
        version: "0.1.0",
        subcommands: [
            ListCommand.self, InfoCommand.self, DefaultCommand.self,
            VolumeCommand.self, MuteCommand.self, RateCommand.self,
            AggregateCommand.self, MultiCommand.self,
        ]
    )
}

struct GlobalOptions: ParsableArguments {
    @Flag(help: "Emit a JSON envelope on stdout.")
    var json = false

    @Flag(help: "Suppress output; communicate via exit code only.")
    var quiet = false

    @Option(help: "Seconds to wait for asynchronous device operations.")
    var timeout: Double = 5
}

enum SelectorFlag: String, EnumerableFlag {
    case byUid, byId, byName

    var mode: SelectorMode {
        switch self {
        case .byUid: return .byUID
        case .byId: return .byID
        case .byName: return .byName
        }
    }

    static func help(for value: SelectorFlag) -> ArgumentHelp? {
        switch value {
        case .byUid: return "Interpret <device> strictly as a device UID."
        case .byId: return "Interpret <device> strictly as a numeric AudioObjectID."
        case .byName: return "Interpret <device> strictly as a device name."
        }
    }
}

struct SelectorOptions: ParsableArguments {
    @Flag(exclusivity: .exclusive)
    var by: SelectorFlag?

    var mode: SelectorMode { by?.mode ?? .auto }
}

enum ScopeArg: String, ExpressibleByArgument, CaseIterable {
    case input, output

    var halScope: AudioObjectPropertyScope {
        self == .input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    }
}

enum RoleArg: String, ExpressibleByArgument, CaseIterable {
    case input, output, system

    var role: DefaultRole {
        switch self {
        case .input: return .input
        case .output: return .output
        case .system: return .system
        }
    }
}
