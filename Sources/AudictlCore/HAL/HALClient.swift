import CoreAudio
import Foundation

/// Raw-bytes seam over the CoreAudio HAL. Everything typed is built on top of
/// this in HALProperties.swift, so a mock only needs to script byte buffers.
public protocol HALClient {
    func hasProperty(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool
    func isSettable(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> Bool
    func dataSize(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> UInt32
    func getData(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress,
                 into buffer: UnsafeMutableRawPointer, size: inout UInt32) throws
    func setData(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress,
                 from buffer: UnsafeRawPointer, size: UInt32) throws
    func createAggregate(_ composition: CFDictionary) throws -> AudioObjectID
    func destroyAggregate(_ id: AudioObjectID) throws
}

public struct CoreAudioHALClient: HALClient {
    public init() {}

    public func hasProperty(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var addr = address
        return AudioObjectHasProperty(id, &addr)
    }

    public func isSettable(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> Bool {
        var addr = address
        var settable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(id, &addr, &settable)
        guard status == noErr else { throw HALError(status: status, operation: "IsPropertySettable") }
        return settable.boolValue
    }

    public func dataSize(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> UInt32 {
        var addr = address
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
        guard status == noErr else { throw HALError(status: status, operation: "GetPropertyDataSize") }
        return size
    }

    public func getData(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress,
                        into buffer: UnsafeMutableRawPointer, size: inout UInt32) throws {
        var addr = address
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buffer)
        guard status == noErr else { throw HALError(status: status, operation: "GetPropertyData") }
    }

    public func setData(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress,
                        from buffer: UnsafeRawPointer, size: UInt32) throws {
        var addr = address
        let status = AudioObjectSetPropertyData(id, &addr, 0, nil, size, buffer)
        guard status == noErr else { throw HALError(status: status, operation: "SetPropertyData") }
    }

    public func createAggregate(_ composition: CFDictionary) throws -> AudioObjectID {
        var newID = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(composition, &newID)
        guard status == noErr else { throw HALError(status: status, operation: "CreateAggregateDevice") }
        return newID
    }

    public func destroyAggregate(_ id: AudioObjectID) throws {
        let status = AudioHardwareDestroyAggregateDevice(id)
        guard status == noErr else { throw HALError(status: status, operation: "DestroyAggregateDevice") }
    }
}
