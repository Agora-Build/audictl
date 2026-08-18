import Foundation

public struct DeviceInfoDTO: Codable, Equatable {
    public struct Direction: Codable, Equatable {
        public let channels: Int
        public let volume: Double?
        public let muted: Bool?
        public init(channels: Int, volume: Double? = nil, muted: Bool? = nil) {
            self.channels = channels
            self.volume = volume
            self.muted = muted
        }
    }

    public let id: UInt32
    public let uid: String
    public let name: String
    public let manufacturer: String?
    public let transport: String
    public let input: Direction
    public let output: Direction
    public let sampleRate: Double?
    public let availableSampleRates: [Double]?
    public let isDefaultInput: Bool
    public let isDefaultOutput: Bool
    public let isDefaultSystem: Bool
    public let isAggregate: Bool
    public let isMultiOutput: Bool
    public let isAlive: Bool
    public let isRunning: Bool

    public init(id: UInt32, uid: String, name: String, manufacturer: String?,
                transport: String, input: Direction, output: Direction,
                sampleRate: Double?, availableSampleRates: [Double]?,
                isDefaultInput: Bool, isDefaultOutput: Bool, isDefaultSystem: Bool,
                isAggregate: Bool, isMultiOutput: Bool, isAlive: Bool, isRunning: Bool) {
        self.id = id
        self.uid = uid
        self.name = name
        self.manufacturer = manufacturer
        self.transport = transport
        self.input = input
        self.output = output
        self.sampleRate = sampleRate
        self.availableSampleRates = availableSampleRates
        self.isDefaultInput = isDefaultInput
        self.isDefaultOutput = isDefaultOutput
        self.isDefaultSystem = isDefaultSystem
        self.isAggregate = isAggregate
        self.isMultiOutput = isMultiOutput
        self.isAlive = isAlive
        self.isRunning = isRunning
    }

    public var ref: DeviceRef { DeviceRef(id: id, uid: uid, name: name) }
}

public struct DeviceListDTO: Codable, Equatable {
    public let devices: [DeviceInfoDTO]
    public init(devices: [DeviceInfoDTO]) { self.devices = devices }
}

public struct DefaultDeviceDTO: Codable, Equatable {
    public let role: String
    public let device: DeviceInfoDTO
    public init(role: String, device: DeviceInfoDTO) {
        self.role = role
        self.device = device
    }
}

public struct VolumeDTO: Codable, Equatable {
    public let device: DeviceRef
    public let scope: String
    public let volume: Double?
    // String keys: JSONEncoder turns Int-keyed dictionaries into flat arrays.
    public let perChannel: [String: Double]?
    public let muted: Bool?
    public init(device: DeviceRef, scope: String, volume: Double?,
                perChannel: [String: Double]?, muted: Bool?) {
        self.device = device
        self.scope = scope
        self.volume = volume
        self.perChannel = perChannel
        self.muted = muted
    }
}

public struct SampleRateDTO: Codable, Equatable {
    public let device: DeviceRef
    public let sampleRate: Double
    public let availableSampleRates: [Double]
    public init(device: DeviceRef, sampleRate: Double, availableSampleRates: [Double]) {
        self.device = device
        self.sampleRate = sampleRate
        self.availableSampleRates = availableSampleRates
    }
}

public struct SubDeviceDTO: Codable, Equatable {
    public let uid: String
    public let name: String?
    public let driftCompensation: Bool
    public init(uid: String, name: String?, driftCompensation: Bool) {
        self.uid = uid
        self.name = name
        self.driftCompensation = driftCompensation
    }
}

public struct AggregateDTO: Codable, Equatable {
    public let id: UInt32
    public let uid: String
    public let name: String
    public let isMultiOutput: Bool
    public let isPrivate: Bool
    public let clockDeviceUID: String?
    public let subDevices: [SubDeviceDTO]
    public init(id: UInt32, uid: String, name: String, isMultiOutput: Bool,
                isPrivate: Bool, clockDeviceUID: String?, subDevices: [SubDeviceDTO]) {
        self.id = id
        self.uid = uid
        self.name = name
        self.isMultiOutput = isMultiOutput
        self.isPrivate = isPrivate
        self.clockDeviceUID = clockDeviceUID
        self.subDevices = subDevices
    }
}

public struct AggregateListDTO: Codable, Equatable {
    public let aggregates: [AggregateDTO]
    public init(aggregates: [AggregateDTO]) { self.aggregates = aggregates }
}

public struct DestroyedDTO: Codable, Equatable {
    public let uid: String?
    public let existed: Bool
    public init(uid: String?, existed: Bool) {
        self.uid = uid
        self.existed = existed
    }
}
