import CoreAudio
import Foundation
@testable import AudictlCore

/// Scripted HAL for unit tests: a table of (objectID, address) → bytes,
/// plus a recording of every set call.
final class MockHALClient: HALClient {
    struct Key: Hashable {
        let id: AudioObjectID
        let selector: AudioObjectPropertySelector
        let scope: AudioObjectPropertyScope
        let element: AudioObjectPropertyElement

        init(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) {
            self.id = id
            self.selector = address.mSelector
            self.scope = address.mScope
            self.element = address.mElement
        }
    }

    struct SetCall {
        let key: Key
        let bytes: [UInt8]
    }

    var properties: [Key: [UInt8]] = [:]
    var cfProperties: [Key: Any] = [:]
    var settable: Set<Key> = []
    var setCalls: [SetCall] = []
    var aggregates: [AudioObjectID: [String: Any]] = [:]
    var nextAggregateID: AudioObjectID = 1000

    // MARK: - Scripting helpers

    func stub<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                 value: T, settable isSettable: Bool = false) {
        var v = value
        let bytes = withUnsafeBytes(of: &v) { Array($0) }
        let key = Key(id, AudioObjectPropertyAddress(selector, scope: scope, element: element))
        properties[key] = bytes
        if isSettable { settable.insert(key) }
    }

    func stubArray<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      values: [T]) {
        var bytes: [UInt8] = []
        for var v in values {
            withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) }
        }
        properties[Key(id, AudioObjectPropertyAddress(selector, scope: scope))] = bytes
    }

    func stubCF(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                value: Any) {
        cfProperties[Key(id, AudioObjectPropertyAddress(selector, scope: scope))] = value
    }

    /// Stubs kAudioDevicePropertyStreamConfiguration: one stream per entry,
    /// each with that many channels.
    func stubChannels(_ id: AudioObjectID, scope: AudioObjectPropertyScope, buffers: [UInt32]) {
        let count = max(buffers.count, 1)
        let size = AudioBufferList.sizeInBytes(maximumBuffers: count)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size,
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
        abl.pointee.mNumberBuffers = UInt32(buffers.count)
        let list = UnsafeMutableAudioBufferListPointer(abl)
        for (i, channels) in buffers.enumerated() {
            list[i].mNumberChannels = channels
            list[i].mDataByteSize = 0
            list[i].mData = nil
        }
        let key = Key(id, AudioObjectPropertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope))
        properties[key] = Array(UnsafeRawBufferPointer(start: raw, count: size))
    }

    /// Registers a device with the common identity properties.
    func addDevice(id: AudioObjectID, uid: String, name: String) {
        stubCF(id, kAudioDevicePropertyDeviceUID, value: uid)
        stubCF(id, kAudioObjectPropertyName, value: name)
        let existing: [AudioObjectID] = deviceList()
        stubArray(systemObjectID, kAudioHardwarePropertyDevices, values: existing + [id])
    }

    private func deviceList() -> [AudioObjectID] {
        let key = Key(systemObjectID, AudioObjectPropertyAddress(kAudioHardwarePropertyDevices))
        guard let bytes = properties[key] else { return [] }
        return bytes.withUnsafeBytes { Array($0.bindMemory(to: AudioObjectID.self)) }
    }

    // MARK: - HALClient

    func hasProperty(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        let key = Key(id, address)
        return properties[key] != nil || cfProperties[key] != nil
    }

    func isSettable(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> Bool {
        settable.contains(Key(id, address))
    }

    func dataSize(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> UInt32 {
        let key = Key(id, address)
        if let bytes = properties[key] { return UInt32(bytes.count) }
        if cfProperties[key] != nil { return UInt32(MemoryLayout<UnsafeRawPointer>.size) }
        throw HALError(status: kAudioHardwareUnknownPropertyError, operation: "mock dataSize")
    }

    func getData(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress,
                 into buffer: UnsafeMutableRawPointer, size: inout UInt32) throws {
        let key = Key(id, address)
        if let bytes = properties[key] {
            let n = min(Int(size), bytes.count)
            bytes.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: n) }
            size = UInt32(n)
            return
        }
        if let cf = cfProperties[key] {
            // Hand out a +1 retained CF object, matching the real HAL contract.
            if let s = cf as? String {
                let unmanaged = Unmanaged.passRetained(s as CFString)
                buffer.assumingMemoryBound(to: Unmanaged<CFString>?.self).pointee = unmanaged
            } else if let d = cf as? [String: Any] {
                let unmanaged = Unmanaged.passRetained(d as CFDictionary)
                buffer.assumingMemoryBound(to: Unmanaged<CFDictionary>?.self).pointee = unmanaged
            }
            return
        }
        throw HALError(status: kAudioHardwareUnknownPropertyError, operation: "mock getData")
    }

    func setData(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress,
                 from buffer: UnsafeRawPointer, size: UInt32) throws {
        let key = Key(id, address)
        guard hasProperty(id, address) else {
            throw HALError(status: kAudioHardwareUnknownPropertyError, operation: "mock setData")
        }
        // CF-typed set (composition rewrite): capture and mirror into cfProperties.
        if cfProperties[key] != nil {
            let unmanaged = buffer.assumingMemoryBound(to: Unmanaged<CFDictionary>?.self).pointee
            if let dict = unmanaged?.takeUnretainedValue() as? [String: Any] {
                cfProperties[key] = dict
                setCalls.append(SetCall(key: key, bytes: []))
                return
            }
        }
        let bytes = Array(UnsafeRawBufferPointer(start: buffer, count: Int(size)))
        properties[key] = bytes
        setCalls.append(SetCall(key: key, bytes: bytes))
    }

    func createAggregate(_ composition: CFDictionary) throws -> AudioObjectID {
        let id = nextAggregateID
        nextAggregateID += 1
        let dict = composition as? [String: Any] ?? [:]
        aggregates[id] = dict
        addDevice(id: id,
                  uid: dict[kAudioAggregateDeviceUIDKey] as? String ?? "",
                  name: dict[kAudioAggregateDeviceNameKey] as? String ?? "")
        stub(id, kAudioObjectPropertyClass, value: kAudioAggregateDeviceClassID)
        stub(id, kAudioDevicePropertyDeviceIsAlive, value: UInt32(1))
        stubCF(id, kAudioAggregateDevicePropertyComposition, value: dict)
        return id
    }

    func destroyAggregate(_ id: AudioObjectID) throws {
        guard aggregates.removeValue(forKey: id) != nil else {
            throw HALError(status: kAudioHardwareBadDeviceError, operation: "mock destroyAggregate")
        }
        let remaining = deviceList().filter { $0 != id }
        stubArray(systemObjectID, kAudioHardwarePropertyDevices, values: remaining)
    }
}
