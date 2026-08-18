import CoreAudio
import Testing
@testable import AudictlCore

@Suite struct DeviceManagerTests {
    /// Mic (input-only), speakers (output-only), one aggregate, one multi-output.
    private func makeWorld() throws -> (MockHALClient, DeviceManager) {
        let hal = MockHALClient()
        hal.addDevice(id: 41, uid: "mic", name: "Mic")
        hal.stubChannels(41, scope: kAudioDevicePropertyScopeInput, buffers: [1])
        hal.addDevice(id: 42, uid: "spk", name: "Speakers")
        hal.stubChannels(42, scope: kAudioDevicePropertyScopeOutput, buffers: [2])
        let manager = AggregateManager(hal: hal)
        _ = try manager.create(AggregateComposition(
            name: "Agg", uid: "agg-uid", subDevices: [.init(uid: "mic", drift: false)]), timeout: 1)
        _ = try manager.create(AggregateComposition(
            name: "Multi", uid: "multi-uid", subDevices: [.init(uid: "spk", drift: true)],
            isStacked: true), timeout: 1)
        return (hal, DeviceManager(hal: hal))
    }

    @Test func filtersSelectByCapabilityAndClass() throws {
        let (_, dm) = try makeWorld()
        #expect(try dm.list().count == 4)
        #expect(try dm.list(filter: .input).map(\.name) == ["Mic"])
        #expect(try dm.list(filter: .output).map(\.name) == ["Speakers"])
        #expect(try dm.list(filter: .aggregate).map(\.name) == ["Agg", "Multi"])
        #expect(try dm.list(filter: .multiOutput).map(\.name) == ["Multi"])
        #expect(try dm.list(filter: [.input, .output]).map(\.name) == ["Mic", "Speakers"])
    }

    @Test func transportMapsKnownAndUnknownValues() throws {
        let (hal, dm) = try makeWorld()
        hal.stub(41, kAudioDevicePropertyTransportType, value: kAudioDeviceTransportTypeUSB)
        #expect(try dm.info(for: 41).transport == "usb")
        // Unknown FourCC values are surfaced literally rather than dropped.
        #expect(TransportType.string(for: 0x666F_6F62) == "foob")
        #expect(TransportType.string(for: kAudioDeviceTransportTypeUnknown) == "unknown")
    }

    @Test func setDefaultIsIdempotent() throws {
        let (hal, dm) = try makeWorld()
        hal.stub(systemObjectID, kAudioHardwarePropertyDefaultOutputDevice,
                 value: AudioObjectID(42), settable: true)
        #expect(try !dm.setDefaultDevice(.output, to: 42))
        hal.stub(systemObjectID, kAudioHardwarePropertyDefaultOutputDevice,
                 value: AudioObjectID(41), settable: true)
        #expect(try dm.setDefaultDevice(.output, to: 42))
        #expect(try dm.defaultDeviceID(.output) == 42)
    }

    @Test func infoMarksDefaults() throws {
        let (hal, dm) = try makeWorld()
        hal.stub(systemObjectID, kAudioHardwarePropertyDefaultInputDevice, value: AudioObjectID(41))
        let info = try dm.info(for: 41)
        #expect(info.isDefaultInput)
        #expect(!info.isDefaultOutput)
        #expect(info.input.channels == 1)
        #expect(info.output.channels == 0)
    }
}
