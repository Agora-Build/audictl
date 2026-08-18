import CoreAudio
import Foundation

public enum SelectorMode {
    case auto, byUID, byID, byName
}

/// Resolves a user-supplied device string to a device.
///
/// Auto precedence: all-digits → AudioObjectID; exact UID (case-sensitive);
/// exact name (case-insensitive); unique case-insensitive substring of name.
public struct DeviceSelector {
    let manager: DeviceManager

    public init(manager: DeviceManager) {
        self.manager = manager
    }

    public func resolve(_ query: String, mode: SelectorMode = .auto) throws -> DeviceRef {
        let refs = try manager.allRefs()

        switch mode {
        case .byID:
            guard let numeric = UInt32(query), let match = refs.first(where: { $0.id == numeric }) else {
                throw AudictlError.deviceNotFound(query: query)
            }
            return match
        case .byUID:
            guard let match = refs.first(where: { $0.uid == query }) else {
                throw AudictlError.deviceNotFound(query: query)
            }
            return match
        case .byName:
            return try resolveByName(query, refs: refs)
        case .auto:
            if let numeric = UInt32(query), query.allSatisfy(\.isNumber),
               let match = refs.first(where: { $0.id == numeric }) {
                return match
            }
            if let match = refs.first(where: { $0.uid == query }) {
                return match
            }
            return try resolveByName(query, refs: refs)
        }
    }

    private func resolveByName(_ query: String, refs: [DeviceRef]) throws -> DeviceRef {
        let lowered = query.lowercased()
        let exact = refs.filter { $0.name.lowercased() == lowered }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { throw AudictlError.ambiguous(query: query, candidates: exact) }

        let substrings = refs.filter { $0.name.lowercased().contains(lowered) }
        switch substrings.count {
        case 0: throw AudictlError.deviceNotFound(query: query)
        case 1: return substrings[0]
        default: throw AudictlError.ambiguous(query: query, candidates: substrings)
        }
    }
}
