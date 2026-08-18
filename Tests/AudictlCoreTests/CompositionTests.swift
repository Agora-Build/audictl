import CoreAudio
import Testing
@testable import AudictlCore

@Suite struct CompositionTests {
    @Test func buildAndParseRoundTrip() {
        let comp = AggregateComposition(
            name: "Studio Rig",
            uid: "audictl-test",
            subDevices: [.init(uid: "dev-a", drift: false), .init(uid: "dev-b", drift: true)],
            clockUID: "dev-a",
            isPrivate: true,
            isStacked: false
        )
        let parsed = AggregateComposition.parse(comp.dictionary())
        #expect(parsed.name == "Studio Rig")
        #expect(parsed.uid == "audictl-test")
        #expect(parsed.subDevices == comp.subDevices)
        #expect(parsed.clockUID == "dev-a")
        #expect(parsed.isPrivate)
        #expect(!parsed.isStacked)
    }

    @Test func multiOutputDefaultsDriftOnNonPrimary() {
        let comp = MultiOutput.composition(name: "Everywhere", uid: "u",
                                           subDeviceUIDs: ["a", "b", "c"], primaryUID: "b")
        #expect(comp.isStacked)
        #expect(comp.clockUID == "b")
        #expect(comp.subDevices == [.init(uid: "a", drift: true),
                                    .init(uid: "b", drift: false),
                                    .init(uid: "c", drift: true)])
    }

    @Test func multiOutputPrimaryDefaultsToFirst() {
        let comp = MultiOutput.composition(name: "M", uid: "u",
                                           subDeviceUIDs: ["a", "b"], primaryUID: nil)
        #expect(comp.clockUID == "a")
        #expect(comp.subDevices.first?.drift == false)
        #expect(comp.subDevices.last?.drift == true)
    }
}

@Suite struct AggregateManagerTests {
    private func makeAggregate() throws -> (MockHALClient, AggregateManager, AggregateDTO) {
        let hal = MockHALClient()
        hal.addDevice(id: 41, uid: "dev-a", name: "Device A")
        hal.addDevice(id: 42, uid: "dev-b", name: "Device B")
        hal.addDevice(id: 43, uid: "dev-c", name: "Device C")
        let manager = AggregateManager(hal: hal)
        let dto = try manager.create(AggregateComposition(
            name: "Agg", uid: "agg-uid",
            subDevices: [.init(uid: "dev-a", drift: false), .init(uid: "dev-b", drift: true)],
            clockUID: "dev-a"
        ), timeout: 1)
        return (hal, manager, dto)
    }

    @Test func createBuildsVisibleAggregate() throws {
        let (_, _, dto) = try makeAggregate()
        #expect(dto.name == "Agg")
        #expect(dto.clockDeviceUID == "dev-a")
        #expect(dto.subDevices.map(\.uid) == ["dev-a", "dev-b"])
        #expect(dto.subDevices.map(\.driftCompensation) == [false, true])
        #expect(dto.subDevices.map(\.name) == ["Device A", "Device B"])
    }

    @Test func addSubDeviceIsIdempotent() throws {
        let (_, manager, dto) = try makeAggregate()
        #expect(try manager.addSubDevice(dto.id, subUID: "dev-c", drift: true, timeout: 1))
        #expect(try !manager.addSubDevice(dto.id, subUID: "dev-c", drift: true, timeout: 1))
        let after = try manager.show(dto.id)
        #expect(after.subDevices.map(\.uid) == ["dev-a", "dev-b", "dev-c"])
        #expect(after.subDevices.last?.driftCompensation == true)
    }

    @Test func removeSubDevice() throws {
        let (_, manager, dto) = try makeAggregate()
        #expect(try manager.removeSubDevice(dto.id, subUID: "dev-b", timeout: 1))
        #expect(try manager.show(dto.id).subDevices.map(\.uid) == ["dev-a"])
    }

    @Test func removeMissingThrowsUnlessAbsentOK() throws {
        let (_, manager, dto) = try makeAggregate()
        do {
            _ = try manager.removeSubDevice(dto.id, subUID: "dev-x", timeout: 1)
            Issue.record("expected subdeviceNotInAggregate")
        } catch AudictlError.subdeviceNotInAggregate {}
        #expect(try !manager.removeSubDevice(dto.id, subUID: "dev-x", absentOK: true, timeout: 1))
    }

    @Test func setClockValidatesMembership() throws {
        let (_, manager, dto) = try makeAggregate()
        #expect(try manager.setClock(dto.id, subUID: "dev-b", timeout: 1))
        #expect(try manager.show(dto.id).clockDeviceUID == "dev-b")
        #expect(try !manager.setClock(dto.id, subUID: "dev-b", timeout: 1))
        do {
            _ = try manager.setClock(dto.id, subUID: "dev-x", timeout: 1)
            Issue.record("expected subdeviceNotInAggregate")
        } catch AudictlError.subdeviceNotInAggregate {}
    }

    @Test func driftToggleRoundTrip() throws {
        let (_, manager, dto) = try makeAggregate()
        #expect(try manager.setDrift(dto.id, subUID: "dev-a", enabled: true, timeout: 1))
        #expect(try manager.show(dto.id).subDevices.first?.driftCompensation == true)
        #expect(try !manager.setDrift(dto.id, subUID: "dev-a", enabled: true, timeout: 1))
    }

    @Test func destroyRefusesNonAggregates() throws {
        let (_, manager, _) = try makeAggregate()
        do {
            try manager.destroy(41)
            Issue.record("expected notAnAggregate")
        } catch AudictlError.notAnAggregate(let ref) {
            #expect(ref.uid == "dev-a")
        }
    }

    @Test func editPreservesUnknownCompositionKeys() throws {
        let (hal, manager, dto) = try makeAggregate()
        let key = MockHALClient.Key(dto.id, AudioObjectPropertyAddress(kAudioAggregateDevicePropertyComposition))
        var raw = hal.cfProperties[key] as? [String: Any] ?? [:]
        raw["some hal key"] = "opaque"
        hal.cfProperties[key] = raw
        _ = try manager.addSubDevice(dto.id, subUID: "dev-c", drift: false, timeout: 1)
        let after = hal.cfProperties[key] as? [String: Any]
        #expect(after?["some hal key"] as? String == "opaque")
    }
}
