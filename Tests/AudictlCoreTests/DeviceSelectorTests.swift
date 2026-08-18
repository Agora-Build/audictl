import CoreAudio
import Testing
@testable import AudictlCore

private func makeSelector() -> (MockHALClient, DeviceSelector) {
    let hal = MockHALClient()
    hal.addDevice(id: 41, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")
    hal.addDevice(id: 42, uid: "AppleUSBAudioEngine:Focusrite:Scarlett", name: "Scarlett 2i2")
    hal.addDevice(id: 43, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    return (hal, DeviceSelector(manager: DeviceManager(hal: hal)))
}

@Suite struct DeviceSelectorTests {
    @Test func resolvesNumericID() throws {
        let (_, selector) = makeSelector()
        #expect(try selector.resolve("42").uid == "AppleUSBAudioEngine:Focusrite:Scarlett")
    }

    @Test func resolvesExactUID() throws {
        let (_, selector) = makeSelector()
        #expect(try selector.resolve("BuiltInSpeakerDevice").id == 41)
    }

    @Test func resolvesExactNameCaseInsensitive() throws {
        let (_, selector) = makeSelector()
        #expect(try selector.resolve("scarlett 2i2").id == 42)
    }

    @Test func resolvesUniqueSubstring() throws {
        let (_, selector) = makeSelector()
        #expect(try selector.resolve("scarlett").id == 42)
        #expect(try selector.resolve("microphone").id == 43)
    }

    @Test func ambiguousSubstringThrowsWithCandidates() throws {
        let (_, selector) = makeSelector()
        do {
            _ = try selector.resolve("macbook")
            Issue.record("expected ambiguous error")
        } catch let AudictlError.ambiguous(query, candidates) {
            #expect(query == "macbook")
            #expect(candidates.count == 2)
        }
    }

    @Test func missingDeviceThrowsNotFound() throws {
        let (_, selector) = makeSelector()
        do {
            _ = try selector.resolve("nonexistent")
            Issue.record("expected not-found error")
        } catch AudictlError.deviceNotFound(let query) {
            #expect(query == "nonexistent")
        }
    }

    @Test func numericStringFallsThroughWhenNoSuchID() throws {
        let (hal, _) = makeSelector()
        hal.addDevice(id: 44, uid: "Weird", name: "99")
        let selector = DeviceSelector(manager: DeviceManager(hal: hal))
        // No device with ID 99, but one named "99" — auto mode finds it by name.
        #expect(try selector.resolve("99").id == 44)
    }

    @Test func byIDModeRejectsNames() throws {
        let (_, selector) = makeSelector()
        do {
            _ = try selector.resolve("Scarlett 2i2", mode: .byID)
            Issue.record("expected not-found error")
        } catch AudictlError.deviceNotFound {}
    }

    @Test func byNameModeSkipsUIDs() throws {
        let (hal, _) = makeSelector()
        hal.addDevice(id: 45, uid: "MacBook Pro Speakers", name: "Impostor")
        let selector = DeviceSelector(manager: DeviceManager(hal: hal))
        // Auto mode prefers the UID match; byName mode goes to the real name.
        #expect(try selector.resolve("MacBook Pro Speakers").id == 45)
        #expect(try selector.resolve("MacBook Pro Speakers", mode: .byName).id == 41)
    }
}
