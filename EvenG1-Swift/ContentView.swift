import SwiftUI
import EvenG1Core

/// Three consumer tabs: the glasses themselves, getting somewhere, and what the
/// glasses show. Engineering surfaces live behind Developer Mode on the Device
/// tab rather than in this tab bar.
struct ContentView: View {
    @EnvironmentObject var bluetoothManager: G1BluetoothManager
    @EnvironmentObject private var glassesEvents: G1GlassesEventNotifier
    @EnvironmentObject private var notificationMirror: NotificationMirrorViewModel
    @EnvironmentObject var voiceCoordinator: GlassesVoiceCoordinator
    @EnvironmentObject var appActionRouter: AppActionRouter
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var developerSettings = DeveloperSettings()

    /// Owned here so transit state survives navigating between tabs.
    @StateObject private var transitViewModel = MTATrainViewModel()

    /// Owned here so the default dashboard can respond to head-up regardless of
    /// which tab is on screen.
    @StateObject private var dashboardViewModel = DashboardViewModel()

    @State private var selectedTab = 0
    @State private var transitCatalogSubtitle = "Next trains at your station"
    @State private var deviceTabEnabled = true
    @State private var navigateTabEnabled = true
    @State private var headsUpTabEnabled = true

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
            .onReceive(NotificationCenter.default.publisher(for: .evenG1FeatureFlagsDidBecomeReady)) { _ in
                loadFeatureFlags()
            }
            .modifier(NotificationMirrorLifecycle(
                scenePhase: scenePhase,
                navigationSessionState: bluetoothManager.navigationSessionState,
                isConnected: bluetoothManager.connectionState == .fullyConnected,
                mirror: notificationMirror
            ))
            .onChange(of: transitViewModel.selectedStation?.stationName) { _, _ in
                syncTransitCatalogSubtitle()
            }
            .onChange(of: selectedTab) { _, newTab in
                DatadogTelemetryService.shared.trackTiming(name: "tab_switch_first_frame")
                let tabName = ["device", "navigate", "heads_up"][safe: newTab] ?? "unknown"
                DatadogTelemetryService.shared.trackProductEvent(
                    name: "tab_selected",
                    attributes: ["tab.name": tabName]
                )
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await processPendingAppAction() }
            }
            .onChange(of: glassesEvents.revision) { _, _ in
                guard let latestEvent = glassesEvents.latestEvent else {
                    return
                }

                routeGlassesEvent(latestEvent)
            }
    }

    @ViewBuilder
    private var tabs: some View {
        if deviceTabEnabled || navigateTabEnabled || headsUpTabEnabled {
            enabledTabs
        } else {
            // Every top-level surface is remotely disabled. Show a maintenance
            // screen rather than an empty TabView, which would render blank.
            ContentUnavailableView(
                "Temporarily Unavailable",
                systemImage: "wrench.and.screwdriver",
                description: Text("The app is being updated. Please check back shortly.")
            )
            .accessibilityIdentifier("app.maintenanceScreen")
        }
    }

    private var enabledTabs: some View {
        TabView(selection: $selectedTab) {
            if deviceTabEnabled {
                DeviceTab()
                    .trackDatadogRUMView(name: "DeviceTab", attributes: rumViewAttributes)
                    .tabItem {
                        Label("Device", systemImage: "eyeglasses")
                    }
                    .tag(0)
            }

            if navigateTabEnabled {
                NavigateTab(isActive: selectedTab == 1)
                    .trackDatadogRUMView(name: "NavigateTab", attributes: rumViewAttributes)
                    .tabItem {
                        Label("Navigate", systemImage: "map")
                    }
                    .tag(1)
            }

            if headsUpTabEnabled {
                AppsTab(
                    transitSubtitle: transitCatalogSubtitle,
                    transitViewModel: transitViewModel,
                    dashboardViewModel: dashboardViewModel
                )
                    .trackDatadogRUMView(name: "AppsTab", attributes: rumViewAttributes)
                    .tabItem {
                        Label("Heads-Up", systemImage: "square.stack.3d.up")
                    }
                    .tag(2)
            }
        }
    }

    private func loadFeatureFlags() {
        deviceTabEnabled = FeatureFlagManager.shared.boolValue(
            forKey: EvenG1FeatureFlagKey.deviceTabEnabled,
            defaultValue: true
        )
        navigateTabEnabled = FeatureFlagManager.shared.boolValue(
            forKey: EvenG1FeatureFlagKey.navigateTabEnabled,
            defaultValue: true
        )
        headsUpTabEnabled = FeatureFlagManager.shared.boolValue(
            forKey: EvenG1FeatureFlagKey.headsUpTabEnabled,
            defaultValue: true
        )

        let enabledTabs = [
            deviceTabEnabled ? 0 : nil,
            navigateTabEnabled ? 1 : nil,
            headsUpTabEnabled ? 2 : nil
        ].compactMap { $0 }

        if !enabledTabs.contains(selectedTab), let firstEnabledTab = enabledTabs.first {
            selectedTab = firstEnabledTab
        }
    }

    private func handleAppear() {
        loadFeatureFlags()
        transitViewModel.bind(bluetoothManager: bluetoothManager)
        dashboardViewModel.bind(bluetoothManager: bluetoothManager)
        voiceCoordinator.bind(to: bluetoothManager)
        notificationMirror.bind(bluetoothManager: bluetoothManager)
        notificationMirror.setAppActive(scenePhase == .active)
        notificationMirror.setNavigationSessionState(bluetoothManager.navigationSessionState)
        notificationMirror.setConnected(bluetoothManager.connectionState == .fullyConnected)
        syncTransitCatalogSubtitle()
        Task { await processPendingAppAction() }
    }

    /// Head gestures are the only events several features want at once, so they go
    /// to a single owner. Everything else keeps its previous routing.
    private func routeGlassesEvent(_ event: G1Event) {
        // Translation owns press-and-hold while its screen is foregrounded.
        if case .pressAndHold = event, appActionRouter.isTranslationForeground {
            appActionRouter.requestTranslationStart()
            return
        }

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
            case .dashboardFallback:
                // Nobody else is drawing custom content, so the default dashboard
                // gets the head gesture (it no-ops when disabled).
                Task { await dashboardViewModel.handleGlassesEvent(event) }
                return
            case .transit:
                break
            }
        }

        Task {
            let consumed = await voiceCoordinator.handleGlassesEvent(event)
            if !consumed {
                await transitViewModel.handleGlassesEvent(event)
            }
        }
    }

    private func syncTransitCatalogSubtitle() {
        if let station = transitViewModel.selectedStation {
            transitCatalogSubtitle = station.stationName
        } else {
            transitCatalogSubtitle = "Next trains at your station"
        }
    }

    @MainActor
    private func processPendingAppAction() async {
        guard let action = PendingAppActionStore.consume() else { return }
        switch action.kind {
        case .startFavoriteNavigation:
            selectedTab = 1
            if let name = action.value {
                appActionRouter.requestFavoriteNavigation(named: name)
            }
        case .nextTrain:
            selectedTab = 2
            await transitViewModel.refreshNow(trigger: .manualButton)
        case .startTranslation:
            selectedTab = 2
            appActionRouter.requestTranslationStart()
        case .stopTranslation:
            await voiceCoordinator.stopTranslation()
        case .sendNote:
            if let note = action.value?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                bluetoothManager.sendText(note)
            }
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
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
        .environmentObject(GlassesVoiceCoordinator())
        .environmentObject(AppActionRouter())
}
