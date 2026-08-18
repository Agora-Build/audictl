import CoreAudio
import Foundation

/// A CoreAudio HAL call failed with a nonzero OSStatus.
public struct HALError: Error, Equatable {
    public let status: OSStatus
    public let operation: String

    public init(status: OSStatus, operation: String) {
        self.status = status
        self.operation = operation
    }

    /// OSStatus values in the HAL are FourCC codes ('!dev', 'who?', …).
    public var fourCC: String {
        let n = UInt32(bitPattern: status)
        let bytes = [n >> 24, n >> 16, n >> 8, n].map { UInt8($0 & 0xFF) }
        let printable = bytes.allSatisfy { (0x20...0x7E).contains($0) }
        guard printable else { return String(status) }
        return String(bytes: bytes, encoding: .ascii) ?? String(status)
    }

    public var message: String {
        let name: String
        switch status {
        case kAudioHardwareBadObjectError: name = "bad object"
        case kAudioHardwareBadDeviceError: name = "bad device"
        case kAudioHardwareBadStreamError: name = "bad stream"
        case kAudioHardwareUnknownPropertyError: name = "unknown property"
        case kAudioHardwareUnsupportedOperationError: name = "unsupported operation"
        case kAudioHardwareBadPropertySizeError: name = "bad property size"
        case kAudioHardwareIllegalOperationError: name = "illegal operation"
        case kAudioHardwareNotRunningError: name = "hardware not running"
        case kAudioHardwareNotReadyError: name = "hardware not ready"
        case kAudioDevicePermissionsError: name = "permission denied"
        case kAudioDeviceUnsupportedFormatError: name = "unsupported format"
        default: name = "OSStatus \(status)"
        }
        return "\(operation): \(name) ('\(fourCC)')"
    }
}
