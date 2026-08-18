import CoreAudio
import Testing
@testable import AudictlCore

/// Golden JSON snapshots — an encoding change here is a schema break and must
/// come with a schemaVersion bump (see SCHEMA.md).
@Suite struct EnvelopeGoldenTests {
    @Test func successEnvelope() {
        let dto = SampleRateDTO(
            device: DeviceRef(id: 42, uid: "dev-uid", name: "Scarlett 2i2"),
            sampleRate: 48000,
            availableSampleRates: [44100, 48000]
        )
        let json = JSONRendering.encode(SuccessEnvelope(data: dto, changed: true))
        #expect(json == #"{"changed":true,"data":{"availableSampleRates":[44100,48000],"device":{"id":42,"name":"Scarlett 2i2","uid":"dev-uid"},"sampleRate":48000},"ok":true,"schemaVersion":1}"#)
    }

    @Test func successEnvelopeOmitsChangedWhenNil() {
        let json = JSONRendering.encode(SuccessEnvelope(data: DeviceListDTO(devices: [])))
        #expect(json == #"{"data":{"devices":[]},"ok":true,"schemaVersion":1}"#)
    }

    @Test func ambiguousErrorEnvelope() {
        let err = AudictlError.ambiguous(query: "macbook", candidates: [
            DeviceRef(id: 41, uid: "spk", name: "MacBook Pro Speakers"),
            DeviceRef(id: 43, uid: "mic", name: "MacBook Pro Microphone"),
        ])
        let json = JSONRendering.encode(ErrorEnvelope(err))
        #expect(json == #"{"error":{"code":"AMBIGUOUS_DEVICE","details":{"candidates":[{"id":41,"name":"MacBook Pro Speakers","uid":"spk"},{"id":43,"name":"MacBook Pro Microphone","uid":"mic"}],"query":"macbook"},"message":"'macbook' matches 2 devices"},"ok":false,"schemaVersion":1}"#)
    }

    @Test func halErrorEnvelopeCarriesOSStatus() {
        let err = AudictlError.hal(HALError(status: kAudioHardwareBadDeviceError, operation: "GetPropertyData"))
        let json = JSONRendering.encode(ErrorEnvelope(err))
        #expect(json.contains(#""code":"HAL_ERROR""#))
        #expect(json.contains(#""fourcc":"!dev""#))
        #expect(json.contains("\"osStatus\":\(kAudioHardwareBadDeviceError)"))
    }

    @Test func invalidSampleRateDetails() {
        let err = AudictlError.invalidSampleRate(requested: 192000, available: [44100, 48000])
        let json = JSONRendering.encode(ErrorEnvelope(err))
        #expect(json == #"{"error":{"code":"INVALID_SAMPLE_RATE","details":{"available":[44100,48000],"requested":192000},"message":"sample rate 192000 not supported (available: 44100, 48000)"},"ok":false,"schemaVersion":1}"#)
    }
}

@Suite struct HALErrorTests {
    @Test func fourCCDecoding() {
        #expect(HALError(status: kAudioHardwareBadDeviceError, operation: "").fourCC == "!dev")
        #expect(HALError(status: kAudioHardwareUnknownPropertyError, operation: "").fourCC == "who?")
        #expect(HALError(status: kAudioHardwareUnsupportedOperationError, operation: "").fourCC == "unop")
    }

    @Test func nonPrintableFallsBackToNumber() {
        #expect(HALError(status: -50, operation: "").fourCC == "-50")
    }

    @Test func exitCodes() {
        #expect(AudictlError.deviceNotFound(query: "x").exitCode == 2)
        #expect(AudictlError.ambiguous(query: "x", candidates: []).exitCode == 3)
        #expect(AudictlError.unsupported("x").exitCode == 4)
        #expect(AudictlError.invalidSampleRate(requested: 1, available: []).exitCode == 4)
        #expect(AudictlError.hal(HALError(status: 1, operation: "")).exitCode == 5)
        #expect(AudictlError.timeout("x").exitCode == 6)
        #expect(AudictlError.internalError("x").exitCode == 1)
    }
}
