import CoreAudio
import Foundation

public struct DeviceFilter: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let input = DeviceFilter(rawValue: 1 << 0)
    public static let output = DeviceFilter(rawValue: 1 << 1)
    public static let aggregate = DeviceFilter(rawValue: 1 << 2)
    public static let multiOutput = DeviceFilter(rawValue: 1 << 3)
}

public struct DeviceManager {
    let hal: HALClient

    public init(hal: HALClient = CoreAudioHALClient()) {
        self.hal = hal
    }

    public func allDeviceIDs() throws -> [AudioObjectID] {
        try hal.getPropertyArray(systemObjectID, kAudioHardwarePropertyDevices)
    }

    public func ref(for id: AudioObjectID) throws -> DeviceRef {
        DeviceRef(id: id,
                  uid: (try? hal.getCFString(id, kAudioDevicePropertyDeviceUID)) ?? "",
                  name: (try? hal.getCFString(id, kAudioObjectPropertyName)) ?? "")
    }

    public func allRefs() throws -> [DeviceRef] {
        try allDeviceIDs().map { try ref(for: $0) }
    }

    public func isAggregate(_ id: AudioObjectID) -> Bool {
        (try? hal.getUInt32(id, kAudioObjectPropertyClass)) == kAudioAggregateDeviceClassID
    }

    func composition(of id: AudioObjectID) -> [String: Any]? {
        guard isAggregate(id) else { return nil }
        return try? hal.getCFDictionary(id, kAudioAggregateDevicePropertyComposition)
    }

    public func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        let counts = (try? hal.streamChannelCounts(id, scope: scope)) ?? []
        return counts.reduce(0) { $0 + Int($1) }
    }

    public func defaultDeviceID(_ role: DefaultRole) throws -> AudioObjectID {
        try hal.getProperty(systemObjectID, role.selector)
    }

    /// Returns whether the default actually changed (false = idempotent no-op).
    public func setDefaultDevice(_ role: DefaultRole, to id: AudioObjectID) throws -> Bool {
        if (try? defaultDeviceID(role)) == id { return false }
        try hal.setProperty(systemObjectID, role.selector, value: id)
        return true
    }

    public func info(for id: AudioObjectID) throws -> DeviceInfoDTO {
        let uid = (try? hal.getCFString(id, kAudioDevicePropertyDeviceUID)) ?? ""
        let name = (try? hal.getCFString(id, kAudioObjectPropertyName)) ?? ""
        let manufacturer = try? hal.getCFString(id, kAudioObjectPropertyManufacturer)
        let transportRaw = (try? hal.getUInt32(id, kAudioDevicePropertyTransportType)) ?? kAudioDeviceTransportTypeUnknown
        let inputChannels = channelCount(id, scope: kAudioDevicePropertyScopeInput)
        let outputChannels = channelCount(id, scope: kAudioDevicePropertyScopeOutput)
        let sampleRate = try? hal.getFloat64(id, kAudioDevicePropertyNominalSampleRate)
        let availableRanges: [AudioValueRange]? = try? hal.getPropertyArray(id, kAudioDevicePropertyAvailableNominalSampleRates)
        let availableRates = availableRanges.map { ranges in
            ranges.flatMap { $0.mMinimum == $0.mMaximum ? [$0.mMinimum] : [$0.mMinimum, $0.mMaximum] }
                .sorted()
        }
        let alive = (try? hal.getUInt32(id, kAudioDevicePropertyDeviceIsAlive)) ?? 0
        let running = (try? hal.getUInt32(id, kAudioDevicePropertyDeviceIsRunningSomewhere)) ?? 0
        let comp = composition(of: id)
        let isAgg = isAggregate(id)
        let stacked = (comp?[kAudioAggregateDeviceIsStackedKey] as? Int ?? 0) == 1

        let volume = VolumeControl(hal: hal)
        let inputVolume = inputChannels > 0 ? try? volume.getVolume(id, scope: kAudioDevicePropertyScopeInput).volume : nil
        let outputVolume = outputChannels > 0 ? try? volume.getVolume(id, scope: kAudioDevicePropertyScopeOutput).volume : nil
        let inputMuted = inputChannels > 0 ? volume.getMute(id, scope: kAudioDevicePropertyScopeInput) : nil
        let outputMuted = outputChannels > 0 ? volume.getMute(id, scope: kAudioDevicePropertyScopeOutput) : nil

        return DeviceInfoDTO(
            id: id,
            uid: uid,
            name: name,
            manufacturer: manufacturer,
            transport: TransportType.string(for: transportRaw),
            input: .init(channels: inputChannels, volume: inputVolume ?? nil, muted: inputMuted),
            output: .init(channels: outputChannels, volume: outputVolume ?? nil, muted: outputMuted),
            sampleRate: sampleRate,
            availableSampleRates: availableRates,
            isDefaultInput: (try? defaultDeviceID(.input)) == id,
            isDefaultOutput: (try? defaultDeviceID(.output)) == id,
            isDefaultSystem: (try? defaultDeviceID(.system)) == id,
            isAggregate: isAgg,
            isMultiOutput: isAgg && stacked,
            isAlive: alive == 1,
            isRunning: running != 0
        )
    }

    public func list(filter: DeviceFilter = []) throws -> [DeviceInfoDTO] {
        try allDeviceIDs().map { try info(for: $0) }.filter { dto in
            if filter.isEmpty { return true }
            var match = false
            if filter.contains(.input), dto.input.channels > 0 { match = true }
            if filter.contains(.output), dto.output.channels > 0 { match = true }
            if filter.contains(.aggregate), dto.isAggregate { match = true }
            if filter.contains(.multiOutput), dto.isMultiOutput { match = true }
            return match
        }
    }
}
