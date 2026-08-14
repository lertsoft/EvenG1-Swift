import SwiftUI
import EvenG1Core

@main
struct EvenG1App: App {
    @StateObject private var bluetoothManager = G1BluetoothManager()

    init() {
        // Initialize Datadog RUM, Feature Flags, and Experiments
        DatadogTelemetryService.shared.initialize()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bluetoothManager)
                .preferredColorScheme(.dark)
                .trackDatadogRUMView(name: "MainAppView")
        }
    }
}
