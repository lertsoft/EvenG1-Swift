/// Destination for a glasses event after dashboard swipe ownership is resolved.
public enum DashboardGestureDestination: Sendable, Equatable {
    case dashboard
    case transit
}

/// Keeps dashboard/transit event routing independent from Swift pattern syntax
/// so both swipe directions follow the same ownership decision.
public enum DashboardGestureRouting {
    public static func destination(
        for event: G1Event,
        dashboardOwnsSwipes: Bool
    ) -> DashboardGestureDestination {
        switch event {
        case .swipeForward, .swipeBackward:
            return dashboardOwnsSwipes ? .dashboard : .transit
        default:
            return .transit
        }
    }
}
