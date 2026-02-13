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
