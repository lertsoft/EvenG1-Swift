import Foundation

/// Represents a parsed frame from the glasses
public struct G1Frame: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let side: GlassesSide
    public let rawData: Data
    public let commandByte: UInt8
    public let payload: Data
    
    public var hexString: String {
        rawData.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    
    public var commandName: String {
        if let cmd = G1Command(rawValue: commandByte) {
            return String(describing: cmd)
        }
        return String(format: "0x%02X", commandByte)
    }
}

/// Parsed event from the glasses
public enum G1Event: Sendable {
    // Touch events
    case singleTap
    case doubleTap
    case tripleTap
    case swipeForward
    case swipeBackward
    case pressAndHold
    case pressAndRelease
    
    // Head position
    case headUp
    case headDown
    
    // Case events
    case caseOpen
    case caseClosed
    case caseRemoved
    case caseBattery(level: Int)
    
    // Connection events
    case pairedSuccess
    case initAck
    case initNack
    
    // Battery
    case batteryUpdate(side: GlassesSide, level: Int)
    
    // Unknown
    case unknown(command: UInt8, firstPayloadByte: UInt8?, payload: Data)
    
    public var displayString: String {
        switch self {
        case .singleTap: return "👆 Single Tap"
        case .doubleTap: return "👆👆 Double Tap"
        case .tripleTap: return "👆👆👆 Triple Tap"
        case .swipeForward: return "👉 Swipe Forward"
        case .swipeBackward: return "👈 Swipe Backward"
        case .pressAndHold: return "✊ Press & Hold"
        case .pressAndRelease: return "✋ Press & Release"
        case .headUp: return "🔼 Head Up"
        case .headDown: return "🔽 Head Down"
        case .caseOpen: return "📦 Case Open"
        case .caseClosed: return "📦 Case Closed"
        case .caseRemoved: return "📦 Removed from Case"
        case .caseBattery(let level): return "🔋 Case Battery: \(level)%"
        case .pairedSuccess: return "✅ Paired Successfully"
        case .initAck: return "✅ Init ACK"
        case .initNack: return "❌ Init NACK"
        case .batteryUpdate(let side, let level): return "🔋 \(side.rawValue) Battery: \(level)%"
        case .unknown(let cmd, let firstPayloadByte, let payload):
            let cmdHex = String(format: "%02X", cmd)
            let firstHex = firstPayloadByte.map { String(format: "%02X", $0) } ?? "--"
            let payloadHex = payload.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " ")
            let suffix = payload.count > 12 ? "..." : ""
            return "❓ Unknown cmd=0x\(cmdHex) p0=0x\(firstHex) payload=[\(payloadHex)\(suffix)]"
        }
    }
}

/// Parses incoming BLE data from the glasses
public final class G1FrameParser: @unchecked Sendable {
    
    /// Configuration for which frames to filter
    public struct FilterConfig: Sendable {
        public var filterAudioData: Bool = true       // Filter 0xF1 audio data
        public var filterHeartbeat: Bool = true       // Filter 0x25 heartbeat
        public var verboseLogging: Bool = false
        
        public init() {}
    }
    
    public var filterConfig = FilterConfig()
    public var protocolMode: G1ProtocolMode = .auto
    
    public init() {}
    
    /// Parse raw data into a frame
    public func parseFrame(data: Data, side: GlassesSide) -> G1Frame {
        let commandByte = data.first ?? 0x00
        let payload = data.count > 1 ? data.dropFirst() : Data()
        
        return G1Frame(
            timestamp: Date(),
            side: side,
            rawData: data,
            commandByte: commandByte,
            payload: Data(payload)
        )
    }
    
    /// Parse a frame into a higher-level event
    public func parseEvent(from frame: G1Frame) -> G1Event? {
        guard let command = G1Command(rawValue: frame.commandByte) else {
            return unknownEvent(command: frame.commandByte, payload: frame.payload)
        }
        
        switch command {
        case .INIT:
            // Init response: 0x4D [ACK/NACK]
            if frame.payload.count >= 1 {
                if frame.payload[0] == G1Response.ACK.rawValue {
                    return .initAck
                } else if frame.payload[0] == G1Response.NACK.rawValue {
                    return .initNack
                }
            }
            return nil
            
        case .STATUS:
            return parseStatusResponse(from: frame)

        case .DEVICE_EVENT:
            return parseDeviceEventPayload(frame.payload, sourceCommand: frame.commandByte)
            
        case .BATTERY:
            return parseBatteryResponse(from: frame, side: frame.side)
            
        case .MIC_DATA:
            // Audio data - typically filtered
            return nil
            
        case .BRIGHTNESS, .BRIGHTNESS_V2:
            // ACK-only configuration response; no user-facing event.
            return nil

        case .HEARTBEAT:
            // Heartbeat response - typically filtered
            return nil
            
        default:
            return nil
        }
    }
    
