import AudictlCore
import Testing
@testable import audictl

@Suite struct RenderingTests {
    @Test func tableAlignsColumns() {
        let lines = formatTableLines([["1", "Speakers"], ["130", "M"]], header: ["ID", "NAME"])
        #expect(lines == ["ID   NAME",
                          "1    Speakers",
                          "130  M"])
    }

    @Test func subDeviceLineMarkers() {
        let clock = SubDeviceDTO(uid: "a", name: "Device A", driftCompensation: false)
        let drifting = SubDeviceDTO(uid: "b", name: "Device B", driftCompensation: true)
        let offline = SubDeviceDTO(uid: "gone-uid", name: nil, driftCompensation: false)
        #expect(subDeviceLine(clock, clockUID: "a", indent: "  ") == "  └ Device A [clock]")
        #expect(subDeviceLine(drifting, clockUID: "a", indent: "  ") == "  └ Device B drift")
        #expect(subDeviceLine(offline, clockUID: "a", indent: "  ") == "  └ gone-uid")
    }

    @Test func describeDeviceListsMembership() {
        let dto = DeviceInfoDTO(
            id: 54, uid: "multi-uid", name: "Multi", manufacturer: nil,
            transport: "aggregate",
            input: .init(channels: 0), output: .init(channels: 2),
            sampleRate: 48000, availableSampleRates: nil,
            isDefaultInput: false, isDefaultOutput: false, isDefaultSystem: false,
            isAggregate: true, isMultiOutput: true, isAlive: true, isRunning: false,
            subDevices: [SubDeviceDTO(uid: "spk", name: "Speakers", driftCompensation: true)],
            clockDeviceUID: "spk"
        )
        let text = describeDevice(dto)
        #expect(text.contains("contains:"))
        #expect(text.contains("└ Speakers [clock] drift"))
    }

    @Test func rateFormatting() {
        #expect(formatRate(44100) == "44.1 kHz")
        #expect(formatRate(48000) == "48.0 kHz")
        #expect(formatRate(44056) == "44056 Hz")
    }
}
