import CoreAudio
import Foundation

public struct VolumeControl {
    let hal: HALClient

    public init(hal: HALClient = CoreAudioHALClient()) {
        self.hal = hal
    }

    // 'vmvc' — kAudioHardwareServiceDeviceProperty_VirtualMainVolume. Declared in
    // the deprecated AudioHardwareService header but served by plain AudioObject
    // get/set; defined locally to avoid importing AudioToolbox.
    static let virtualMainVolume = AudioObjectPropertySelector(0x766D_7663)

    func channelElements(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> [UInt32] {
        let count = ((try? hal.streamChannelCounts(id, scope: scope)) ?? [])
            .reduce(0) { $0 + Int($1) }
        guard count > 0 else { return [] }
        return (1...UInt32(count)).map { $0 }
    }

    // MARK: - Volume

    public func getVolume(_ id: AudioObjectID,
                          scope: AudioObjectPropertyScope) throws -> (volume: Double?, perChannel: [Int: Double]?) {
        let perChannel = readChannelVolumes(id, scope: scope)

        let virtualAddr = AudioObjectPropertyAddress(Self.virtualMainVolume, scope: scope)
        if hal.hasProperty(id, virtualAddr) {
            let v = try hal.getFloat32(id, Self.virtualMainVolume, scope: scope)
            return (Double(v), perChannel)
        }

        let mainAddr = AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: scope)
        if hal.hasProperty(id, mainAddr) {
            let v = try hal.getFloat32(id, kAudioDevicePropertyVolumeScalar, scope: scope)
            return (Double(v), perChannel)
        }

        if let perChannel, !perChannel.isEmpty {
            let avg = perChannel.values.reduce(0, +) / Double(perChannel.count)
            return (avg, perChannel)
        }
        throw AudictlError.unsupported("device does not expose a volume control for this scope")
    }

    private func readChannelVolumes(_ id: AudioObjectID,
                                    scope: AudioObjectPropertyScope) -> [Int: Double]? {
        var result: [Int: Double] = [:]
        for ch in channelElements(id, scope: scope) {
            let addr = AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: scope, element: ch)
            guard hal.hasProperty(id, addr) else { continue }
            if let v = try? hal.getFloat32(id, kAudioDevicePropertyVolumeScalar,
                                          scope: scope, element: ch) {
                result[Int(ch)] = Double(v)
            }
        }
        return result.isEmpty ? nil : result
    }

    public func setVolume(_ id: AudioObjectID,
                          scope: AudioObjectPropertyScope,
                          to value: Double,
                          channel: UInt32? = nil) throws -> Bool {
        let clamped = Float32(min(max(value, 0), 1))

        if let channel {
            return try setScalar(id, scope: scope, element: channel, value: clamped)
        }

        let virtualAddr = AudioObjectPropertyAddress(Self.virtualMainVolume, scope: scope)
        if hal.hasProperty(id, virtualAddr), (try? hal.isSettable(id, virtualAddr)) == true {
            let old = (try? hal.getFloat32(id, Self.virtualMainVolume, scope: scope)) ?? -1
            try hal.setProperty(id, Self.virtualMainVolume, scope: scope, value: clamped)
            return abs(old - clamped) > 0.0001
        }

        let mainAddr = AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: scope)
        if hal.hasProperty(id, mainAddr), (try? hal.isSettable(id, mainAddr)) == true {
            return try setScalar(id, scope: scope, element: kAudioObjectPropertyElementMain, value: clamped)
        }

        var changed = false
        var wroteAny = false
        for ch in channelElements(id, scope: scope) {
            let addr = AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: scope, element: ch)
            guard hal.hasProperty(id, addr), (try? hal.isSettable(id, addr)) == true else { continue }
            if try setScalar(id, scope: scope, element: ch, value: clamped) { changed = true }
            wroteAny = true
        }
        guard wroteAny else {
            throw AudictlError.unsupported("device does not expose a settable volume control for this scope")
        }
        return changed
    }

    private func setScalar(_ id: AudioObjectID, scope: AudioObjectPropertyScope,
                           element: AudioObjectPropertyElement, value: Float32) throws -> Bool {
        let addr = AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: scope, element: element)
        guard hal.hasProperty(id, addr) else {
            throw AudictlError.unsupported("no volume control on channel \(element) for this scope")
        }
        let old = (try? hal.getFloat32(id, kAudioDevicePropertyVolumeScalar,
                                       scope: scope, element: element)) ?? -1
        try hal.setProperty(id, kAudioDevicePropertyVolumeScalar, scope: scope, element: element, value: value)
        return abs(old - value) > 0.0001
    }

    // MARK: - Mute

    public func getMute(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool? {
        let mainAddr = AudioObjectPropertyAddress(kAudioDevicePropertyMute, scope: scope)
        if hal.hasProperty(id, mainAddr) {
            let v = try? hal.getUInt32(id, kAudioDevicePropertyMute, scope: scope)
            return v.map { $0 == 1 }
        }
        var states: [Bool] = []
        for ch in channelElements(id, scope: scope) {
            let addr = AudioObjectPropertyAddress(kAudioDevicePropertyMute, scope: scope, element: ch)
            guard hal.hasProperty(id, addr) else { continue }
            if let v = try? hal.getUInt32(id, kAudioDevicePropertyMute, scope: scope, element: ch) {
                states.append(v == 1)
            }
        }
        guard !states.isEmpty else { return nil }
        return states.allSatisfy { $0 }
    }

    public func setMute(_ id: AudioObjectID, scope: AudioObjectPropertyScope,
                        muted: Bool, channel: UInt32? = nil) throws -> Bool {
        let value: UInt32 = muted ? 1 : 0

        if let channel {
            let addr = AudioObjectPropertyAddress(kAudioDevicePropertyMute, scope: scope, element: channel)
            guard hal.hasProperty(id, addr), (try? hal.isSettable(id, addr)) == true else {
                throw AudictlError.unsupported("no mute control on channel \(channel) for this scope")
            }
            let old = try? hal.getUInt32(id, kAudioDevicePropertyMute, scope: scope, element: channel)
            try hal.setProperty(id, kAudioDevicePropertyMute, scope: scope, element: channel, value: value)
            return old != value
        }

        let mainAddr = AudioObjectPropertyAddress(kAudioDevicePropertyMute, scope: scope)
        if hal.hasProperty(id, mainAddr), (try? hal.isSettable(id, mainAddr)) == true {
            let old = try? hal.getUInt32(id, kAudioDevicePropertyMute, scope: scope)
            try hal.setProperty(id, kAudioDevicePropertyMute, scope: scope, value: value)
            return old != value
        }

        var changed = false
        var wroteAny = false
        for ch in channelElements(id, scope: scope) {
            let addr = AudioObjectPropertyAddress(kAudioDevicePropertyMute, scope: scope, element: ch)
            guard hal.hasProperty(id, addr), (try? hal.isSettable(id, addr)) == true else { continue }
            let old = try? hal.getUInt32(id, kAudioDevicePropertyMute, scope: scope, element: ch)
            try hal.setProperty(id, kAudioDevicePropertyMute, scope: scope, element: ch, value: value)
            if old != value { changed = true }
            wroteAny = true
        }
        guard wroteAny else {
            throw AudictlError.unsupported("device does not expose a settable mute control for this scope")
        }
        return changed
    }
}
