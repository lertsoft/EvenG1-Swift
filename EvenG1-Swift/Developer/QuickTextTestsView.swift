import SwiftUI
import EvenG1Core

/// QA fixtures for the text transport: wrapping, glyph coverage, and clearing.
/// These were previously the first thing a user saw on the Display tab.
struct QuickTextTestsView: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager

    private struct Fixture: Identifiable {
        let id = UUID()
        let name: String
        let text: () -> String
    }

    private let fixtures: [Fixture] = [
        Fixture(name: "Hello World", text: { "Hello World!" }),
        Fixture(name: "Timestamp", text: {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return "Time: \(formatter.string(from: Date()))"
        }),
        Fixture(name: "Multi-line wrap", text: {
            "This is a longer text message that should wrap across multiple lines on the G1 display."
        }),
        Fixture(name: "Glyph coverage", text: {
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        }),
        Fixture(name: "Line overflow", text: {
            Array(repeating: "Overflow line", count: 8).joined(separator: " ")
        })
    ]

    @State private var lastSent: String = ""

    var body: some View {
        Form {
            if bluetoothManager.connectionState != .fullyConnected {
                Section {
                    Label("Connect glasses to run fixtures", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                GlassesHUDPreview(text: lastSent, placeholder: "Run a fixture to preview it")
            } header: {
                Text("Rendered as sent")
            }

            Section("Fixtures") {
                ForEach(fixtures) { fixture in
                    Button(fixture.name) {
                        let text = fixture.text()
                        lastSent = text
                        bluetoothManager.sendText(text)
                    }
                }
            }
            .disabled(bluetoothManager.connectionState != .fullyConnected)

            Section {
                Button(role: .destructive) {
                    lastSent = ""
                    bluetoothManager.clearDisplay()
                } label: {
                    Label("Clear display", systemImage: "xmark.circle")
                }
                .disabled(bluetoothManager.connectionState != .fullyConnected)
            }
        }
        .navigationTitle("Quick Text Fixtures")
        .navigationBarTitleDisplayMode(.inline)
    }
}
