import SwiftUI
import EvenG1Core

/// Three consumer tabs: the glasses themselves, getting somewhere, and what the
/// glasses show. Engineering surfaces live behind Developer Mode on the Device
/// tab rather than in this tab bar.
struct ContentView: View {
    @EnvironmentObject var bluetoothManager: G1BluetoothManager
    @EnvironmentObject private var glassesEvents: G1GlassesEventNotifier
    @EnvironmentObject private var notificationMirror: NotificationMirrorViewModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var developerSettings = DeveloperSettings()

    /// Owned here so transit state survives navigating between tabs.
    @StateObject private var transitViewModel = MTATrainViewModel()

    @State private var selectedTab = 0
    @State private var transitCatalogSubtitle = "Next trains at your station"

    private var rumViewAttributes: [String: String] {
        var attributes = TelemetryBuildInfo.rumViewAttributes
        attributes["connection.state"] = bluetoothManager.connectionState.displayString
        return attributes
    }

    var body: some View {
        tabs
            .tint(.cyan)
            .environmentObject(developerSettings)
            .onAppear(perform: handleAppear)
            .modifier(NotificationMirrorLifecycle(
                scenePhase: scenePhase,
                navigationSessionState: bluetoothManager.navigationSessionState,
                isConnected: bluetoothManager.connectionState == .fullyConnected,
                mirror: notificationMirror
            ))
            .onChange(of: transitViewModel.selectedStation?.stationName) { _, _ in
                syncTransitCatalogSubtitle()
            }
            .onChange(of: selectedTab) { _, _ in
                DatadogTelemetryService.shared.trackTiming(name: "tab_switch_first_frame")
            }
            .onChange(of: glassesEvents.revision) { _, _ in
                guard let latestEvent = glassesEvents.latestEvent else {
                    return
                }

                routeGlassesEvent(latestEvent)
            }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            DeviceTab()
                .trackDatadogRUMView(name: "DeviceTab", attributes: rumViewAttributes)
                .tabItem {
                    Label("Device", systemImage: "eyeglasses")
                }
                .tag(0)

            NavigateTab(isActive: selectedTab == 1)
                .trackDatadogRUMView(name: "NavigateTab", attributes: rumViewAttributes)
                .tabItem {
                    Label("Navigate", systemImage: "map")
                }
                .tag(1)

            AppsTab(
                transitSubtitle: transitCatalogSubtitle,
                transitViewModel: transitViewModel
            )
                .trackDatadogRUMView(name: "AppsTab", attributes: rumViewAttributes)
                .tabItem {
                    Label("Heads-Up", systemImage: "square.stack.3d.up")
                }
                .tag(2)
        }
    }

    private func handleAppear() {
        transitViewModel.bind(bluetoothManager: bluetoothManager)
        notificationMirror.bind(bluetoothManager: bluetoothManager)
        notificationMirror.setAppActive(scenePhase == .active)
        notificationMirror.setNavigationSessionState(bluetoothManager.navigationSessionState)
        notificationMirror.setConnected(bluetoothManager.connectionState == .fullyConnected)
        syncTransitCatalogSubtitle()
    }

    /// Head gestures are the only events several features want at once, so they go
    /// to a single owner. Everything else keeps its previous routing.
    private func routeGlassesEvent(_ event: G1Event) {
        if G1LensSurfaceArbiter.isContendedGesture(event) {
            let owner = G1LensSurfaceArbiter.headGestureOwner(
                navigationSessionState: bluetoothManager.navigationSessionState,
                isNotificationMirrorEligible: notificationMirror.isEligibleForHeadGestures,
                isTransitWidgetActive: transitViewModel.isWidgetActive
            )

            switch owner {
            case .notificationMirror:
                notificationMirror.handleGlassesEvent(event)
                return
            case .navigation:
                // NavigateTab drives navigation from its own subscription.
                return
            case .transit, .dashboardFallback:
                break
            }
        }

        Task {
            await transitViewModel.handleGlassesEvent(event)
        }
    }

    private func syncTransitCatalogSubtitle() {
        if let station = transitViewModel.selectedStation {
            transitCatalogSubtitle = station.stationName
        } else {
            transitCatalogSubtitle = "Next trains at your station"
        }
    }
}

/// Keeps the mirror's view of the world current: it must stop drawing when
/// navigation takes the lens, when the app leaves the foreground (there is no
/// background BLE mode), and when the glasses go away.
private struct NotificationMirrorLifecycle: ViewModifier {
    let scenePhase: ScenePhase
    let navigationSessionState: G1NavigationSessionState
    let isConnected: Bool
    let mirror: NotificationMirrorViewModel

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                mirror.setAppActive(phase == .active)
            }
            .onChange(of: navigationSessionState) { _, state in
                mirror.setNavigationSessionState(state)
            }
            .onChange(of: isConnected) { _, connected in
                mirror.setConnected(connected)
            }
    }
}

#Preview {
    let bluetoothManager = G1BluetoothManager()
    ContentView()
        .environmentObject(bluetoothManager)
        .environmentObject(bluetoothManager.diagnostics)
        .environmentObject(bluetoothManager.glassesEvents)
        .environmentObject(NotificationMirrorViewModel())
}
