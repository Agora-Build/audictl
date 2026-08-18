import Foundation

public enum ErrorCode: String, Codable {
    case deviceNotFound = "DEVICE_NOT_FOUND"
    case ambiguousDevice = "AMBIGUOUS_DEVICE"
    case notAnAggregate = "NOT_AN_AGGREGATE"
    case unsupportedOperation = "UNSUPPORTED_OPERATION"
    case invalidSampleRate = "INVALID_SAMPLE_RATE"
    case subdeviceNotInAggregate = "SUBDEVICE_NOT_IN_AGGREGATE"
    case halError = "HAL_ERROR"
    case timeout = "TIMEOUT"
    case internalError = "INTERNAL"
}

/// Minimal reference to a device, used in error details and candidate lists.
public struct DeviceRef: Codable, Equatable {
    public let id: UInt32
    public let uid: String
    public let name: String

    public init(id: UInt32, uid: String, name: String) {
        self.id = id
        self.uid = uid
        self.name = name
    }
}

public enum AudictlError: Error {
    case deviceNotFound(query: String)
    case ambiguous(query: String, candidates: [DeviceRef])
    case notAnAggregate(DeviceRef)
    case unsupported(String)
    case invalidSampleRate(requested: Double, available: [Double])
    case subdeviceNotInAggregate(aggregate: String, subdevice: String)
    case timeout(String)
    case hal(HALError)
    case internalError(String)

    public var code: ErrorCode {
        switch self {
        case .deviceNotFound: return .deviceNotFound
        case .ambiguous: return .ambiguousDevice
        case .notAnAggregate: return .notAnAggregate
        case .unsupported: return .unsupportedOperation
        case .invalidSampleRate: return .invalidSampleRate
        case .subdeviceNotInAggregate: return .subdeviceNotInAggregate
        case .timeout: return .timeout
        case .hal: return .halError
        case .internalError: return .internalError
        }
    }

    /// Process exit code; part of the agent contract in SCHEMA.md.
    public var exitCode: Int32 {
        switch self {
        case .internalError: return 1
        case .deviceNotFound: return 2
        case .ambiguous: return 3
        case .notAnAggregate, .unsupported, .subdeviceNotInAggregate, .invalidSampleRate: return 4
        case .hal: return 5
        case .timeout: return 6
        }
    }

    public var message: String {
        switch self {
        case .deviceNotFound(let q):
            return "no device matches '\(q)'"
        case .ambiguous(let q, let candidates):
            return "'\(q)' matches \(candidates.count) devices"
        case .notAnAggregate(let ref):
            return "'\(ref.name)' is not an aggregate device"
        case .unsupported(let what):
            return what
        case .invalidSampleRate(let requested, let available):
            let rates = available.map { String(format: "%g", $0) }.joined(separator: ", ")
            return "sample rate \(String(format: "%g", requested)) not supported (available: \(rates))"
        case .subdeviceNotInAggregate(let agg, let sub):
            return "'\(sub)' is not a sub-device of '\(agg)'"
        case .timeout(let what):
            return "timed out waiting for \(what)"
        case .hal(let err):
            return err.message
        case .internalError(let msg):
            return msg
        }
    }
}
