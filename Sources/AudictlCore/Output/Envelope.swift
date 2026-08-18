import Foundation

public let schemaVersion = 1

public struct SuccessEnvelope<T: Encodable>: Encodable {
    public let ok = true
    public let schemaVersion = AudictlCore.schemaVersion
    public let changed: Bool?
    public let data: T

    public init(data: T, changed: Bool? = nil) {
        self.data = data
        self.changed = changed
    }

    enum CodingKeys: String, CodingKey { case ok, schemaVersion, changed, data }
}

public struct ErrorEnvelope: Encodable {
    public struct Payload: Encodable {
        public let code: ErrorCode
        public let message: String
        public let details: JSONValue?
    }

    public let ok = false
    public let schemaVersion = AudictlCore.schemaVersion
    public let error: Payload

    enum CodingKeys: String, CodingKey { case ok, schemaVersion, error }

    public init(_ error: AudictlError) {
        self.error = Payload(code: error.code, message: error.message, details: error.jsonDetails)
    }
}

extension AudictlError {
    var jsonDetails: JSONValue? {
        switch self {
        case .deviceNotFound(let query):
            return .object(["query": .string(query)])
        case .ambiguous(let query, let candidates):
            return .object([
                "query": .string(query),
                "candidates": .array(candidates.map {
                    .object(["id": .number(Double($0.id)), "uid": .string($0.uid), "name": .string($0.name)])
                }),
            ])
        case .invalidSampleRate(let requested, let available):
            return .object([
                "requested": .number(requested),
                "available": .array(available.map { .number($0) }),
            ])
        case .subdeviceNotInAggregate(let agg, let sub):
            return .object(["aggregate": .string(agg), "subdevice": .string(sub)])
        case .hal(let err):
            return .object([
                "osStatus": .number(Double(err.status)),
                "fourcc": .string(err.fourCC),
                "operation": .string(err.operation),
            ])
        case .notAnAggregate, .unsupported, .timeout, .internalError:
            return nil
        }
    }
}

/// Small JSON value type so error details stay structured without Any-typing.
public enum JSONValue: Encodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 {
                try container.encode(Int64(n))
            } else {
                try container.encode(n)
            }
        case .bool(let b): try container.encode(b)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        case .null: try container.encodeNil()
        }
    }
}

public enum JSONRendering {
    public static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"schemaVersion":\#(schemaVersion),"error":{"code":"INTERNAL","message":"JSON encoding failed"}}"#
        }
        return string
    }
}
