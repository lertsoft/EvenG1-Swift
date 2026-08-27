import SwiftUI
import EvenG1Core

/// Home for the glasses themselves: one hardware hero with per-arm battery, the
/// controls a person changes daily rendered as instrument tiles, and links out
/// to configuration and support.
struct DeviceTab: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager

    private var isLinked: Bool {
        bluetoothManager.connectionState == .fullyConnected
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Even.Space.section) {
                    EvenScreenHeader(eyebrow: "Even Realities / Hardware", title: "My G1") {
                        EvenStatusIndicator(
                            isLive: isLinked,
                            liveLabel: "Connected",
                            idleLabel: "Offline",
                            isPending: bluetoothManager.isScanning || bluetoothManager.connectionState == .partiallyConnected
                        )
                    }

                    GlassesHeroCard()

                    if isLinked {
                        VStack(alignment: .leading, spacing: Even.Space.gap + 2) {
                            EvenSectionHeader(title: "Device Control")
                            DeviceControlSection()
                        }
                    } else {
                        ConnectCard()
                    }

                    VStack(alignment: .leading, spacing: Even.Space.gap + 2) {
                        EvenSectionHeader(title: "More")
                        DeviceLinksCard()
                    }
                }
                .padding(.horizontal, Even.Space.margin)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(Even.Palette.base.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

// MARK: - Hero

/// Single source of truth for connection state and per-arm battery. A stylized
/// hardware render stands in until the final asset lands.
private struct GlassesHeroCard: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(bluetoothManager.connectedGlasses?.displayName ?? "Even G1")
                        .font(.system(.title2, design: .default).weight(.semibold))
                        .foregroundStyle(Even.Palette.textPrimary)
                    HStack(spacing: 8) {
                        if bluetoothManager.isScanning {
                            ProgressView().controlSize(.small).tint(Even.Palette.phosphor)
                        } else {
                            Circle().fill(statusColor).frame(width: 7, height: 7)
                        }
                        Text(statusText)
                            .font(.evenSubtitle)
                            .foregroundStyle(Even.Palette.textSecondary)
                            .accessibilityIdentifier("device.statusLabel")
                    }
                }
                Spacer()
                Text("HW / 01")
                    .font(.evenMicro)
                    .tracking(1.2)
                    .foregroundStyle(Even.Palette.textTertiary)
            }

            DeviceRender()

            if let glasses = bluetoothManager.connectedGlasses {
                HStack(spacing: Even.Space.gap) {
                    ArmBatteryBar(label: "Left", state: glasses.leftState, battery: glasses.leftBattery)
                    ArmBatteryBar(label: "Right", state: glasses.rightState, battery: glasses.rightBattery)
                }
            }
        }
        .padding(Even.Space.tilePadding)
        .frame(maxWidth: .infinity)
        .evenTileSurface()
    }

    private var statusText: String {
        if bluetoothManager.isScanning { return "Looking for your glasses…" }
        return bluetoothManager.connectionState.displayString
    }

    private var statusColor: Color {
        switch bluetoothManager.connectionState {
        case .disconnected: return Even.Palette.textTertiary
        case .scanning, .partiallyConnected: return Even.Palette.caution
        case .fullyConnected: return Even.Palette.phosphor
        }
    }
}

/// Placeholder hardware render — a stylized glasses silhouette on a faint panel.
/// Swap in the final render asset without touching layout.
private struct DeviceRender: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Even.Radius.control, style: .continuous)
                .fill(Even.Palette.hud)
            EvenDotGrid(spacing: 12, dotRadius: 0.6)
            Image(systemName: "eyeglasses")
                .font(.system(size: 72, weight: .ultraLight))
                .foregroundStyle(Even.Palette.textPrimary.opacity(0.85))
                .shadow(color: Even.Palette.phosphor.opacity(0.15), radius: 12)
        }
        .frame(height: 132)
        .clipShape(RoundedRectangle(cornerRadius: Even.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Even.Radius.control, style: .continuous)
                .stroke(Even.Palette.border, lineWidth: 1)
        )
        .accessibilityHidden(true)
    }
}

