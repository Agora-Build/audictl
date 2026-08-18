import CoreAudio
import Foundation

public extension AudioObjectPropertyAddress {
    init(_ selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) {
        self.init(mSelector: selector, mScope: scope, mElement: element)
    }
}

public let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

/// Typed accessors built on the raw HALClient seam.
public extension HALClient {
    func getProperty<T>(_ id: AudioObjectID,
                        _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> T {
        // `let x: UInt32? = try? getProperty(...)` infers T = Optional<UInt32>
        // and would load garbage; force call sites to the typed helpers below.
        guard !(T.self is ExpressibleByNilLiteral.Type) else {
            throw HALError(status: kAudioHardwareBadPropertySizeError,
                           operation: "getProperty inferred an Optional type — pin T explicitly")
        }
        let addr = AudioObjectPropertyAddress(selector, scope: scope, element: element)
        var size = try dataSize(id, addr)
        guard Int(size) >= MemoryLayout<T>.size else {
            throw HALError(status: kAudioHardwareBadPropertySizeError, operation: "getProperty")
        }
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<T>.alignment)
        defer { ptr.deallocate() }
        try getData(id, addr, into: ptr, size: &size)
        return ptr.load(as: T.self)
    }

    func getPropertyArray<T>(_ id: AudioObjectID,
                             _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                             element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> [T] {
        let addr = AudioObjectPropertyAddress(selector, scope: scope, element: element)
        var size = try dataSize(id, addr)
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { ptr.deallocate() }
        try getData(id, addr, into: ptr, size: &size)
        return Array(UnsafeBufferPointer(start: ptr, count: Int(size) / MemoryLayout<T>.stride))
    }

    func setProperty<T>(_ id: AudioObjectID,
                        _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                        value: T) throws {
        let addr = AudioObjectPropertyAddress(selector, scope: scope, element: element)
        var v = value
        try withUnsafeBytes(of: &v) { buffer in
            try setData(id, addr, from: buffer.baseAddress!, size: UInt32(MemoryLayout<T>.size))
        }
    }

    // Non-generic helpers: immune to the Optional-inference trap above.
    func getUInt32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                   element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> UInt32 {
        try getProperty(id, selector, scope: scope, element: element) as UInt32
    }

    func getFloat32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> Float32 {
        try getProperty(id, selector, scope: scope, element: element) as Float32
    }

    func getFloat64(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> Float64 {
        try getProperty(id, selector, scope: scope, element: element) as Float64
    }

    // CF object properties come back +1 retained; they must not go through the
    // generic load(as:) path or the retain is dropped on the floor.
    func getCFString(_ id: AudioObjectID,
                     _ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> String {
        let addr = AudioObjectPropertyAddress(selector, scope: scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try withUnsafeMutablePointer(to: &value) { ptr in
            try getData(id, addr, into: UnsafeMutableRawPointer(ptr), size: &size)
        }
        guard let cf = value?.takeRetainedValue() else {
            throw HALError(status: kAudioHardwareUnknownPropertyError, operation: "getCFString")
        }
        return cf as String
    }

    func getCFDictionary(_ id: AudioObjectID,
                         _ selector: AudioObjectPropertySelector) throws -> [String: Any] {
        let addr = AudioObjectPropertyAddress(selector)
        var value: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        try withUnsafeMutablePointer(to: &value) { ptr in
            try getData(id, addr, into: UnsafeMutableRawPointer(ptr), size: &size)
        }
        guard let cf = value?.takeRetainedValue(), let dict = cf as? [String: Any] else {
            throw HALError(status: kAudioHardwareUnknownPropertyError, operation: "getCFDictionary")
        }
        return dict
    }

    func setCFDictionary(_ id: AudioObjectID,
                         _ selector: AudioObjectPropertySelector,
                         _ dict: [String: Any]) throws {
        let addr = AudioObjectPropertyAddress(selector)
        var cf: CFDictionary? = dict as CFDictionary
        try withUnsafeMutablePointer(to: &cf) { ptr in
            try setData(id, addr, from: UnsafeRawPointer(ptr),
                        size: UInt32(MemoryLayout<CFDictionary?>.size))
        }
    }

    /// Channel counts per stream for a scope. AudioBufferList is variable-length,
    /// so it has to be walked, not load(as:)-ed.
    func streamChannelCounts(_ id: AudioObjectID,
                             scope: AudioObjectPropertyScope) throws -> [UInt32] {
        let addr = AudioObjectPropertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size = try dataSize(id, addr)
        guard size > 0 else { return [] }
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ptr.deallocate() }
        try getData(id, addr, into: ptr, size: &size)
        let listPtr = ptr.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(listPtr).map { $0.mNumberChannels }
    }
}
