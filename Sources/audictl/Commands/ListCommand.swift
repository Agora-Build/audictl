import ArgumentParser
import AudictlCore

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List audio devices."
    )

    @OptionGroup var globals: GlobalOptions

    @Flag(help: "Only devices with input channels.")
    var input = false

    @Flag(help: "Only devices with output channels.")
    var output = false

    @Flag(help: "Only aggregate devices.")
    var aggregate = false

    @Flag(help: "Only multi-output devices.")
    var multi = false

    func run() throws {
        try rendered(globals, human: { (dto: DeviceListDTO, _) in
            formatTable(dto.devices.map(deviceRow), header: deviceHeader)
        }) {
            var filter: DeviceFilter = []
            if input { filter.insert(.input) }
            if output { filter.insert(.output) }
            if aggregate { filter.insert(.aggregate) }
            if multi { filter.insert(.multiOutput) }
            let devices = try DeviceManager().list(filter: filter)
            return (DeviceListDTO(devices: devices), nil)
        }
    }
}

struct InfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show full details for one device."
    )

    @OptionGroup var globals: GlobalOptions
    @OptionGroup var selector: SelectorOptions

    @Argument(help: "Device UID, numeric ID, or (partial) name.")
    var device: String

    func run() throws {
        try rendered(globals, human: { (dto: DeviceInfoDTO, _) in describeDevice(dto) }) {
            let manager = DeviceManager()
            let ref = try DeviceSelector(manager: manager).resolve(device, mode: selector.mode)
            return (try manager.info(for: ref.id), nil)
        }
    }
}
