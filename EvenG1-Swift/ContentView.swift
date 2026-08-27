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
    @AppStorage(TranslationPreferences.sideButtonEnabledKey)
    private var translationSideButtonEnabled = false
    @AppStorage(TranslationPreferences.sideButtonDurationKey)
    private var translationSideButtonDurationSeconds =
        TranslationPreferences.defaultSideButtonDurationSeconds

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
    @State private var translationStartRequested = false
    @State private var translationStopInProgress = false
    @State private var requestedFirmwareDoubleTapAction: UInt8?

    private var rumViewAttributes: [String: String] {
        var attributes = TelemetryBuildInfo.rumViewAttributes
        attributes["connection.state"] = bluetoothManager.connectionState.displayString
        return attributes
    }

    var body: some View {
        tabs
            .tint(Even.Palette.phosphor)
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
            .onChange(of: bluetoothManager.connectionState) { _, state in
                if state == .fullyConnected {
                    synchronizeFirmwareDoubleTapAction()
                } else {
                    requestedFirmwareDoubleTapAction = nil
                }
            }
            .onChange(of: translationSideButtonEnabled) { _, _ in
                synchronizeFirmwareDoubleTapAction()
            }
            .onChange(of: voiceCoordinator.translationStopRevision) { _, _ in
                translationStartRequested = false
            }
            .onChange(of: voiceCoordinator.mode) { _, mode in
                if case .failed = mode {
                    translationStartRequested = false
                }
            }
            .onChange(of: appActionRouter.translationStartCompletionRevision) { _, _ in
                translationStartRequested = false
            }
            .onChange(of: glassesEvents.revision) { _, _ in
                guard let latestEvent = glassesEvents.latestEvent else {
                    return
                }

                routeGlassesEvent(latestEvent)
            }
            .onChange(of: appActionRouter.translationStartRevision) { _, revision in
                guard revision > 0 else { return }
                guard headsUpTabEnabled else {
                    appActionRouter.completeTranslationStartRequest(revision: revision)
                    return
                }
                selectedTab = 2
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
                    .toolbar(.hidden, for: .tabBar)
                    .tag(0)
            }

            if navigateTabEnabled {
                NavigateTab(isActive: selectedTab == 1)
                    .trackDatadogRUMView(name: "NavigateTab", attributes: rumViewAttributes)
                    .toolbar(.hidden, for: .tabBar)
                    .tag(1)
            }

            if headsUpTabEnabled {
                AppsTab(
                    transitSubtitle: transitCatalogSubtitle,
                    transitViewModel: transitViewModel,
                    dashboardViewModel: dashboardViewModel
                )
                    .trackDatadogRUMView(name: "AppsTab", attributes: rumViewAttributes)
                    .toolbar(.hidden, for: .tabBar)
                    .tag(2)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            EvenTabBar(items: tabItems, selection: $selectedTab)
        }
    }

    private var tabItems: [EvenTabItem] {
        var items: [EvenTabItem] = []
        if deviceTabEnabled {
            items.append(EvenTabItem(tag: 0, title: "Device", systemImage: "eyeglasses"))
        }
        if navigateTabEnabled {
            items.append(EvenTabItem(tag: 1, title: "Navigate", systemImage: "map"))
        }
        if headsUpTabEnabled {
            items.append(EvenTabItem(tag: 2, title: "Heads-Up", systemImage: "square.stack.3d.up"))
        }
        return items
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
        synchronizeFirmwareDoubleTapAction()
        Task { await processPendingAppAction() }
    }

    /// Head gestures are the only events several features want at once, so they go
    /// to a single owner. Everything else keeps its previous routing.
    private func routeGlassesEvent(_ event: G1Event) {
        if translationSideButtonEnabled {
            switch event {
            case .actionDoubleTap:
                if voiceCoordinator.isTranslationActive {
                    stopTranslationFromGlasses()
                } else {
                    guard !translationStartRequested,
                          !translationStopInProgress else { return }
                    translationStartRequested = true
                    startTranslationFromGlasses()
                }
                return
            case .doubleTap:
                guard voiceCoordinator.isTranslationActive || translationStopInProgress else {
                    break
                }
                stopTranslationFromGlasses()
                return
            default:
                break
            }
        }

        if G1LensSurfaceArbiter.isContendedGesture(event) {
            // Live captions keep ownership of the single lens surface. Head-up
            // reasserts the latest caption after a firmware display timeout.
            if voiceCoordinator.handleTranslationDisplayEvent(event) {
                return
            }

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
            if consumed { return }

            let dashboardOwnsSwipes = dashboardViewModel.shouldHandleSwipePaging(
                navigationSessionState: bluetoothManager.navigationSessionState,
                isNotificationMirrorEligible: notificationMirror.isEligibleForHeadGestures,
                isTransitWidgetActive: transitViewModel.isWidgetActive
            )
            switch DashboardGestureRouting.destination(
                for: event,
                dashboardOwnsSwipes: dashboardOwnsSwipes
            ) {
            case .dashboard:
                await dashboardViewModel.handleGlassesEvent(event)
            case .transit:
                await transitViewModel.handleGlassesEvent(event)
            }
        }
    }

    private func startTranslationFromGlasses() {
        let autoStopSeconds = translationSideButtonDurationSeconds > 0
            ? translationSideButtonDurationSeconds
            : nil
        Task { @MainActor in
            _ = await bluetoothManager.clearDisplayAndWait()
            guard translationSideButtonEnabled else {
                translationStartRequested = false
                return
            }
            appActionRouter.requestTranslationStart(
                autoStopAfterSeconds: autoStopSeconds,
                fromSideButton: true
            )
        }
    }

    private func stopTranslationFromGlasses() {
        guard !translationStopInProgress else { return }
        translationStopInProgress = true
        translationStartRequested = false
        Task { @MainActor in
            await voiceCoordinator.stopTranslation()
            translationStopInProgress = false
        }
    }

    private func synchronizeFirmwareDoubleTapAction() {
        guard bluetoothManager.connectionState == .fullyConnected else {
            requestedFirmwareDoubleTapAction = nil
            return
        }
        let action: UInt8 = translationSideButtonEnabled ? 0x02 : 0x00
        guard requestedFirmwareDoubleTapAction != action else {
            return
        }
        requestedFirmwareDoubleTapAction = action
        Task { @MainActor in
            for attempt in 0..<3 {
                guard bluetoothManager.connectionState == .fullyConnected,
                      (translationSideButtonEnabled ? UInt8(0x02) : UInt8(0x00)) == action else {
                    return
                }

                if await bluetoothManager.setFirmwareDoubleTapAction(action) {
                    return
                }

                if attempt < 2 {
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }

            if requestedFirmwareDoubleTapAction == action {
                requestedFirmwareDoubleTapAction = nil
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