private struct ArmBatteryBar: View {
    let label: String
    let state: PeripheralState
    let battery: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label.uppercased())
                    .font(.evenMicro)
                    .tracking(1.2)
                    .foregroundStyle(Even.Palette.textSecondary)
                Spacer()
                Text(battery.map { "\($0)%" } ?? (state.isReady ? "—" : state.displayString))
                    .font(.evenMicro)
                    .monospacedDigit()
                    .foregroundStyle(battery != nil ? BatteryStyle.color(for: battery ?? 0) : Even.Palette.textSecondary)
                    .lineLimit(1)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Even.Palette.surfaceActive)
                    Capsule()
                        .fill(BatteryStyle.color(for: battery ?? 0))
                        .frame(width: proxy.size.width * CGFloat(battery ?? 0) / 100)
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Even.Palette.surfaceActive.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Even.Radius.control, style: .continuous))
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
        if level >= 40 { return Even.Palette.phosphor }
        if level >= 20 { return Even.Palette.caution }
        return Even.Palette.destructive
    }
}

// MARK: - Device control

private struct DeviceControlSection: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager

    var body: some View {
        VStack(spacing: Even.Space.gap) {
            EvenToggleTile(
                title: "Silent Mode",
                systemImage: bluetoothManager.isSilentModeEnabled ? "speaker.slash" : "speaker.wave.2",
                isOn: silentModeBinding
            )
            .accessibilityIdentifier("device.silentModeToggle")

            BrightnessControl()

            HStack(spacing: Even.Space.gap) {
                EvenActionTile(title: "Clear HUD", systemImage: "xmark.square") {
                    bluetoothManager.clearDisplay()
                }
                .accessibilityIdentifier("device.clearDisplayButton")

                EvenActionTile(title: "Disconnect", systemImage: "bolt.horizontal.circle", role: .destructive) {
                    bluetoothManager.disconnect()
                }
                .accessibilityIdentifier("device.disconnectButton")
            }
        }
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
        EvenSliderTile(
            title: "Brightness",
            systemImage: "sun.max",
            valueLabel: "\(Int(level))%",
            value: $level,
            range: 0...100,
            step: 5,
            onEditingChanged: { isEditing in
                if !isEditing {
                    bluetoothManager.setBrightness(Int(level), autoMode: bluetoothManager.isAutoBrightnessEnabled)
                }
            },
            autoLabel: "Auto Level",
            autoIsOn: autoBinding
        )
        .accessibilityIdentifier("device.brightnessSlider")
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

// MARK: - Disconnected

/// One primary action gets the user connected: reconnect the remembered pair, or
/// scan when there isn't one. Discovered pairs connect by tapping the row.
private struct ConnectCard: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager

    var body: some View {
        VStack(spacing: 14) {
            if bluetoothManager.isScanning {
                EvenPrimaryButton(title: "Stop Searching", systemImage: "stop.circle", style: .secondary) {
                    bluetoothManager.stopScanning()
                }
                .accessibilityIdentifier("device.stopScanButton")
            } else {
                EvenPrimaryButton(title: primaryActionTitle, systemImage: "antenna.radiowaves.left.and.right") {
                    bluetoothManager.connectToPreferredGlasses()
                }
                .accessibilityIdentifier("device.connectButton")

                if bluetoothManager.hasRememberedGlasses {
                    EvenPrimaryButton(title: "Scan for a New Pair", systemImage: "arrow.clockwise", style: .secondary) {
                        bluetoothManager.forgetRememberedGlassesAndScan()
                    }
                    .accessibilityIdentifier("device.freshScanButton")
                }
            }

            if bluetoothManager.discoveredPairs.isEmpty {
                Text(emptyStateText)
                    .font(.evenSubtitle)
                    .foregroundStyle(Even.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("device.connectHint")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sortedDiscoveredPairs.enumerated()), id: \.element.key) { index, entry in
                        if index > 0 {
                            Divider().overlay(Even.Palette.border)
                        }
                        DiscoveredPairRow(pair: entry.value)
                    }
                }
                .background(Even.Palette.surfaceActive.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: Even.Radius.control, style: .continuous))
            }
        }
        .padding(Even.Space.tilePadding)
        .evenTileSurface()
    }

    private var sortedDiscoveredPairs: [(key: String, value: DiscoveredGlassesPair)] {
        bluetoothManager.discoveredPairs.sorted { lhs, rhs in
            lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
        }
    }

    private var primaryActionTitle: String {
        bluetoothManager.hasRememberedGlasses ? "Connect" : "Find My Glasses"
    }

    private var emptyStateText: String {
        if bluetoothManager.hasRememberedGlasses {
            return "Take your glasses out of the case and keep them nearby. They reconnect automatically when the app opens."
        }
        return "Open the charging case and keep both arms nearby to pair for the first time."
    }
}

