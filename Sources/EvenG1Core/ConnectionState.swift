import Foundation
import CoreBluetooth

/// Represents the side of the glasses
public enum GlassesSide: String, Sendable {
    case left = "L"
    case right = "R"
    
    /// Parse side from device name
    public static func from(name: String) -> GlassesSide? {
        let hasLeftMarker = name.range(of: G1BLEConstants.leftIndicator, options: [.caseInsensitive]) != nil
        let hasRightMarker = name.range(of: G1BLEConstants.rightIndicator, options: [.caseInsensitive]) != nil
        if hasLeftMarker, !hasRightMarker { return .left }
        if hasRightMarker, !hasLeftMarker { return .right }

        // Accept common delimiter variants such as "-L-" / "-R-" or spaced tokens.
        let leftPattern = #"(?i)(^|[_\-\s])L([_\-\s]|$)"#
        let rightPattern = #"(?i)(^|[_\-\s])R([_\-\s]|$)"#
        let hasLeftToken = name.range(of: leftPattern, options: [.regularExpression]) != nil
        let hasRightToken = name.range(of: rightPattern, options: [.regularExpression]) != nil

        if hasLeftToken, !hasRightToken { return .left }
        if hasRightToken, !hasLeftToken { return .right }
        return nil
    }
}

/// State of a single peripheral (left or right)
public enum PeripheralState: Equatable, Sendable {
    case disconnected
    case connecting
    case discoveringServices
    case discoveringCharacteristics
    case enablingNotifications
    case initializing  // Sending 0x4D 0x01
    case ready
    case error(String)
    
    public var isConnected: Bool {
        switch self {
        case .ready, .initializing, .enablingNotifications,
             .discoveringCharacteristics, .discoveringServices:
            return true
        default:
            return false
        }
    }
    
    public var isReady: Bool {
        self == .ready
    }
    
    public var displayString: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .discoveringServices: return "Discovering Services..."
        case .discoveringCharacteristics: return "Discovering Characteristics..."
        case .enablingNotifications: return "Enabling Notifications..."
        case .initializing: return "Initializing..."
        case .ready: return "Ready"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

/// Overall connection state for the glasses pair
public enum GlassesConnectionState: Equatable, Sendable {
    case disconnected
    case scanning
    case partiallyConnected  // One side connected
    case fullyConnected      // Both sides ready
    
    public var displayString: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .scanning: return "Scanning..."
        case .partiallyConnected: return "Partially Connected"
        case .fullyConnected: return "Connected"
        }
    }
}

/// Information about a single G1 peripheral
public struct G1PeripheralInfo: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let side: GlassesSide
    public let channel: String
    public var state: PeripheralState
    public var batteryLevel: Int?
    
    public init(peripheral: CBPeripheral, side: GlassesSide, channel: String) {
        self.id = peripheral.identifier
        self.name = peripheral.name ?? "Unknown"
        self.side = side
        self.channel = channel
        self.state = .disconnected
        self.batteryLevel = nil
    }
}

/// A discovered glasses pair (may be partial)
public struct DiscoveredGlassesPair: Identifiable, Sendable {
    public let id: String  // Channel ID
    public let channel: String
    public var displayName: String { "Even G1 (\(channel))" }
    
    public var leftInfo: G1PeripheralInfo?
    public var rightInfo: G1PeripheralInfo?
    
    public var isComplete: Bool {
        leftInfo != nil && rightInfo != nil
    }
    
    public var isFullyConnected: Bool {
        leftInfo?.state.isReady == true && rightInfo?.state.isReady == true
    }
    
    public init(channel: String) {
        self.id = channel
        self.channel = channel
    }
}

/// Connected glasses pair with peripheral references
public final class ConnectedGlassesPair: @unchecked Sendable {
    public let channel: String
    public var displayName: String { "Even G1 (\(channel))" }
    
    // Peripheral references (weak to avoid retain cycles)
    public weak var leftPeripheral: CBPeripheral?
    public weak var rightPeripheral: CBPeripheral?
    
    // Characteristics for writing
    public var leftTXCharacteristic: CBCharacteristic?
    public var rightTXCharacteristic: CBCharacteristic?
    
    // State tracking
    public var leftState: PeripheralState = .disconnected
    public var rightState: PeripheralState = .disconnected
    
    // Battery levels
    public var leftBattery: Int?
    public var rightBattery: Int?
    
    public var overallState: GlassesConnectionState {
        let leftReady = leftState.isReady
        let rightReady = rightState.isReady
        
        if leftReady && rightReady {
            return .fullyConnected
        } else if leftState.isConnected || rightState.isConnected {
            return .partiallyConnected
        } else {
            return .disconnected
        }
    }
    
    public var batteryLevel: Int? {
        guard let left = leftBattery, let right = rightBattery else {
            return leftBattery ?? rightBattery
        }
        return min(left, right)
    }
    
    public init(channel: String) {
        self.channel = channel
    }
    
    public func peripheral(for side: GlassesSide) -> CBPeripheral? {
        switch side {
        case .left: return leftPeripheral
        case .right: return rightPeripheral
        }
    }
    
    public func txCharacteristic(for side: GlassesSide) -> CBCharacteristic? {
        switch side {
        case .left: return leftTXCharacteristic
        case .right: return rightTXCharacteristic
        }
    }
    
    public func setState(_ state: PeripheralState, for side: GlassesSide) {
        switch side {
        case .left: leftState = state
        case .right: rightState = state
        }
    }
    
    public func state(for side: GlassesSide) -> PeripheralState {
        switch side {
        case .left: return leftState
        case .right: return rightState
        }
    }
}
