import CoreAudio
import Testing
@testable import AudictlCore

private let out = kAudioDevicePropertyScopeOutput
private let virtualMain = VolumeControl.virtualMainVolume

@Suite struct VolumeControlTests {
    @Test func prefersVirtualMainOverScalar() throws {
        let hal = MockHALClient()
        hal.stub(10, virtualMain, scope: out, value: Float32(0.5), settable: true)
        hal.stub(10, kAudioDevicePropertyVolumeScalar, scope: out, value: Float32(0.9))
        let (volume, _) = try VolumeControl(hal: hal).getVolume(10, scope: out)
        #expect(volume == 0.5)
    }

    @Test func fallsBackToMainScalar() throws {
        let hal = MockHALClient()
        hal.stub(11, kAudioDevicePropertyVolumeScalar, scope: out, value: Float32(0.25))
        let (volume, _) = try VolumeControl(hal: hal).getVolume(11, scope: out)
        #expect(volume == 0.25)
    }

    @Test func averagesPerChannelWhenNoMainControl() throws {
        let hal = MockHALClient()
        hal.stubChannels(12, scope: out, buffers: [2])
        hal.stub(12, kAudioDevicePropertyVolumeScalar, scope: out, element: 1, value: Float32(0.2))
        hal.stub(12, kAudioDevicePropertyVolumeScalar, scope: out, element: 2, value: Float32(0.6))
        let (volume, perChannel) = try VolumeControl(hal: hal).getVolume(12, scope: out)
        #expect(volume != nil && abs(volume! - 0.4) < 0.0001)
        #expect(perChannel?.count == 2)
    }

    @Test func noControlAtAllIsUnsupported() throws {
        let hal = MockHALClient()
        do {
            _ = try VolumeControl(hal: hal).getVolume(13, scope: out)
            Issue.record("expected unsupported")
        } catch AudictlError.unsupported {}
        do {
            _ = try VolumeControl(hal: hal).setVolume(13, scope: out, to: 0.5)
            Issue.record("expected unsupported")
        } catch AudictlError.unsupported {}
    }

    @Test func setVolumeReportsChangedOnlyOnRealChange() throws {
        let hal = MockHALClient()
        hal.stub(10, virtualMain, scope: out, value: Float32(0.5), settable: true)
        let control = VolumeControl(hal: hal)
        #expect(try control.setVolume(10, scope: out, to: 0.8))
        #expect(try !control.setVolume(10, scope: out, to: 0.8))
    }

    @Test func setVolumeWritesEveryChannelWhenOnlyChannelsExist() throws {
        let hal = MockHALClient()
        hal.stubChannels(12, scope: out, buffers: [2])
        hal.stub(12, kAudioDevicePropertyVolumeScalar, scope: out, element: 1, value: Float32(0.2), settable: true)
        hal.stub(12, kAudioDevicePropertyVolumeScalar, scope: out, element: 2, value: Float32(0.6), settable: true)
        #expect(try VolumeControl(hal: hal).setVolume(12, scope: out, to: 1.0))
        let elements = hal.setCalls.map(\.key.element).sorted()
        #expect(elements == [1, 2])
        let (volume, _) = try VolumeControl(hal: hal).getVolume(12, scope: out)
        #expect(volume == 1.0)
    }

    @Test func setVolumeClampsOutOfRange() throws {
        let hal = MockHALClient()
        hal.stub(10, virtualMain, scope: out, value: Float32(0.5), settable: true)
        _ = try VolumeControl(hal: hal).setVolume(10, scope: out, to: 7.5)
        let (volume, _) = try VolumeControl(hal: hal).getVolume(10, scope: out)
        #expect(volume == 1.0)
    }

    @Test func muteRoundTripAndIdempotency() throws {
        let hal = MockHALClient()
        hal.stub(14, kAudioDevicePropertyMute, scope: out, value: UInt32(0), settable: true)
        let control = VolumeControl(hal: hal)
        #expect(control.getMute(14, scope: out) == false)
        #expect(try control.setMute(14, scope: out, muted: true))
        #expect(control.getMute(14, scope: out) == true)
        #expect(try !control.setMute(14, scope: out, muted: true))
    }

    @Test func muteAbsentIsNilOnGetAndThrowsOnSet() throws {
        let hal = MockHALClient()
        let control = VolumeControl(hal: hal)
        #expect(control.getMute(15, scope: out) == nil)
        do {
            _ = try control.setMute(15, scope: out, muted: true)
            Issue.record("expected unsupported")
        } catch AudictlError.unsupported {}
    }
}

@Suite struct SampleRateControlTests {
    private func makeDevice(_ hal: MockHALClient, rates: [AudioValueRange], current: Double) {
        hal.stub(20, kAudioDevicePropertyNominalSampleRate, value: Float64(current), settable: true)
        hal.stubArray(20, kAudioDevicePropertyAvailableNominalSampleRates, values: rates)
    }

    @Test func availableRatesFlattenSortedDeduped() throws {
        let hal = MockHALClient()
        makeDevice(hal, rates: [.init(mMinimum: 48000, mMaximum: 48000),
                                .init(mMinimum: 44100, mMaximum: 44100),
                                .init(mMinimum: 8000, mMaximum: 96000)], current: 48000)
        #expect(try SampleRateControl(hal: hal).availableRates(20) == [8000, 44100, 48000, 96000])
    }

    @Test func setValidatesAgainstRanges() throws {
        let hal = MockHALClient()
        makeDevice(hal, rates: [.init(mMinimum: 44100, mMaximum: 44100),
                                .init(mMinimum: 48000, mMaximum: 48000)], current: 44100)
        do {
            _ = try SampleRateControl(hal: hal).set(20, to: 96000, timeout: 1)
            Issue.record("expected invalidSampleRate")
        } catch let AudictlError.invalidSampleRate(requested, available) {
            #expect(requested == 96000)
            #expect(available == [44100, 48000])
        }
    }

    @Test func setAppliesAndConfirms() throws {
        let hal = MockHALClient()
        makeDevice(hal, rates: [.init(mMinimum: 44100, mMaximum: 44100),
                                .init(mMinimum: 48000, mMaximum: 48000)], current: 44100)
        let control = SampleRateControl(hal: hal)
        #expect(try control.set(20, to: 48000, timeout: 1))
        #expect(try control.current(20) == 48000)
        #expect(try !control.set(20, to: 48000, timeout: 1))
    }

    @Test func ratesInsideARangeAreAccepted() throws {
        let hal = MockHALClient()
        makeDevice(hal, rates: [.init(mMinimum: 8000, mMaximum: 96000)], current: 48000)
        #expect(try SampleRateControl(hal: hal).set(20, to: 12345, timeout: 1))
    }
}
