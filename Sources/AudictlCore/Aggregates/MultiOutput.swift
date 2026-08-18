import CoreAudio
import Foundation

/// Multi-output devices are stacked aggregates. Audio MIDI Setup convention:
/// drift compensation on every sub-device except the clock/primary.
public enum MultiOutput {
    public static func composition(name: String, uid: String,
                                   subDeviceUIDs: [String],
                                   primaryUID: String?) -> AggregateComposition {
        let primary = primaryUID ?? subDeviceUIDs.first
        return AggregateComposition(
            name: name,
            uid: uid,
            subDevices: subDeviceUIDs.map {
                .init(uid: $0, drift: $0 != primary)
            },
            clockUID: primary,
            isPrivate: false,
            isStacked: true
        )
    }
}
