import SwiftUI
import DatadogRUM
import EvenG1Core

struct DatadogRUMViewModifier: ViewModifier {
    let viewName: String
    let attributes: [String: Encodable]
    
    func body(content: Content) -> some View {
        content
            .onAppear {
                if DatadogTelemetryService.shared.isInitialized {
                    RUMMonitor.shared().startView(key: viewName, name: viewName, attributes: attributes)
                }
            }
            .onDisappear {
                if DatadogTelemetryService.shared.isInitialized {
                    RUMMonitor.shared().stopView(key: viewName, attributes: [:])
                }
            }
    }
}

public extension View {
    /// Track this SwiftUI View lifecycle in Datadog RUM.
    func trackDatadogRUMView(name: String, attributes: [String: Encodable] = [:]) -> some View {
        self.modifier(DatadogRUMViewModifier(viewName: name, attributes: attributes))
    }
}
