import Foundation
import CoreBluetooth

/// Compatibility behavior for protocol decoding/encoding.
public enum G1ProtocolMode: String, CaseIterable, Sendable {
    /// Prefer official mappings, but transparently accept legacy variants.
    case auto
    /// Strictly prefer official command/event mappings.
    case official
    /// Keep legacy mappings used by earlier app revisions.
    case legacy
}

/// BLE Service and Characteristic UUIDs for Even G1 glasses (Nordic UART-style)
public enum G1BLEConstants {
    /// UART Service UUID
    public static var uartServiceUUID: CBUUID { CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E") }
    /// TX Characteristic (write to glasses)
    public static var uartTXCharacteristicUUID: CBUUID { CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") }
    /// RX Characteristic (receive notifications from glasses)
    public static var uartRXCharacteristicUUID: CBUUID { CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") }
    
    /// Device name prefixes
    public static let deviceNamePrefix = "Even G1"
    public static let leftIndicator = "_L_"
    public static let rightIndicator = "_R_"
    
    /// Timing constants
    public static let heartbeatInterval: TimeInterval = 8.0
    public static let reconnectionDelay: TimeInterval = 3.0
    public static let maxReconnectionAttempts = 5
    public static let commandTimeoutMs: Int = 500
    public static let initDelayMs: UInt64 = 100_000_000  // 100ms in nanoseconds
}

/// G1 Commands (based on official demo + MentraOS)
public enum G1Command: UInt8 {
    // Compatibility aliases
    case BRIGHTNESS_V2 = 0x01

    // Initialization
    case INIT = 0x4D
    
    // Display
    case SEND_TEXT = 0x4E
    case BMP_DATA = 0x15
    case BMP_END = 0x20
    case CRC_CHECK = 0x16
    case EXIT_ALL = 0x18
    
    // Configuration  
    case WHITELIST = 0x04
    case SILENT_MODE = 0x03
    case BRIGHTNESS = 0x0E
    // Shared command family used for head-up behavior and navigation control.
    case HEAD_UP_ANGLE = 0x0A
    case DASHBOARD_LAYOUT = 0x06
    case DASHBOARD_SHOW = 0x07
    case DISPLAY_SETTINGS = 0x26
    
    // Status
    case STATUS = 0x22
    case HEARTBEAT = 0x25
    case BATTERY = 0x2C
    case QUICK_NOTE = 0x43
    case NOTIFICATION = 0x4B
    
    // Audio
    case MIC_ON = 0x0F
    case MIC_DATA = 0xF1
    
    // Events (received from glasses)
    case DEVICE_EVENT = 0xF5
    /// Chunked JSON configuration channel (whitelist, app registry, etc.).
    case VENDOR_CONFIG = 0xF6
}

/// Compatibility command IDs observed across firmware and community implementations.
public enum G1CompatibilityCommand {
    /// Android's initial pairing/setup command, used as an unbonded fallback.
    public static let androidInit: UInt8 = 0xF4

    /// Brightness command used by official mappings.
    public static let brightnessV2: UInt8 = G1Command.BRIGHTNESS_V2.rawValue
    /// Brightness command used by legacy mappings.
    public static let brightnessLegacy: UInt8 = G1Command.BRIGHTNESS.rawValue

    /// Head-up behavior configuration.
    public static let headUpMode: UInt8 = G1Command.HEAD_UP_ANGLE.rawValue
    /// Alternate head-up behavior command seen on some firmware.
    public static let headUpModeAlt: UInt8 = 0x0B
    /// Maps the firmware action performed after a head-up motion.
    public static let headUpAction: UInt8 = 0x08
    /// Dashboard visibility command.
    public static let dashboardVisibility: UInt8 = G1Command.DASHBOARD_SHOW.rawValue

    /// Microphone control primary command byte.
    public static let microphonePrimary: UInt8 = 0x0E
    /// Microphone control fallback command byte.
    public static let microphoneFallback: UInt8 = G1Command.MIC_ON.rawValue

    /// Navigation command family primary byte (inferred).
    public static let navigationPrimary: UInt8 = G1Command.HEAD_UP_ANGLE.rawValue
}

/// G1 Device events (0xF5 payload)
public enum G1DeviceEvent: UInt8 {
    case DOUBLE_TAP = 0x00
    case SINGLE_TAP = 0x01
    /// Primary right-arm head-motion event.
    case HEAD_UP_PRIMARY = 0x02
    /// Primary right-arm return-to-level event.
    case HEAD_DOWN_PRIMARY = 0x03
    case TRIPLE_TAP = 0x04
    case TRIPLE_TAP_ALT = 0x05
    
    case CASE_BATTERY = 0x0F
    case GLASSES_BATTERY = 0x0A
    case PAIRED_SUCCESS = 0x11
    
    case PRESS_AND_HOLD = 0x17
    case PRESS_AND_RELEASE = 0x18
    /// Host-handled action emitted when double tap is mapped to Translate.
    case ACTION_DOUBLE_TAP = 0x20
    
    case HEAD_UP = 0x19
    case HEAD_DOWN = 0x1A
    case HEAD_UP_ALT = 0x1E
    case HEAD_DOWN_ALT = 0x1F
    
    case CASE_OPEN = 0x22
    case CASE_CLOSED = 0x23
    case CASE_REMOVED = 0x24
}

/// Command response codes
public enum G1Response: UInt8 {
    case ACK = 0xC9
    case NACK = 0xCA
    case CONTINUE = 0xCB
}
