import SwiftUI
import EvenG1Core

/// Hub for everything that used to be exposed in the main tab bar: raw logs,
/// gesture events, microphone codec counters, QA text fixtures, and the
/// navigation transport trace.
struct DeveloperToolsView: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager

    var body: some View {
        List {
            Section {
                NavigationLink {
                    LogsView()
                } label: {
                    Label("Logs & Events", systemImage: "doc.text.magnifyingglass")
                }
                .accessibilityIdentifier("developer.logsLink")

                NavigationLink {
                    NavigationDiagnosticsView()
                } label: {
                    Label("Navigation Diagnostics", systemImage: "waveform.path.ecg")
                }
                .accessibilityIdentifier("developer.navigationDiagnosticsLink")

                NavigationLink {
                    MicrophoneDiagnosticsView()
                } label: {
                    Label("Microphone & Audio Codec", systemImage: "mic.badge.plus")
                }
                .accessibilityIdentifier("developer.microphoneLink")
            } header: {
                Text("Instrumentation")
            } footer: {
                Text("Live protocol state. Counters keep updating while these screens are open.")
            }

            Section("Hardware tests") {
                NavigationLink {
                    QuickTextTestsView()
                } label: {
                    Label("Quick Text Fixtures", systemImage: "textformat.abc")
                }
                .accessibilityIdentifier("developer.quickTestsLink")

                NavigationLink {
                    ProtocolReferenceView()
                } label: {
                    Label("Protocol Reference", systemImage: "number")
                }
            }

            Section {
                LabeledContent("Buffered logs", value: "\(bluetoothManager.logs.count)")
                LabeledContent("Buffered events", value: "\(bluetoothManager.events.count)")
                LabeledContent("Trace records", value: "\(bluetoothManager.navigationTraceEntries.count)")

                Button(role: .destructive) {
                    bluetoothManager.clearLogs()
                } label: {
                    Label("Clear all buffers", systemImage: "trash")
                }
                .disabled(
                    bluetoothManager.logs.isEmpty &&
                    bluetoothManager.events.isEmpty &&
                    bluetoothManager.navigationTraceEntries.isEmpty
                )
            } header: {
                Text("Buffers")
            }
        }
        .navigationTitle("Developer Tools")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The vendor byte commands that used to be printed as footnotes under consumer
/// controls. Documenting them here keeps the product screens free of hex.
struct ProtocolReferenceView: View {
    private struct Entry: Identifiable {
        let id = UUID()
        let command: String
        let name: String
        let detail: String
    }

    private let entries: [Entry] = [
        Entry(
            command: "0x04",
            name: "Notification whitelist",
            detail: "Registers the app identifiers allowed to push notifications to the glasses. Must be acknowledged before 0x4B is accepted."
        ),
        Entry(
            command: "0x4B",
            name: "Notification payload",
            detail: "Delivers a chunked JSON notification. iOS cannot read other apps' Notification Center content, so payloads are app-generated."
        ),
        Entry(
            command: "0x26",
            name: "Display position",
            detail: "Sets raster height and eye distance, each on a 0–8 scale. Sequence byte increments per command."
        ),
        Entry(
            command: "0x03",
            name: "Head-up mode",
            detail: "Configures firmware dashboard activation on tilt. Sent side-specific so one arm can fail without losing the other."
        ),
        Entry(
            command: "LC3 20B",
            name: "Microphone frames",
            detail: "Microphone audio arrives as 20-byte LC3 frames at 16 kHz. PCM decode modes exist only for protocol diagnostics."
        )
    ]

    var body: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(entry.command)
                                .font(.subheadline.monospaced().weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 5))
                            Text(entry.name)
                                .font(.subheadline.weight(.medium))
                        }
                        Text(entry.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                Text("Reverse-engineered from the Even Realities demo app. Behavior varies by firmware — validate on hardware before relying on any command.")
            }
        }
        .navigationTitle("Protocol Reference")
        .navigationBarTitleDisplayMode(.inline)
    }
}
