import SwiftUI
import EvenG1Core

/// Three consumer tabs: the glasses themselves, getting somewhere, and what the
/// glasses show. Engineering surfaces live behind Developer Mode on the Device
/// tab rather than in this tab bar.
struct ContentView: View {
    @EnvironmentObject var bluetoothManager: G1BluetoothManager
    @EnvironmentObject var voiceCoordinator: GlassesVoiceCoordinator
    @EnvironmentObject var appActionRouter: AppActionRouter
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var developerSettings = DeveloperSettings()

    /// Owned here so transit state survives navigating between tabs.
    @StateObject private var transitViewModel = MTATrainViewModel()

    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DeviceTab()
                .trackDatadogRUMView(name: "DeviceTab")
                .tabItem {
                    Label("Device", systemImage: "eyeglasses")
                }
                .tag(0)

            NavigateTab(isActive: selectedTab == 1)
                .trackDatadogRUMView(name: "NavigateTab")
                .tabItem {
                    Label("Navigate", systemImage: "map")
                }
                .tag(1)

            AppsTab(transitViewModel: transitViewModel)
                .trackDatadogRUMView(name: "AppsTab")
                .tabItem {
                    Label("Heads-Up", systemImage: "square.stack.3d.up")
                }
                .tag(2)
        }
        .tint(.cyan)
        .environmentObject(developerSettings)
        .onAppear {
            transitViewModel.bind(bluetoothManager: bluetoothManager)
            voiceCoordinator.bind(to: bluetoothManager)
            Task { await processPendingAppAction() }
        }
        .onChange(of: selectedTab) { _, newTab in
            let tabName = ["device", "navigate", "heads_up"][safe: newTab] ?? "unknown"
            DatadogTelemetryService.shared.trackProductEvent(
                name: "tab_selected",
                attributes: ["tab.name": tabName]
            )
        }
        .onChange(of: bluetoothManager.eventRevision) { _, _ in
            guard let latestEvent = bluetoothManager.events.first else {
                return
            }

            Task {
                if case .pressAndHold = latestEvent,
                   appActionRouter.isTranslationForeground {
                    appActionRouter.requestTranslationStart()
                    return
                }
                let consumed = await voiceCoordinator.handleGlassesEvent(latestEvent)
                if !consumed {
                    await transitViewModel.handleGlassesEvent(latestEvent)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await processPendingAppAction() }
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

#Preview {
    ContentView()
        .environmentObject(G1BluetoothManager())
        .environmentObject(GlassesVoiceCoordinator())
        .environmentObject(AppActionRouter())
}
