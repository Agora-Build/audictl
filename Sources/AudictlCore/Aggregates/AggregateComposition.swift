import CoreAudio
import Foundation

/// Builder/parser for the aggregate-device composition dictionary.
///
/// Used for `create` and for presenting `show`. Edits to existing aggregates
/// deliberately do NOT round-trip through this type — they mutate the raw
/// dictionary in place so keys the HAL adds beyond these are preserved.
public struct AggregateComposition {
    public struct SubDevice: Equatable {
        public var uid: String
        public var drift: Bool
        public init(uid: String, drift: Bool) {
            self.uid = uid
            self.drift = drift
        }
    }

    public var name: String
    public var uid: String
    public var subDevices: [SubDevice]
    public var clockUID: String?
    public var isPrivate: Bool
    public var isStacked: Bool

    public init(name: String, uid: String, subDevices: [SubDevice],
                clockUID: String? = nil, isPrivate: Bool = false, isStacked: Bool = false) {
        self.name = name
        self.uid = uid
        self.subDevices = subDevices
        self.clockUID = clockUID
        self.isPrivate = isPrivate
        self.isStacked = isStacked
    }

    public func dictionary() -> [String: Any] {
        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceSubDeviceListKey: subDevices.map { sub in
                [kAudioSubDeviceUIDKey: sub.uid,
                 kAudioSubDeviceDriftCompensationKey: sub.drift ? 1 : 0] as [String: Any]
            },
            kAudioAggregateDeviceIsPrivateKey: isPrivate ? 1 : 0,
            kAudioAggregateDeviceIsStackedKey: isStacked ? 1 : 0,
        ]
        if let clockUID {
            dict[kAudioAggregateDeviceMainSubDeviceKey] = clockUID
        }
        return dict
    }

    public static func parse(_ dict: [String: Any]) -> AggregateComposition {
        AggregateComposition(
            name: dict[kAudioAggregateDeviceNameKey] as? String ?? "",
            uid: dict[kAudioAggregateDeviceUIDKey] as? String ?? "",
            subDevices: Self.parseSubDevices(dict),
            clockUID: dict[kAudioAggregateDeviceMainSubDeviceKey] as? String,
            isPrivate: (dict[kAudioAggregateDeviceIsPrivateKey] as? Int ?? 0) == 1,
            isStacked: (dict[kAudioAggregateDeviceIsStackedKey] as? Int ?? 0) == 1
        )
    }

    static func parseSubDevices(_ dict: [String: Any]) -> [SubDevice] {
        let list = dict[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]] ?? []
        return list.compactMap { sub in
            guard let uid = sub[kAudioSubDeviceUIDKey] as? String else { return nil }
            return SubDevice(uid: uid, drift: (sub[kAudioSubDeviceDriftCompensationKey] as? Int ?? 0) == 1)
        }
    }
}
