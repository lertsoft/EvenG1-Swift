import SwiftUI
import DatadogRUM

public extension View {
    /// Track this SwiftUI view's lifecycle as a Datadog RUM view.
    ///
    /// Delegates to the SDK's own modifier, which identifies each view instance
    /// uniquely and shares the instrumentation's view stack. A hand-rolled
    /// `startView`/`stopView` pair keyed by view name cannot do either: two views
    /// sharing a name collide, and a view whose `onDisappear` never fires (the app's
    /// root, for instance) leaves a view open for the rest of the session.
    func trackDatadogRUMView(name: String, attributes: [String: Encodable] = [:]) -> some View {
        trackRUMView(name: name, attributes: attributes)
    }
}
