import CoreAudio
import Foundation
import Testing
@testable import AudictlCore

/// Real-HAL tests, opt-in via AUDICTL_INTEGRATION=1:
///
///     AUDICTL_INTEGRATION=1 swift test --filter IntegrationTests
///
/// The aggregates created here are private (visible only to this process),
/// so the user's device list is never polluted; each test destroys what it
/// creates even on failure.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AUDICTL_INTEGRATION"] == "1"))
struct AggregateLifecycleTests {
    private func anyOutputUID() throws -> String {
        let manager = DeviceManager()
        let dto = try manager.list(filter: .output).first { !$0.isAggregate && $0.isAlive }
        let uid = try #require(dto?.uid)
        return uid
    }

    private func makePrivate(_ subUIDs: [String], stacked: Bool = false) throws -> (AggregateManager, AggregateDTO) {
        let manager = AggregateManager()
        let dto = try manager.create(AggregateComposition(
            name: "audictl-test",
            uid: "audictl-test-\(UUID().uuidString)",
            subDevices: subUIDs.map { .init(uid: $0, drift: false) },
            clockUID: subUIDs.first,
            isPrivate: true,
            isStacked: stacked
        ), timeout: 5)
        return (manager, dto)
    }

    @Test func privateAggregateRoundTrip() throws {
        let out = try anyOutputUID()
        let (manager, dto) = try makePrivate([out])
        defer { try? manager.destroy(dto.id) }

        #expect(dto.isPrivate)
        #expect(dto.subDevices.map(\.uid) == [out])
        #expect(dto.clockDeviceUID == out)

        let rate = SampleRateControl()
        let current = try rate.current(dto.id)
        #expect(current > 0)
        #expect(try rate.availableRates(dto.id).contains(current))
    }

    @Test func editCompositionLive() throws {
        let out = try anyOutputUID()
        let mic = try DeviceManager().list(filter: .input).first { !$0.isAggregate && $0.uid != out }?.uid
        let (manager, dto) = try makePrivate([out])
        defer { try? manager.destroy(dto.id) }

        guard let mic else { return }  // single-device machines: create/destroy is still exercised

        #expect(try manager.addSubDevice(dto.id, subUID: mic, drift: true, timeout: 5))
        #expect(try manager.show(dto.id).subDevices.map(\.uid).contains(mic))
        #expect(try manager.setDrift(dto.id, subUID: mic, enabled: false, timeout: 5))
        #expect(try manager.setClock(dto.id, subUID: mic, timeout: 5))
        #expect(try manager.show(dto.id).clockDeviceUID == mic)
        #expect(try manager.removeSubDevice(dto.id, subUID: mic, timeout: 5))
        #expect(try !manager.show(dto.id).subDevices.map(\.uid).contains(mic))
    }

    @Test func publicCreateDestroyIsVisible() throws {
        let out = try anyOutputUID()
        let manager = AggregateManager()
        let dto = try manager.create(AggregateComposition(
            name: "audictl-visibility-test",
            uid: "audictl-vis-\(UUID().uuidString)",
            subDevices: [.init(uid: out, drift: false)],
            isPrivate: false
        ), timeout: 5)
        defer { try? manager.destroy(dto.id) }

        #expect(try DeviceManager().allDeviceIDs().contains(dto.id))
        try manager.destroy(dto.id)
        #expect(try !AggregateManager().listAggregates().contains { $0.uid == dto.uid })
    }
}
