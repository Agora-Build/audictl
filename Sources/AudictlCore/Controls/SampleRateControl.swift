import CoreAudio
import Foundation

public struct SampleRateControl {
    let hal: HALClient

    public init(hal: HALClient = CoreAudioHALClient()) {
        self.hal = hal
    }

    public func current(_ id: AudioObjectID) throws -> Double {
        try hal.getFloat64(id, kAudioDevicePropertyNominalSampleRate)
    }

    public func availableRanges(_ id: AudioObjectID) throws -> [AudioValueRange] {
        try hal.getPropertyArray(id, kAudioDevicePropertyAvailableNominalSampleRates)
    }

    /// Discrete rates (min==max ranges) plus range endpoints, sorted, deduped.
    public func availableRates(_ id: AudioObjectID) throws -> [Double] {
        let ranges = try availableRanges(id)
        let rates = ranges.flatMap { $0.mMinimum == $0.mMaximum ? [$0.mMinimum] : [$0.mMinimum, $0.mMaximum] }
        return Array(Set(rates)).sorted()
    }

    /// Returns whether the rate actually changed. Some devices apply the rate
    /// asynchronously, so the set is confirmed by polling the readback.
    public func set(_ id: AudioObjectID, to hz: Double, timeout: TimeInterval = 5) throws -> Bool {
        let now = try current(id)
        if now == hz { return false }

        let ranges = try availableRanges(id)
        guard ranges.contains(where: { hz >= $0.mMinimum && hz <= $0.mMaximum }) else {
            let rates = ranges.flatMap { $0.mMinimum == $0.mMaximum ? [$0.mMinimum] : [$0.mMinimum, $0.mMaximum] }
            throw AudictlError.invalidSampleRate(requested: hz, available: Array(Set(rates)).sorted())
        }

        try hal.setProperty(id, kAudioDevicePropertyNominalSampleRate, value: Float64(hz))

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? current(id)) == hz { return true }
            usleep(50_000)
        }
        throw AudictlError.timeout("sample rate to settle at \(String(format: "%g", hz)) Hz")
    }
}
