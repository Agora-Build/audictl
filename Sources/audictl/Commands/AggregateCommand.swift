import ArgumentParser
import AudictlCore
import Foundation

/// Resolves a sub-device query: normal device resolution first, falling back
/// to an exact UID match inside the aggregate's composition so sub-devices
/// whose hardware is unplugged can still be removed or edited.
func destroyAggregate(globals: GlobalOptions, mode: SelectorMode,
                      query: String, ifExists: Bool) throws {
    try rendered(globals, human: { (dto: DestroyedDTO, _) in
        dto.existed ? "destroyed \(dto.uid ?? query)" : "no such device; nothing to do"
    }) {
        let manager = AggregateManager()
        let ref: DeviceRef
        do {
            ref = try DeviceSelector(manager: DeviceManager()).resolve(query, mode: mode)
        } catch AudictlError.deviceNotFound where ifExists {
            return (DestroyedDTO(uid: nil, existed: false), false)
        }
        let uid = ref.uid
        try manager.destroy(ref.id, timeout: globals.timeout)
        return (DestroyedDTO(uid: uid, existed: true), true)
    }
}

func resolveSubUID(_ query: String, in aggregate: AggregateDTO,
                   selector: DeviceSelector, mode: SelectorMode) throws -> String {
    do {
        return try selector.resolve(query, mode: mode).uid
    } catch AudictlError.deviceNotFound {
        if aggregate.subDevices.contains(where: { $0.uid == query }) { return query }
        throw AudictlError.deviceNotFound(query: query)
    }
}

struct AggregateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "aggregate",
        abstract: "Create, inspect, edit, and destroy aggregate devices.",
        subcommands: [List.self, Show.self, Create.self, Destroy.self,
                      Add.self, Remove.self, SetClock.self, Drift.self]
    )

    struct AggregateRef: ParsableArguments {
        @OptionGroup var globals: GlobalOptions
        @OptionGroup var selector: SelectorOptions

        @Argument(help: "Aggregate device UID, numeric ID, or (partial) name.")
        var aggregate: String

        func resolve() throws -> (AggregateManager, DeviceSelector, AggregateDTO) {
            let manager = AggregateManager()
            let deviceSelector = DeviceSelector(manager: DeviceManager())
            let ref = try deviceSelector.resolve(aggregate, mode: selector.mode)
            return (manager, deviceSelector, try manager.show(ref.id))
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List aggregate and multi-output devices."
        )
        @OptionGroup var globals: GlobalOptions

        func run() throws {
            try rendered(globals, human: { (dto: AggregateListDTO, _) in
                dto.aggregates.isEmpty
                    ? "no aggregate devices"
                    : dto.aggregates.map(describeAggregate).joined(separator: "\n\n")
            }) {
                (AggregateListDTO(aggregates: try AggregateManager().listAggregates()), nil)
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Dump one aggregate's composition."
        )
        @OptionGroup var ref: AggregateRef

        func run() throws {
            try rendered(ref.globals, human: { (dto: AggregateDTO, _) in describeAggregate(dto) }) {
                let (_, _, dto) = try ref.resolve()
                return (dto, nil)
            }
        }
    }

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create an aggregate device."
        )

        @OptionGroup var globals: GlobalOptions
        @OptionGroup var selector: SelectorOptions

        @Option(help: "Name for the new aggregate device.")
        var name: String

        @Option(help: "Comma-separated sub-devices (UID, ID, or name each).")
        var devices: String

        @Option(help: "Sub-device that provides the clock (default: first).")
        var clock: String?

        @Option(help: "Enable drift compensation: 'all' or a comma-separated device list.")
        var drift: String?

        @Flag(help: "Make the aggregate visible only to this process.")
        var `private` = false

        @Option(help: "Custom UID (default: audictl-<uuid>).")
        var uid: String?

        func run() throws {
            try rendered(globals, human: { (dto: AggregateDTO, _) in describeAggregate(dto) }) {
                let deviceSelector = DeviceSelector(manager: DeviceManager())
                let subQueries = devices.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard !subQueries.isEmpty else {
                    throw ValidationError("--devices needs at least one device")
                }
                let subUIDs = try subQueries.map { try deviceSelector.resolve($0, mode: selector.mode).uid }
                let clockUID = try clock.map { try deviceSelector.resolve($0, mode: selector.mode).uid }
                    ?? subUIDs.first

                let driftUIDs: Set<String>
                if let drift {
                    if drift.lowercased() == "all" {
                        driftUIDs = Set(subUIDs)
                    } else {
                        driftUIDs = Set(try drift.split(separator: ",")
                            .map { try deviceSelector.resolve(String($0).trimmingCharacters(in: .whitespaces),
                                                              mode: selector.mode).uid })
                    }
                } else {
                    driftUIDs = []
                }

                let composition = AggregateComposition(
                    name: name,
                    uid: uid ?? "audictl-\(UUID().uuidString)",
                    subDevices: subUIDs.map { .init(uid: $0, drift: driftUIDs.contains($0)) },
                    clockUID: clockUID,
                    isPrivate: `private`,
                    isStacked: false
                )
                return (try AggregateManager().create(composition, timeout: globals.timeout), true)
            }
        }
    }

    struct Destroy: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "destroy",
            abstract: "Destroy an aggregate device."
        )

        @OptionGroup var globals: GlobalOptions
        @OptionGroup var selector: SelectorOptions

        @Argument(help: "Aggregate device UID, numeric ID, or (partial) name.")
        var aggregate: String

        @Flag(help: "Succeed (changed=false) when no such device exists.")
        var ifExists = false

        func run() throws {
            try destroyAggregate(globals: globals, mode: selector.mode,
                                 query: aggregate, ifExists: ifExists)
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add a sub-device to an aggregate."
        )

        @OptionGroup var ref: AggregateRef

        @Argument(help: "Device to add (UID, ID, or name).")
        var subdevice: String

        @Flag(help: "Enable drift compensation on the added sub-device.")
        var drift = false

        func run() throws {
            try rendered(ref.globals, human: { (dto: AggregateDTO, changed) in
                (changed == true ? "" : "already present\n") + describeAggregate(dto)
            }) {
                let (manager, deviceSelector, agg) = try ref.resolve()
                let subUID = try deviceSelector.resolve(subdevice, mode: ref.selector.mode).uid
                let changed = try manager.addSubDevice(agg.id, subUID: subUID, drift: drift,
                                                       timeout: ref.globals.timeout)
                return (try manager.show(agg.id), changed)
            }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Remove a sub-device from an aggregate."
        )

        @OptionGroup var ref: AggregateRef

        @Argument(help: "Sub-device to remove (UID, ID, or name).")
        var subdevice: String

        @Flag(help: "Succeed (changed=false) when the sub-device is not in the aggregate.")
        var ifAbsentOk = false

        func run() throws {
            try rendered(ref.globals, human: { (dto: AggregateDTO, changed) in
                (changed == true ? "" : "not a sub-device; nothing to do\n") + describeAggregate(dto)
            }) {
                let (manager, deviceSelector, agg) = try ref.resolve()
                let subUID = try resolveSubUID(subdevice, in: agg,
                                               selector: deviceSelector, mode: ref.selector.mode)
                let changed = try manager.removeSubDevice(agg.id, subUID: subUID, absentOK: ifAbsentOk,
                                                          timeout: ref.globals.timeout)
                return (try manager.show(agg.id), changed)
            }
        }
    }

    struct SetClock: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-clock",
            abstract: "Choose which sub-device provides the aggregate's clock."
        )

        @OptionGroup var ref: AggregateRef

        @Argument(help: "Sub-device to use as clock source (UID, ID, or name).")
        var subdevice: String

        func run() throws {
            try rendered(ref.globals, human: { (dto: AggregateDTO, _) in describeAggregate(dto) }) {
                let (manager, deviceSelector, agg) = try ref.resolve()
                let subUID = try resolveSubUID(subdevice, in: agg,
                                               selector: deviceSelector, mode: ref.selector.mode)
                let changed = try manager.setClock(agg.id, subUID: subUID, timeout: ref.globals.timeout)
                return (try manager.show(agg.id), changed)
            }
        }
    }

    struct Drift: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "drift",
            abstract: "Toggle drift compensation for one sub-device."
        )

        enum State: String, ExpressibleByArgument, CaseIterable {
            case on, off
        }

        @OptionGroup var ref: AggregateRef

        @Argument(help: "Sub-device (UID, ID, or name).")
        var subdevice: String

        @Argument(help: "on or off.")
        var state: State

        func run() throws {
            try rendered(ref.globals, human: { (dto: AggregateDTO, _) in describeAggregate(dto) }) {
                let (manager, deviceSelector, agg) = try ref.resolve()
                let subUID = try resolveSubUID(subdevice, in: agg,
                                               selector: deviceSelector, mode: ref.selector.mode)
                let changed = try manager.setDrift(agg.id, subUID: subUID, enabled: state == .on,
                                                   timeout: ref.globals.timeout)
                return (try manager.show(agg.id), changed)
            }
        }
    }
}

