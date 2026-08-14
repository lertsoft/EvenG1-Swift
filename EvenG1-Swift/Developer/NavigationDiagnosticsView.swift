import SwiftUI
import UniformTypeIdentifiers
import EvenG1Core

/// Navigation transport trace and JSONL evidence export.
///
/// This used to be a waveform button in the Navigate top bar, where users read
/// it as a feature rather than a hardware-validation tool.
struct NavigationDiagnosticsView: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager

    @State private var exportDocument = DiagnosticsDocument(text: "")
    @State private var isExporting = false
    @State private var isConfirmingClear = false
    @State private var exportStatus: String?

    var body: some View {
        List {
            Section("Session") {
                LabeledContent("Connection", value: bluetoothManager.connectionState.displayString)
                LabeledContent("State", value: bluetoothManager.navigationSessionState.rawValue.capitalized)
                LabeledContent("Transport", value: bluetoothManager.navigationTransportMode.displayName)
                LabeledContent("Trace entries", value: "\(bluetoothManager.navigationTraceEntries.count)")
            }

            Section {
                Button {
                    exportDocument = DiagnosticsDocument(
                        text: bluetoothManager.exportNavigationTraceJSONL()
                    )
                    exportStatus = nil
                    isExporting = true
                } label: {
                    Label("Export chronological JSONL", systemImage: "square.and.arrow.up")
                }
                .disabled(bluetoothManager.navigationTraceEntries.isEmpty)
                .accessibilityIdentifier("exportNavigationTraceButton")

                Button(role: .destructive) {
                    isConfirmingClear = true
                } label: {
                    Label("Clear trace", systemImage: "trash")
                }
                .disabled(bluetoothManager.navigationTraceEntries.isEmpty)

                if let exportStatus {
                    Text(exportStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Evidence")
            } footer: {
                Text("Exports oldest-to-newest records with ISO 8601 timestamps. Attach the file to the hardware validation matrix with the glasses firmware version.")
            }

            Section("Recent records") {
                if bluetoothManager.navigationTraceEntries.isEmpty {
                    Text("Start navigation to collect native and fallback transport evidence.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(bluetoothManager.navigationTraceEntries.prefix(20)) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.direction.rawValue.uppercased())
                                    .font(.caption.weight(.semibold))
                                Text(String(format: "0x%02X", entry.command))
                                    .font(.caption.monospaced())
                                Spacer()
                                Text(entry.transportMode.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let note = entry.note, !note.isEmpty {
                                Text(note)
                                    .font(.footnote)
                            }
                            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Navigation Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Clear all navigation trace entries?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear Trace", role: .destructive) {
                bluetoothManager.clearNavigationTrace()
                exportStatus = nil
            }
            Button("Cancel", role: .cancel) {}
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .data,
            defaultFilename: DiagnosticsBundle.filename(prefix: "EvenG1-navigation-trace", extension: "jsonl")
        ) { result in
            switch result {
            case .success:
                exportStatus = "Trace exported"
            case .failure(let error):
                exportStatus = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}
