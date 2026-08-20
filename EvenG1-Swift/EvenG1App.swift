import SwiftUI
import EvenG1Core

@main
struct EvenG1App: App {
    @StateObject private var bluetoothManager = G1BluetoothManager()
    @StateObject private var voiceCoordinator = GlassesVoiceCoordinator()
    @StateObject private var appActionRouter = AppActionRouter()

    /// Owned here rather than in a tab because the notification delegate can hand
    /// off a notification before any view has appeared.
    @StateObject private var notificationMirror = NotificationMirrorViewModel()

    /// `UNUserNotificationCenter` keeps only a weak delegate reference, so this
    /// has to outlive the registration call.
    private let notificationDelegate = AppNotificationDelegate()

    init() {
        DatadogTelemetryService.shared.initialize()
        DatadogTelemetryService.shared.setUserInfo(
            id: TelemetryIdentity.anonymousInstallID(),
            extraInfo: TelemetryBuildInfo.rumViewAttributes
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bluetoothManager)
                .environmentObject(bluetoothManager.diagnostics)
                .environmentObject(bluetoothManager.glassesEvents)
                .environmentObject(notificationMirror)
                .environmentObject(voiceCoordinator)
                .environmentObject(appActionRouter)
                .preferredColorScheme(.dark)
                .task {
                    notificationDelegate.register(viewModel: notificationMirror)
                    await notificationMirror.refreshAuthorizationStatus()
                }
        }
    }
}
