import SwiftUI
import EvenG1Core

/// Raw UART log and gesture-event inspector. Reachable only from Developer Tools.
struct LogsView: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager
    @EnvironmentObject private var diagnostics: G1DiagnosticsStore
    @State private var showEvents = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $showEvents) {
                Text("Logs (\(diagnostics.logs.count))").tag(false)
                Text("Events (\(diagnostics.events.count))").tag(true)
            }
            .pickerStyle(.segmented)
            .padding()

            if showEvents {
                EventsListView()
            } else {
                LogsListView()
            }
        }
        .navigationTitle("Logs & Events")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") {
                    bluetoothManager.clearLogs()
                }
            }
        }
    }
}

struct LogsListView: View {
    @EnvironmentObject private var diagnostics: G1DiagnosticsStore

    var body: some View {
        if diagnostics.logs.isEmpty {
            ContentUnavailableView {
                Label("No Logs", systemImage: "doc.text")
            } description: {
                Text("Bluetooth activity will appear here")
            }
            .accessibilityIdentifier("logs.emptyState")
        } else {
            List {
                ForEach(diagnostics.logs.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.level.rawValue)
                            Text(entry.formattedTime)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }

                        Text(entry.message)
                            .font(.footnote)
                            .foregroundStyle(colorForLevel(entry.level))
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.plain)
        }
    }

    private func colorForLevel(_ level: G1BluetoothManager.LogEntry.LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }
}

struct EventsListView: View {
    @EnvironmentObject private var diagnostics: G1DiagnosticsStore

    var body: some View {
        if diagnostics.events.isEmpty {
            ContentUnavailableView {
                Label("No Events", systemImage: "hand.tap")
            } description: {
                Text("Tap or gesture on your glasses to see events here")
            }
            .accessibilityIdentifier("events.emptyState")
        } else {
            List {
                ForEach(diagnostics.events.indices, id: \.self) { index in
                    Text(diagnostics.events[index].displayString)
                        .font(.body)
                }
            }
            .listStyle(.plain)
        }
    }
}
