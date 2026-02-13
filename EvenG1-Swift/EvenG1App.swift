import SwiftUI
import EvenG1Core

@main
struct EvenG1App: App {
    @StateObject private var bluetoothManager = G1BluetoothManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bluetoothManager)
                .preferredColorScheme(.dark)
        }
    }
}
