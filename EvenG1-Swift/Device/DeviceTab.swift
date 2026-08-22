import SwiftUI
import EvenG1Core

/// Home for the glasses themselves: one connection hero, the two settings a
/// person changes daily, and links out to configuration and support.
struct DeviceTab: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    GlassesHeroCard()

                    if bluetoothManager.connectionState == .fullyConnected {
                        QuickSettingsCard()
                    } else {
                        ConnectCard()
                    }

                    DeviceLinksCard()
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Even G1")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

// MARK: - Hero

/// Single source of truth for connection state and per-arm battery. Replaces the
/// old status card plus separate battery graphic, which reported the same
/// numbers twice.
private struct GlassesHeroCard: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "eyeglasses")
                .font(.system(size: 62, weight: .light))
                .foregroundStyle(accentColor)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(bluetoothManager.connectedGlasses?.displayName ?? "Even G1")
                    .font(.title3.bold())

                HStack(spacing: 8) {
                    if bluetoothManager.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Circle()
                            .fill(accentColor)
                            .frame(width: 8, height: 8)
                    }

                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("device.statusLabel")
                }
            }

            if let glasses = bluetoothManager.connectedGlasses {
                HStack(spacing: 12) {
                    ArmBatteryView(label: "Left", state: glasses.leftState, battery: glasses.leftBattery)
                    ArmBatteryView(label: "Right", state: glasses.rightState, battery: glasses.rightBattery)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var statusText: String {
        if bluetoothManager.isScanning {
            return "Looking for your glasses…"
        }
        return bluetoothManager.connectionState.displayString
    }

    private var accentColor: Color {
        switch bluetoothManager.connectionState {
        case .disconnected: return .secondary
        case .scanning: return .orange
        case .partiallyConnected: return .yellow
        case .fullyConnected: return .green
        }
    }
}

private struct ArmBatteryView: View {
    let label: String
    let state: PeripheralState
    let battery: Int?

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if let battery {
                Label("\(battery)%", systemImage: BatteryStyle.icon(for: battery))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BatteryStyle.color(for: battery))
                    .monospacedDigit()
            } else {
                Label(state.isReady ? "—" : state.displayString, systemImage: "battery.0percent")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

enum BatteryStyle {
    static func icon(for level: Int) -> String {
        if level >= 75 { return "battery.100" }
        if level >= 50 { return "battery.75" }
        if level >= 25 { return "battery.50" }
        return "battery.25"
    }

    static func color(for level: Int) -> Color {
        if level >= 50 { return .green }
        if level >= 25 { return .yellow }
        return .red
    }
}

// MARK: - Disconnected

/// One primary action gets the user connected: reconnect the remembered pair, or
/// scan when there isn't one. Discovered pairs connect by tapping the row.
private struct ConnectCard: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager

    var body: some View {
        VStack(spacing: 14) {
            if bluetoothManager.isScanning {
                Button {
                    bluetoothManager.stopScanning()
                } label: {
                    Text("Stop searching")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("device.stopScanButton")
            } else {
                Button {
                    bluetoothManager.connectToPreferredGlasses()
                } label: {
                    Label(primaryActionTitle, systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("device.connectButton")

                if bluetoothManager.hasRememberedGlasses {
                    Button {
                        bluetoothManager.forgetRememberedGlassesAndScan()
                    } label: {
                        Label("Scan for a new pair", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("device.freshScanButton")
                }
            }

            if bluetoothManager.discoveredPairs.isEmpty {
                Text(emptyStateText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("device.connectHint")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sortedDiscoveredPairs.enumerated()), id: \.element.key) { index, entry in
                        if index > 0 {
                            Divider()
                        }
                        DiscoveredPairRow(pair: entry.value)
                    }
                }
                .background(Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var sortedDiscoveredPairs: [(key: String, value: DiscoveredGlassesPair)] {
        bluetoothManager.discoveredPairs.sorted { lhs, rhs in
            lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
        }
    }

    private var primaryActionTitle: String {
        bluetoothManager.hasRememberedGlasses ? "Connect" : "Find my glasses"
    }

    private var emptyStateText: String {
        if bluetoothManager.hasRememberedGlasses {
            return "Take your glasses out of the case and keep them nearby. They reconnect automatically when the app opens."
        }
        return "Open the charging case and keep both arms nearby to pair for the first time."
    }
}

private struct DiscoveredPairRow: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager
    let pair: DiscoveredGlassesPair

    var body: some View {
        Button {
            bluetoothManager.connect(to: pair)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "eyeglasses")
                    .font(.title3)
                    .foregroundStyle(pair.isComplete ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pair.displayName)
                        .font(.subheadline.weight(.medium))
                    Text(pair.isComplete ? "Both arms found" : "Waiting for the other arm…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if pair.isComplete {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!pair.isComplete)
    }
}

// MARK: - Connected

/// The two controls worth reaching for without leaving the dashboard.
private struct QuickSettingsCard: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager

    var body: some View {
        VStack(spacing: 0) {
            Toggle(isOn: silentModeBinding) {
                Label("Silent mode", systemImage: bluetoothManager.isSilentModeEnabled ? "speaker.slash" : "speaker.wave.2")
            }
            .accessibilityIdentifier("device.silentModeToggle")
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().padding(.leading, 16)

            BrightnessControl()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider().padding(.leading, 16)

            Button {
                bluetoothManager.clearDisplay()
            } label: {
                HStack {
                    Label("Clear display", systemImage: "xmark.circle")
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("device.clearDisplayButton")

            Divider().padding(.leading, 16)

            Button(role: .destructive) {
                bluetoothManager.disconnect()
            } label: {
                HStack {
                    Label("Disconnect", systemImage: "xmark.circle.fill")
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("device.disconnectButton")
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var silentModeBinding: Binding<Bool> {
        Binding(
            get: { bluetoothManager.isSilentModeEnabled },
            set: { bluetoothManager.setSilentMode($0) }
        )
    }
}

/// Brightness commits on release so a drag does not flood the BLE queue.
struct BrightnessControl: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager
    @State private var level: Double = 50
    @State private var hasLoadedInitialValue = false

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Brightness", systemImage: "sun.max")
                Spacer()
                Text("\(Int(level))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Slider(value: $level, in: 0...100, step: 5) { isEditing in
                if !isEditing {
                    bluetoothManager.setBrightness(Int(level), autoMode: bluetoothManager.isAutoBrightnessEnabled)
                }
            }
            .accessibilityIdentifier("device.brightnessSlider")

            Toggle(isOn: autoBinding) {
                Text("Adjust automatically")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("device.autoBrightnessToggle")
        }
        .onAppear {
            guard !hasLoadedInitialValue else { return }
            hasLoadedInitialValue = true
            level = Double(bluetoothManager.brightnessLevel)
        }
    }

    private var autoBinding: Binding<Bool> {
        Binding(
            get: { bluetoothManager.isAutoBrightnessEnabled },
            set: { bluetoothManager.setBrightness(Int(level), autoMode: $0) }
        )
    }
}

// MARK: - Links

private struct DeviceLinksCard: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager
    @EnvironmentObject private var developerSettings: DeveloperSettings

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink {
                GlassesConfigurationView()
            } label: {
                DeviceLinkRow(title: "Glasses Configuration", subtitle: "Display position, wake on tilt", icon: "slider.horizontal.3")
            }
            .accessibilityIdentifier("device.configurationLink")

            Divider().padding(.leading, 56)

            NavigationLink {
                SupportView()
            } label: {
                DeviceLinkRow(title: "Support & Diagnostics", subtitle: "Export data for troubleshooting", icon: "lifepreserver")
            }
            .accessibilityIdentifier("device.supportLink")

            if developerSettings.isDeveloperModeEnabled {
                Divider().padding(.leading, 56)

                NavigationLink {
                    DeveloperToolsView()
                } label: {
                    DeviceLinkRow(title: "Developer Tools", subtitle: "Logs, traces, protocol tests", icon: "hammer")
                }
                .accessibilityIdentifier("device.developerToolsLink")
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

private struct DeviceLinkRow: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.body)
                .frame(width: 28, height: 28)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

#Preview {
    let bluetoothManager = G1BluetoothManager()
    DeviceTab()
        .environmentObject(bluetoothManager)
        .environmentObject(bluetoothManager.diagnostics)
        .environmentObject(bluetoothManager.glassesEvents)
        .environmentObject(DeveloperSettings())
}
