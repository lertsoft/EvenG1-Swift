import Foundation

/// Which feature a head gesture belongs to.
public enum G1LensSurfaceOwner: String, Sendable, Equatable {
    case navigation
    case notificationMirror
    case transit
    /// Nobody is drawing custom content, so the stock dashboard fallback keeps
    /// its existing behavior.
    case dashboardFallback
}

/// Decides who handles a head gesture.
///
/// The glasses expose a single display surface, and head-up/head-down is the only
/// gesture more than one feature wants. Without an explicit order, a head-down
/// meant to dismiss a notification also reaches transit, which clears the lens.
public enum G1LensSurfaceArbiter {
    public static func headGestureOwner(navigationSessionState: G1NavigationSessionState,
                                       isNotificationMirrorEligible: Bool,
                                       isTransitWidgetActive: Bool) -> G1LensSurfaceOwner {
        // A trip in progress outranks everything: the route map is the reason the
        // wearer is looking at the glasses at all.
        guard navigationSessionState == .inactive else {
            return .navigation
        }
        // The mirror only claims gestures when it has something to reveal or is
        // already showing something, so an idle mirror costs transit nothing.
        if isNotificationMirrorEligible {
            return .notificationMirror
        }
        if isTransitWidgetActive {
            return .transit
        }
        return .dashboardFallback
    }

    /// Whether the event is one that more than one feature competes for.
    public static func isContendedGesture(_ event: G1Event) -> Bool {
        switch event {
        case .headUp, .headDown:
            return true
        default:
            return false
        }
    }
}