    /// Parse 0x22 status responses that can wrap 0xF5 device events.
    private func parseStatusResponse(from frame: G1Frame) -> G1Event? {
        let payload = frame.payload
        guard !payload.isEmpty else { return nil }

        if payload[0] == G1Command.DEVICE_EVENT.rawValue {
            return parseDeviceEventPayload(Data(payload.dropFirst()), sourceCommand: frame.commandByte)
        }

        if payload.count >= 2 && payload[1] == G1Command.DEVICE_EVENT.rawValue {
            return parseDeviceEventPayload(Data(payload.dropFirst(2)), sourceCommand: frame.commandByte)
        }

        if let index = payload.firstIndex(of: G1Command.DEVICE_EVENT.rawValue),
           index < payload.index(before: payload.endIndex) {
            let nestedStart = payload.index(after: index)
            return parseDeviceEventPayload(Data(payload[nestedStart...]), sourceCommand: frame.commandByte)
        }

        // Some firmware sends the status command with direct event code payload.
        if let event = parseDeviceEventCode(payload[0], remainingPayload: Data(payload.dropFirst())) {
            return event
        }

        return unknownEvent(command: frame.commandByte, payload: payload)
    }

    /// Parse 0xF5 device event payload bytes.
    private func parseDeviceEventPayload(_ payload: Data, sourceCommand: UInt8) -> G1Event? {
        guard !payload.isEmpty else { return nil }
        let eventCode = payload[0]
        let remainingPayload = Data(payload.dropFirst())

        if let event = parseDeviceEventCode(eventCode, remainingPayload: remainingPayload) {
            return event
        }

        return unknownEvent(command: sourceCommand, payload: payload)
    }

    private func parseDeviceEventCode(_ eventCode: UInt8, remainingPayload: Data) -> G1Event? {
        switch eventCode {
        case G1DeviceEvent.SINGLE_TAP.rawValue:
            return .singleTap
        case G1DeviceEvent.DOUBLE_TAP.rawValue:
            return .doubleTap
        case G1DeviceEvent.SWIPE_FORWARD.rawValue:
            return .swipeForward
        case G1DeviceEvent.SWIPE_BACKWARD.rawValue:
            return .swipeBackward
        case G1DeviceEvent.PRESS_AND_HOLD.rawValue:
            return .pressAndHold
        case G1DeviceEvent.PRESS_AND_RELEASE.rawValue:
            return .pressAndRelease
        case G1DeviceEvent.HEAD_UP.rawValue:
            return .headUp
        case G1DeviceEvent.HEAD_DOWN.rawValue:
            return .headDown
        case G1DeviceEvent.HEAD_UP_ALT.rawValue:
            return .headUp
        case G1DeviceEvent.HEAD_DOWN_ALT.rawValue:
            return .headDown
        case G1DeviceEvent.CASE_OPEN.rawValue:
            return .caseOpen
        case G1DeviceEvent.CASE_CLOSED.rawValue:
            return .caseClosed
        case G1DeviceEvent.CASE_REMOVED.rawValue:
            return .caseRemoved
        case G1DeviceEvent.CASE_BATTERY.rawValue:
            if let level = remainingPayload.first {
                return .caseBattery(level: Int(level))
            }
            return nil
        case G1DeviceEvent.PAIRED_SUCCESS.rawValue:
            return .pairedSuccess
        case G1DeviceEvent.TRIPLE_TAP.rawValue:
            switch protocolMode {
            case .legacy, .auto:
                return .tripleTap
            case .official:
                return nil
            }
        case G1DeviceEvent.TRIPLE_TAP_ALT.rawValue:
            switch protocolMode {
            case .official, .auto:
                return .tripleTap
            case .legacy:
                return nil
            }
        default:
            return nil
        }
    }
    
    /// Parse 0x2C battery response
    private func parseBatteryResponse(from frame: G1Frame, side: GlassesSide) -> G1Event? {
        // Response format: 2C 66 [battery%] [flags] [voltage_low] [voltage_high]
        guard frame.payload.count >= 2,
              frame.payload[0] == 0x66 else {
            return nil
        }
        
        let batteryPercent = Int(frame.payload[1])
        return .batteryUpdate(side: side, level: batteryPercent)
    }

    private func unknownEvent(command: UInt8, payload: Data) -> G1Event {
        .unknown(command: command, firstPayloadByte: payload.first, payload: payload)
    }
    
    /// Check if a frame should be filtered based on config
    public func shouldFilter(frame: G1Frame) -> Bool {
        guard let command = G1Command(rawValue: frame.commandByte) else {
            return false
        }
        
        switch command {
        case .MIC_DATA:
            return filterConfig.filterAudioData
        case .HEARTBEAT:
            return filterConfig.filterHeartbeat
        default:
            return false
        }
    }
}