/// Shared button treatment: phosphor-filled primary, hairline secondary.
struct EvenPrimaryButton: View {
    enum Style { case primary, secondary }

    let title: String
    var systemImage: String?
    var style: Style = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .medium))
                }
                Text(title)
                    .font(.evenTileTitle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(style == .primary ? Even.Palette.base : Even.Palette.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: Even.Radius.control, style: .continuous)
                    .fill(style == .primary ? Even.Palette.phosphor : Even.Palette.surfaceActive)
            )
        }
        .buttonStyle(.evenPressable)
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
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(pair.isComplete ? Even.Palette.phosphor : Even.Palette.textSecondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pair.displayName)
                        .font(.evenTileTitle)
                        .foregroundStyle(Even.Palette.textPrimary)
                    Text(pair.isComplete ? "Both arms found" : "Waiting for the other arm…")
                        .font(.evenSubtitle)
                        .foregroundStyle(Even.Palette.textSecondary)
                }

                Spacer()

                if pair.isComplete {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Even.Palette.textTertiary)
                } else {
                    ProgressView().controlSize(.small).tint(Even.Palette.phosphor)
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

// MARK: - Links

private struct DeviceLinksCard: View {
    @EnvironmentObject private var developerSettings: DeveloperSettings

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink {
                GlassesConfigurationView()
            } label: {
                DeviceLinkRow(title: "Glasses Configuration", subtitle: "Display position, wake on tilt", icon: "slider.horizontal.3")
            }
            .buttonStyle(.evenPressable)
            .accessibilityIdentifier("device.configurationLink")

            Divider().overlay(Even.Palette.border).padding(.leading, 52)

            NavigationLink {
                SupportView()
            } label: {
                DeviceLinkRow(title: "Support & Diagnostics", subtitle: "Export data for troubleshooting", icon: "lifepreserver")
            }
            .buttonStyle(.evenPressable)
            .accessibilityIdentifier("device.supportLink")

            if developerSettings.isDeveloperModeEnabled {
                Divider().overlay(Even.Palette.border).padding(.leading, 52)

                NavigationLink {
                    DeveloperToolsView()
                } label: {
                    DeviceLinkRow(title: "Developer Tools", subtitle: "Logs, traces, protocol tests", icon: "hammer")
                }
                .buttonStyle(.evenPressable)
                .accessibilityIdentifier("device.developerToolsLink")
            }
        }
        .evenTileSurface()
    }
}

private struct DeviceLinkRow: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .frame(width: 24)
                .foregroundStyle(Even.Palette.textPrimary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.evenTileTitle)
                    .foregroundStyle(Even.Palette.textPrimary)
                Text(subtitle)
                    .font(.evenSubtitle)
                    .foregroundStyle(Even.Palette.textSecondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Even.Palette.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}
