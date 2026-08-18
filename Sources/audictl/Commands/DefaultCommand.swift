import ArgumentParser
import AudictlCore

struct DefaultCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "default",
        abstract: "Get or set the default input/output/system device.",
        subcommands: [Get.self, Set.self]
    )

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get",
            abstract: "Show the default device for a role."
        )

        @OptionGroup var globals: GlobalOptions

        @Argument(help: "One of: input, output, system.")
        var role: RoleArg

        func run() throws {
            try rendered(globals, human: { (dto: DefaultDeviceDTO, _) in
                "\(dto.device.name) (id \(dto.device.id), \(dto.device.uid))"
            }) {
                let manager = DeviceManager()
                let id = try manager.defaultDeviceID(role.role)
                return (DefaultDeviceDTO(role: role.rawValue, device: try manager.info(for: id)), nil)
            }
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Set the default device for a role."
        )

        @OptionGroup var globals: GlobalOptions
        @OptionGroup var selector: SelectorOptions

        @Argument(help: "One of: input, output, system.")
        var role: RoleArg

        @Argument(help: "Device UID, numeric ID, or (partial) name.")
        var device: String

        func run() throws {
            try rendered(globals, human: { (dto: DefaultDeviceDTO, changed) in
                let verb = changed == true ? "default \(dto.role) is now" : "default \(dto.role) already"
                return "\(verb) \(dto.device.name)"
            }) {
                let manager = DeviceManager()
                let ref = try DeviceSelector(manager: manager).resolve(device, mode: selector.mode)
                let changed = try manager.setDefaultDevice(role.role, to: ref.id)
                return (DefaultDeviceDTO(role: role.rawValue, device: try manager.info(for: ref.id)), changed)
            }
        }
    }
}
