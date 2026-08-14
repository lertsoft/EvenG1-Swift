import SwiftUI
import EvenG1Core

/// Three consumer tabs: the glasses themselves, getting somewhere, and what the
/// glasses show. Engineering surfaces live behind Developer Mode on the Device
/// tab rather than in this tab bar.
struct ContentView: View {
    @EnvironmentObject var bluetoothManager: G1BluetoothManager
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
        }
        .onChange(of: bluetoothManager.eventRevision) { _, _ in
            guard let latestEvent = bluetoothManager.events.first else {
                return
            }

            Task {
                await transitViewModel.handleGlassesEvent(latestEvent)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(G1BluetoothManager())
}
