import ArgumentParser
import AudictlCore

struct RateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rate",
        abstract: "Get, list, or set a device's nominal sample rate.",
        subcommands: [Get.self, List.self, Set.self]
    )

    struct RateArgs: ParsableArguments {
        @OptionGroup var globals: GlobalOptions
        @OptionGroup var selector: SelectorOptions

        @Argument(help: "Device UID, numeric ID, or (partial) name.")
        var device: String

        func resolve() throws -> (DeviceRef, SampleRateControl) {
            let manager = DeviceManager()
            let ref = try DeviceSelector(manager: manager).resolve(device, mode: selector.mode)
            return (ref, SampleRateControl())
        }

        func dto(_ ref: DeviceRef, _ control: SampleRateControl) throws -> SampleRateDTO {
            SampleRateDTO(device: ref,
                          sampleRate: try control.current(ref.id),
                          availableSampleRates: try control.availableRates(ref.id))
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get",
            abstract: "Show the current sample rate."
        )
        @OptionGroup var args: RateArgs

        func run() throws {
            try rendered(args.globals, human: { (dto: SampleRateDTO, _) in
                "\(dto.device.name): \(formatRate(dto.sampleRate))"
            }) {
                let (ref, control) = try args.resolve()
                return (try args.dto(ref, control), nil)
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List the sample rates the device supports."
        )
        @OptionGroup var args: RateArgs

        func run() throws {
            try rendered(args.globals, human: { (dto: SampleRateDTO, _) in
                dto.availableSampleRates.map {
                    ($0 == dto.sampleRate ? "* " : "  ") + formatRate($0)
                }.joined(separator: "\n")
            }) {
                let (ref, control) = try args.resolve()
                return (try args.dto(ref, control), nil)
            }
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Set the nominal sample rate.",
            discussion: "Accepts plain hertz (48000) or k-suffixed shorthand (44.1k, 96kHz)."
        )
        @OptionGroup var args: RateArgs

        @Argument(help: "Sample rate in Hz, e.g. 48000 or 44.1k.")
        var rate: String

        func run() throws {
            let hz = try parseRateValue(rate)
            try rendered(args.globals, human: { (dto: SampleRateDTO, changed) in
                let verb = changed == true ? "is now" : "already"
                return "\(dto.device.name) \(verb) \(formatRate(dto.sampleRate))"
            }) {
                let (ref, control) = try args.resolve()
                let changed = try control.set(ref.id, to: hz, timeout: args.globals.timeout)
                return (try args.dto(ref, control), changed)
            }
        }
    }
}
