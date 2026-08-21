import Foundation

public extension Notification.Name {
    /// Posted once the Datadog Feature Flags client has finished loading remote
    /// assignments for the current evaluation context. Observers should re-evaluate
    /// flags so a clean launch reflects remote values instead of the launch-time
    /// defaults returned before assignments arrived.
    static let evenG1FeatureFlagsDidBecomeReady = Notification.Name("com.eveng1.featureFlags.didBecomeReady")
}

/// Typed Datadog feature-flag and experiment keys used across the app.
///
/// Keys use dot-separated segments and avoid special characters Datadog rejects
/// in feature-flag tracking (see RUM feature-flag setup docs).
public enum EvenG1FeatureFlagKey {
    // MARK: - Tab visibility

    public static let deviceTabEnabled = "feature.device_tab.enabled"
    public static let navigateTabEnabled = "feature.navigate_tab.enabled"
    public static let headsUpTabEnabled = "feature.heads_up_tab.enabled"

    // MARK: - Heads-Up widgets

    public static let transitWidgetEnabled = "feature.transit_widget.enabled"
    public static let notificationsWidgetEnabled = "feature.notifications_widget.enabled"
    public static let translateWidgetEnabled = "feature.translate_widget.enabled"
    public static let notesWidgetEnabled = "feature.notes_widget.enabled"
    public static let dashboardWidgetEnabled = "feature.dashboard_widget.enabled"

    // MARK: - Experiments

    /// UX variant for the MTA board layout. Known values: `control`, `single_summary`.
    public static let mtaBoardLayoutExperiment = "experiment.mta_board.layout"
}
