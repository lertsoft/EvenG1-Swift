import SwiftUI
import EvenG1Core

@main
struct EvenG1App: App {
    @StateObject private var bluetoothManager = G1BluetoothManager()
    @StateObject private var voiceCoordinator = GlassesVoiceCoordinator()
    @StateObject private var appActionRouter = AppActionRouter()

    init() {
        DatadogTelemetryService.shared.initialize()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bluetoothManager)
                .environmentObject(voiceCoordinator)
                .environmentObject(appActionRouter)
                .preferredColorScheme(.dark)
        }
    }
}