struct MultiCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "multi",
        abstract: "Create and destroy multi-output devices.",
        subcommands: [Create.self, Destroy.self]
    )

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a multi-output device.",
            discussion: "Drift compensation is enabled on every device except the primary (clock)."
        )

        @OptionGroup var globals: GlobalOptions
        @OptionGroup var selector: SelectorOptions

        @Option(help: "Name for the new multi-output device.")
        var name: String

        @Option(help: "Comma-separated output devices (UID, ID, or name each).")
        var devices: String

        @Option(help: "Primary device providing the clock (default: first).")
        var primary: String?

        func run() throws {
            try rendered(globals, human: { (dto: AggregateDTO, _) in describeAggregate(dto) }) {
                let deviceSelector = DeviceSelector(manager: DeviceManager())
                let subQueries = devices.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard !subQueries.isEmpty else {
                    throw ValidationError("--devices needs at least one device")
                }
                let subUIDs = try subQueries.map { try deviceSelector.resolve($0, mode: selector.mode).uid }
                let primaryUID = try primary.map { try deviceSelector.resolve($0, mode: selector.mode).uid }

                let composition = MultiOutput.composition(
                    name: name,
                    uid: "audictl-\(UUID().uuidString)",
                    subDeviceUIDs: subUIDs,
                    primaryUID: primaryUID
                )
                return (try AggregateManager().create(composition, timeout: globals.timeout), true)
            }
        }
    }

    struct Destroy: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "destroy",
            abstract: "Destroy a multi-output device."
        )

        @OptionGroup var globals: GlobalOptions
        @OptionGroup var selector: SelectorOptions

        @Argument(help: "Multi-output device UID, numeric ID, or (partial) name.")
        var device: String

        @Flag(help: "Succeed (changed=false) when no such device exists.")
        var ifExists = false

        func run() throws {
            try destroyAggregate(globals: globals, mode: selector.mode,
                                 query: device, ifExists: ifExists)
        }
    }
}
