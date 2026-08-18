import CoreAudio
import Foundation

public struct AggregateManager {
    let hal: HALClient
    let devices: DeviceManager

    public init(hal: HALClient = CoreAudioHALClient()) {
        self.hal = hal
        self.devices = DeviceManager(hal: hal)
    }

    // MARK: - Read

    public func listAggregates() throws -> [AggregateDTO] {
        try devices.allDeviceIDs().filter { devices.isAggregate($0) }.compactMap { try? show($0) }
    }

    public func show(_ id: AudioObjectID) throws -> AggregateDTO {
        guard devices.isAggregate(id) else {
            throw AudictlError.notAnAggregate(try devices.ref(for: id))
        }
        let raw = try hal.getCFDictionary(id, kAudioAggregateDevicePropertyComposition)
        let comp = AggregateComposition.parse(raw)
        let refsByUID = Dictionary(uniqueKeysWithValues: (try? devices.allRefs())?.map { ($0.uid, $0) } ?? [])
        return AggregateDTO(
            id: id,
            uid: comp.uid,
            name: comp.name,
            isMultiOutput: comp.isStacked,
            isPrivate: comp.isPrivate,
            clockDeviceUID: comp.clockUID,
            subDevices: comp.subDevices.map {
                SubDeviceDTO(uid: $0.uid, name: refsByUID[$0.uid]?.name, driftCompensation: $0.drift)
            }
        )
    }

    // MARK: - Lifecycle

    public func create(_ composition: AggregateComposition,
                       timeout: TimeInterval = 5) throws -> AggregateDTO {
        let id = try hal.createAggregate(composition.dictionary() as CFDictionary)
        try waitUntil(timeout: timeout, what: "aggregate device to appear") {
            let alive = (try? hal.getUInt32(id, kAudioDevicePropertyDeviceIsAlive)) ?? 0
            guard alive == 1 else { return false }
            let raw = (try? hal.getCFDictionary(id, kAudioAggregateDevicePropertyComposition)) ?? [:]
            let subs = AggregateComposition.parseSubDevices(raw).map(\.uid)
            return Set(subs) == Set(composition.subDevices.map(\.uid))
        }
        return try show(id)
    }

    public func destroy(_ id: AudioObjectID, timeout: TimeInterval = 5) throws {
        guard devices.isAggregate(id) else {
            throw AudictlError.notAnAggregate(try devices.ref(for: id))
        }
        try hal.destroyAggregate(id)
        // Destruction is asynchronous like creation: wait until the device is
        // actually gone so callers can trust the post-state.
        try waitUntil(timeout: timeout, what: "aggregate device to disappear") {
            let ids = (try? devices.allDeviceIDs()) ?? []
            return !ids.contains(id)
        }
    }

    // MARK: - Edits (read-modify-write on the raw composition)

    public func addSubDevice(_ aggID: AudioObjectID, subUID: String,
                             drift: Bool, timeout: TimeInterval = 5) throws -> Bool {
        try editComposition(aggID, timeout: timeout) { raw in
            var list = raw[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]] ?? []
            guard !list.contains(where: { $0[kAudioSubDeviceUIDKey] as? String == subUID }) else {
                return false
            }
            list.append([kAudioSubDeviceUIDKey: subUID,
                         kAudioSubDeviceDriftCompensationKey: drift ? 1 : 0])
            raw[kAudioAggregateDeviceSubDeviceListKey] = list
            return true
        } verify: { raw in
            AggregateComposition.parseSubDevices(raw).contains { $0.uid == subUID }
        }
    }

    public func removeSubDevice(_ aggID: AudioObjectID, subUID: String,
                                absentOK: Bool = false, timeout: TimeInterval = 5) throws -> Bool {
        try editComposition(aggID, timeout: timeout) { raw in
            var list = raw[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]] ?? []
            let before = list.count
            list.removeAll { $0[kAudioSubDeviceUIDKey] as? String == subUID }
            guard list.count != before else {
                if absentOK { return false }
                throw AudictlError.subdeviceNotInAggregate(aggregate: aggregateName(aggID), subdevice: subUID)
            }
            raw[kAudioAggregateDeviceSubDeviceListKey] = list
            return true
        } verify: { raw in
            !AggregateComposition.parseSubDevices(raw).contains { $0.uid == subUID }
        }
    }

    public func setClock(_ aggID: AudioObjectID, subUID: String,
                         timeout: TimeInterval = 5) throws -> Bool {
        try editComposition(aggID, timeout: timeout) { raw in
            guard AggregateComposition.parseSubDevices(raw).contains(where: { $0.uid == subUID }) else {
                throw AudictlError.subdeviceNotInAggregate(aggregate: aggregateName(aggID), subdevice: subUID)
            }
            guard raw[kAudioAggregateDeviceMainSubDeviceKey] as? String != subUID else { return false }
            raw[kAudioAggregateDeviceMainSubDeviceKey] = subUID
            return true
        } verify: { raw in
            raw[kAudioAggregateDeviceMainSubDeviceKey] as? String == subUID
        }
    }

    public func setDrift(_ aggID: AudioObjectID, subUID: String, enabled: Bool,
                         timeout: TimeInterval = 5) throws -> Bool {
        try editComposition(aggID, timeout: timeout) { raw in
            var list = raw[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]] ?? []
            guard let idx = list.firstIndex(where: { $0[kAudioSubDeviceUIDKey] as? String == subUID }) else {
                throw AudictlError.subdeviceNotInAggregate(aggregate: aggregateName(aggID), subdevice: subUID)
            }
            let current = (list[idx][kAudioSubDeviceDriftCompensationKey] as? Int ?? 0) == 1
            guard current != enabled else { return false }
            list[idx][kAudioSubDeviceDriftCompensationKey] = enabled ? 1 : 0
            raw[kAudioAggregateDeviceSubDeviceListKey] = list
            return true
        } verify: { raw in
            AggregateComposition.parseSubDevices(raw).first { $0.uid == subUID }?.drift == enabled
        }
    }

    // MARK: - Internals

    private func aggregateName(_ id: AudioObjectID) -> String {
        (try? hal.getCFString(id, kAudioObjectPropertyName)) ?? String(id)
    }

    /// Applies `mutate` to the current composition; if it reports a change,
    /// writes the whole dictionary back atomically and polls `verify`.
    private func editComposition(_ aggID: AudioObjectID,
                                 timeout: TimeInterval,
                                 mutate: (inout [String: Any]) throws -> Bool,
                                 verify: @escaping ([String: Any]) -> Bool) throws -> Bool {
        guard devices.isAggregate(aggID) else {
            throw AudictlError.notAnAggregate(try devices.ref(for: aggID))
        }
        var raw = try hal.getCFDictionary(aggID, kAudioAggregateDevicePropertyComposition)
        guard try mutate(&raw) else { return false }
        try hal.setCFDictionary(aggID, kAudioAggregateDevicePropertyComposition, raw)
        try waitUntil(timeout: timeout, what: "aggregate composition to settle") {
            guard let readback = try? hal.getCFDictionary(aggID, kAudioAggregateDevicePropertyComposition) else {
                return false
            }
            return verify(readback)
        }
        return true
    }

    func waitUntil(timeout: TimeInterval, what: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            usleep(50_000)
        }
        throw AudictlError.timeout(what)
    }
}
