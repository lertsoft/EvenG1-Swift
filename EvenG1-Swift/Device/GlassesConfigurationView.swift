import SwiftUI
import EvenG1Core

/// Physical fit and wake behavior: where the image sits in the lens and whether
/// looking up wakes the display. Previously buried under text tests and codec
/// counters on the Display tab.
struct GlassesConfigurationView: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager
    @EnvironmentObject private var developerSettings: DeveloperSettings

    @State private var displayPositionEnabled = true
    @State private var displayHeight = 4
    @State private var displayDistance = 4
    @State private var tiltWakeEnabled = false
    @State private var tiltHeadUpMode: G1HeadUpMode = .dashboard
    @State private var tiltAppEventFallback = true

    private var isDisconnected: Bool {
        bluetoothManager.connectionState != .fullyConnected
    }

    var body: some View {
        Form {
            if isDisconnected {
                Section {
                    Label("Connect glasses to change these settings", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("configuration.connectRequiredLabel")
                }
            }

            Section {
                BrightnessControl()
            } header: {
                Text("Brightness")
            }
            .disabled(isDisconnected)

            Section {
                Toggle("Show image in lens", isOn: $displayPositionEnabled)
                    .accessibilityIdentifier("configuration.positionEnabled")

                Stepper("Height: \(displayHeight)", value: $displayHeight, in: 0...8)
                    .accessibilityIdentifier("configuration.positionHeight")
                    .disabled(!displayPositionEnabled)

                Stepper("Eye distance: \(displayDistance)", value: $displayDistance, in: 0...8)
                    .accessibilityIdentifier("configuration.positionDistance")
                    .disabled(!displayPositionEnabled)

                Button {
                    Task {
                        let settings = G1DisplayPositionSettings(
                            enabled: displayPositionEnabled,
                            height: displayHeight,
                            distance: displayDistance
                        )
                        _ = await bluetoothManager.setDisplayPosition(settings)
                    }
                } label: {
                    Label("Apply position", systemImage: "checkmark.circle")
                }
                .accessibilityIdentifier("configuration.positionApply")
            } header: {
                Text("Display Position")
            } footer: {
                Text("Move the image up or down and set how far it sits from your eye. Both scales run 0 to 8.")
            }
            .disabled(isDisconnected)

            Section {
                Toggle("Wake on look up", isOn: $tiltWakeEnabled)
                    .accessibilityIdentifier("configuration.tiltEnabled")

                Picker("Show when awake", selection: $tiltHeadUpMode) {
                    ForEach(G1HeadUpMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .disabled(!tiltWakeEnabled)

                if developerSettings.isDeveloperModeEnabled {
                    Toggle("App-side gesture fallback", isOn: $tiltAppEventFallback)
                        .disabled(!tiltWakeEnabled)
                }

                Button {
                    Task { await applyTiltConfiguration() }
                } label: {
                    Label("Apply wake behavior", systemImage: "checkmark.circle")
                }
                .accessibilityIdentifier("configuration.tiltApply")
            } header: {
                Text("Wake Gesture")
            } footer: {
                Text(bluetoothManager.isDashboardVisible
                     ? "The dashboard is currently showing on the glasses."
                     : "Tilting your head up brings the display forward without touching your phone.")
            }
            .disabled(isDisconnected)

            Section {
                Button {
                    bluetoothManager.requestBatteryStatus()
                } label: {
                    Label("Refresh battery reading", systemImage: "battery.100.bolt")
                }
                .disabled(isDisconnected)
            }
        }
        .navigationTitle("Glasses Configuration")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            syncTiltFormState()
            syncDisplayPositionFormState()
        }
        .onChange(of: bluetoothManager.tiltDashboardConfig) { _, _ in
            syncTiltFormState()
        }
        .onChange(of: bluetoothManager.displayPositionSettings) { _, _ in
            syncDisplayPositionFormState()
        }
    }

    private func applyTiltConfiguration() async {
        let config = G1TiltDashboardConfig(
            enabled: tiltWakeEnabled,
            headUpMode: tiltHeadUpMode,
            appEventFallback: tiltAppEventFallback
        )
        _ = await bluetoothManager.configureTiltDashboard(config)
    }

    private func syncTiltFormState() {
        guard let config = bluetoothManager.tiltDashboardConfig else { return }
        tiltWakeEnabled = config.enabled
        tiltHeadUpMode = config.headUpMode
        tiltAppEventFallback = config.appEventFallback
    }

    private func syncDisplayPositionFormState() {
        guard let settings = bluetoothManager.displayPositionSettings else { return }
        displayPositionEnabled = settings.enabled
        displayHeight = settings.height
        displayDistance = settings.distance
    }
}
