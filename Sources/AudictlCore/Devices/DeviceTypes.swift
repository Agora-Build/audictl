import CoreAudio
import Foundation

public enum TransportType {
    public static func string(for raw: UInt32) -> String {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: return "builtin"
        case kAudioDeviceTransportTypePCI: return "pci"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeFireWire: return "firewire"
        case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "bluetoothLE"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeAVB: return "avb"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeAutoAggregate: return "autoaggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeContinuityCaptureWired: return "continuityCaptureWired"
        case kAudioDeviceTransportTypeContinuityCaptureWireless: return "continuityCaptureWireless"
        case kAudioDeviceTransportTypeUnknown: return "unknown"
        default:
            return HALError(status: OSStatus(bitPattern: raw), operation: "").fourCC
        }
    }
}

public enum DefaultRole: String, CaseIterable {
    case input, output, system

    public var selector: AudioObjectPropertySelector {
        switch self {
        case .input: return kAudioHardwarePropertyDefaultInputDevice
        case .output: return kAudioHardwarePropertyDefaultOutputDevice
        case .system: return kAudioHardwarePropertyDefaultSystemOutputDevice
        }
    }
}
