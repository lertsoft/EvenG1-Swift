import SwiftUI
import UniformTypeIdentifiers
import EvenG1Core

/// Consumer-facing troubleshooting: export one file for support, and the toggle
/// that reveals the engineering tools.
struct SupportView: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager
    @EnvironmentObject private var developerSettings: DeveloperSettings

    @State private var exportDocument = DiagnosticsDocument(text: "")
    @State private var isExporting = false
    @State private var exportStatus: String?

    var body: some View {
        Form {
            Section {
                Button {
                    exportDocument = DiagnosticsDocument(text: DiagnosticsBundle.text(for: bluetoothManager))
                    exportStatus = nil
                    isExporting = true
                } label: {
                    Label("Export Diagnostic Data", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("support.exportButton")

                if let exportStatus {
                    Text(exportStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("support.exportStatus")
                }
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text("Creates a single text file with connection state, recent Bluetooth activity, and glasses events. Share it with support when reporting a problem.")
            }

            Section {
                LabeledContent("App version", value: DiagnosticsBundle.appVersion)
                LabeledContent("Connection", value: bluetoothManager.connectionState.displayString)
                LabeledContent("Glasses", value: bluetoothManager.connectedGlasses?.displayName ?? "Not connected")
            } header: {
                Text("About")
            }

            Section {
                Toggle("Developer Mode", isOn: $developerSettings.isDeveloperModeEnabled)
                    .accessibilityIdentifier("support.developerModeToggle")
            } footer: {
                Text("Adds Developer Tools to this device page: raw Bluetooth logs, gesture events, microphone codec counters, navigation traces, and protocol test fixtures.")
            }
        }
        .navigationTitle("Support & Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .data,
            defaultFilename: DiagnosticsBundle.filename()
        ) { result in
            switch result {
            case .success:
                exportStatus = "Diagnostic data exported"
            case .failure(let error):
                exportStatus = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}
