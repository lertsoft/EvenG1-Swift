import Foundation

public enum G1HeadUpMode: UInt8, CaseIterable, Sendable {
    case off = 0x00
    case dashboard = 0x01
    case notes = 0x02
    case notify = 0x03

    public var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .dashboard:
            return "Dashboard"
        case .notes:
            return "Notes"
        case .notify:
            return "Notify"
        }
    }
}

public struct G1TiltDashboardConfig: Sendable, Equatable {
    public var enabled: Bool
    public var headUpMode: G1HeadUpMode
    public var appEventFallback: Bool

    public init(enabled: Bool, headUpMode: G1HeadUpMode, appEventFallback: Bool) {
        self.enabled = enabled
        self.headUpMode = headUpMode
        self.appEventFallback = appEventFallback
    }
}

/// Which app feature last uploaded a bitmap that remains latched in glasses memory.
public enum G1LatchedDisplayOwner: String, Sendable, Equatable {
    case none
    case dashboard
    case navigation
    case transit
    case notificationMirror
    case translation
    case other
}

/// Vendor-documented raster position controls. The user-facing distance is
/// zero-based (0...8); the wire protocol encodes it as 1...9.
public struct G1DisplayPositionSettings: Sendable, Equatable {
    public var enabled: Bool
    public var height: Int
    public var distance: Int

    public init(enabled: Bool, height: Int, distance: Int) {
        self.enabled = enabled
        self.height = min(8, max(0, height))
        self.distance = min(8, max(0, distance))
    }
}

public struct G1DisplaySettingsPacketBuilder {
    public init() {}

    public static func positionPacket(settings: G1DisplayPositionSettings, sequence: UInt8) -> Data {
        Data([
            G1Command.DISPLAY_SETTINGS.rawValue,
            0x08,
            0x00,
            sequence,
            0x02,
            settings.enabled ? 0x01 : 0x00,
            UInt8(settings.height),
            UInt8(settings.distance + 1)
        ])
    }
}
