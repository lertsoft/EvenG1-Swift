import SwiftUI
import EvenG1Core
import CoreLocation

struct ContentView: View {
    @EnvironmentObject var bluetoothManager: G1BluetoothManager
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            ConnectionTab()
                .tabItem {
                    Label("Connect", systemImage: "eyeglasses")
                }
                .tag(0)

            NavigateTab(isActive: selectedTab == 1)
                .tabItem {
                    Label("Navigate", systemImage: "map")
                }
                .tag(1)
            
            DisplayTab(isActive: selectedTab == 2)
                .tabItem {
                    Label("Display", systemImage: "text.bubble")
                }
                .tag(2)
            
            LogsTab()
                .tabItem {
                    Label("Logs", systemImage: "doc.text")
                }
                .tag(3)
        }
        .tint(.cyan)
    }
}

// MARK: - Connection Tab

struct ConnectionTab: View {
    @EnvironmentObject var bluetoothManager: G1BluetoothManager
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Status Card
                StatusCard()
                    .padding()
                
                if bluetoothManager.connectionState == .fullyConnected {
                    // Connected View
                    ConnectedInfoView()
                } else {
                    // Scanning View
                    ScanningView()
                }
            }
            .navigationTitle("Even G1")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

struct StatusCard: View {
    @EnvironmentObject var bluetoothManager: G1BluetoothManager
    
    var body: some View {
        VStack(spacing: 12) {
            // Main Status
            HStack(spacing: 12) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 14, height: 14)
                    .shadow(color: statusColor.opacity(0.6), radius: 6)
                
                Text(bluetoothManager.connectionState.displayString)
                    .font(.headline)
                
                Spacer()
                
                if bluetoothManager.isScanning {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            
            // L/R Status when connected
            if let glasses = bluetoothManager.connectedGlasses {
                HStack(spacing: 20) {
                    SideBadge(label: "L", state: glasses.leftState, battery: glasses.leftBattery)
                    SideBadge(label: "R", state: glasses.rightState, battery: glasses.rightBattery)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    private var statusColor: Color {
        switch bluetoothManager.connectionState {
        case .disconnected: return .red
        case .scanning: return .orange
        case .partiallyConnected: return .yellow
        case .fullyConnected: return .green
        }
    }
}

struct SideBadge: View {
    let label: String
    let state: PeripheralState
    let battery: Int?
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.isReady ? Color.green : (state.isConnected ? Color.yellow : Color.red))
                .frame(width: 8, height: 8)
            
            Text(label)
                .font(.subheadline.bold())
            
            if let battery = battery {
                Text("\(battery)%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ScanningView: View {
    @EnvironmentObject var bluetoothManager: G1BluetoothManager
    
    var body: some View {
        VStack(spacing: 20) {
            if bluetoothManager.discoveredPairs.isEmpty && !bluetoothManager.isScanning {
                ContentUnavailableView {
                    Label("No Glasses Found", systemImage: "eyeglasses")
                } description: {
                    Text("Tap 'Scan' to find your Even G1 glasses")
                }
                .accessibilityIdentifier("connection.noGlasses")
                .frame(maxHeight: .infinity)
            } else if bluetoothManager.discoveredPairs.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Searching for glasses...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    let discoveredEntries = bluetoothManager.discoveredPairs.sorted(by: { $0.key < $1.key })
                    ForEach(discoveredEntries, id: \.key) { entry in
                        DiscoveredPairRow(pair: entry.value)
                    }
                }
                .listStyle(.insetGrouped)
            }
            
            // Scan Controls
            HStack(spacing: 16) {
                if bluetoothManager.isScanning {
                    Button {
                        bluetoothManager.stopScanning()
                    } label: {
                        Text("Stop")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                } else {
                    Button {
                        bluetoothManager.startScanning()
                    } label: {
                        Label("Scan", systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("connection.scanButton")
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    
                    Button {
                        bluetoothManager.reconnectToLastKnown()
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("connection.reconnectButton")
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding()
        }
    }
}

struct DiscoveredPairRow: View {
    @EnvironmentObject var bluetoothManager: G1BluetoothManager
    let pair: DiscoveredGlassesPair
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(pair.displayName)
                    .font(.headline)
                
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: pair.leftInfo != nil ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(pair.leftInfo != nil ? .green : .secondary)
                        Text("Left")
                            .font(.caption)
                    }
                    
                    HStack(spacing: 4) {
                        Image(systemName: pair.rightInfo != nil ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(pair.rightInfo != nil ? .green : .secondary)
                        Text("Right")
                            .font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if pair.isComplete {
                Button("Connect") {
                    bluetoothManager.connect(to: pair)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Text("Waiting...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ConnectedInfoView: View {
    @EnvironmentObject var bluetoothManager: G1BluetoothManager
    
    var body: some View {
        VStack(spacing: 24) {
            // Glasses Icon
            Image(systemName: "eyeglasses")
                .font(.system(size: 80))
                .foregroundStyle(.green)
                .padding(.top, 32)
            
            if let glasses = bluetoothManager.connectedGlasses {
                VStack(spacing: 8) {
                    Text(glasses.displayName)
                        .font(.title2.bold())
                    
                    if let battery = glasses.batteryLevel {
                        Label("\(battery)%", systemImage: batteryIcon(for: battery))
                            .font(.headline)
                            .foregroundStyle(batteryColor(for: battery))
                    }
                }
            }
            
            Spacer()
            
            // Quick Actions
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    QuickActionButton(title: "Battery", icon: "battery.100") {
                        bluetoothManager.requestBatteryStatus()
                    }
                    QuickActionButton(title: "Clear Display", icon: "xmark.circle") {
                        bluetoothManager.clearDisplay()
                    }
                }
                
                HStack(spacing: 12) {
                    QuickActionButton(title: "Silent On", icon: "speaker.slash") {
                        bluetoothManager.setSilentMode(true)
                    }
                    QuickActionButton(title: "Silent Off", icon: "speaker.wave.2") {
                        bluetoothManager.setSilentMode(false)
                    }
                }
            }
            .padding(.horizontal)
            
            Button(role: .destructive) {
                bluetoothManager.disconnect()
            } label: {
                Text("Disconnect")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding()
        }
    }
    
    private func batteryIcon(for level: Int) -> String {
        if level >= 75 { return "battery.100" }
        if level >= 50 { return "battery.75" }
        if level >= 25 { return "battery.50" }
        return "battery.25"
    }
    
    private func batteryColor(for level: Int) -> Color {
        if level >= 50 { return .green }
        if level >= 25 { return .yellow }
        return .red
    }
}

struct QuickActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Display Tab

private enum MTAStationPickerPurpose: String, Identifiable {
    case lockStation
    case stationPreference

    var id: String { rawValue }
}

struct DisplayTab: View {
    @EnvironmentObject var bluetoothManager: G1BluetoothManager
    let isActive: Bool

    @State private var textToSend = ""
    @State private var notificationTitle = "EvenG1 Swift"
    @State private var notificationMessage = "This is a test notification."
    @State private var notificationStatus = "Not sent"
    @State private var isNotificationSending = false
    @State private var brightnessValue: Double = 50
    @State private var tiltDashboardEnabled = false
    @State private var tiltHeadUpMode: G1HeadUpMode = .dashboard
    @State private var tiltAppEventFallback = true
    @State private var displayPositionEnabled = true
    @State private var displayHeight = 4
    @State private var displayDistance = 4
    @StateObject private var mtaViewModel = MTATrainViewModel()
    @StateObject private var stationPickerViewModel = MTAStationPickerViewModel()
    @StateObject private var micAudioPipeline = G1MicrophoneAudioPipeline()
    @State private var stationPickerPurpose: MTAStationPickerPurpose?
    @State private var pendingPreferenceMode: MTADirectionPreferenceMode = .both
    @State private var showPreferenceModeDialog = false
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        NavigationStack {
            Form {
                // Connection required notice
                if bluetoothManager.connectionState != .fullyConnected {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text("Connect to glasses first")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("display.connectRequiredLabel")
                        }
                    }
                }
                
                // Text Input Section
                Section {
                    TextField("Enter text to display...", text: $textToSend, axis: .vertical)
                        .lineLimit(3...6)
                        .focused($isTextFieldFocused)
                        .accessibilityIdentifier("display.textField")
                    
                    if !textToSend.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            let width = bluetoothManager.textHelper.stringWidth(textToSend)
                            let lines = bluetoothManager.textHelper.wrapText(textToSend)
                            
                            Text("Width: \(width)px / \(G1TextHelper.displayWidth)px")
                            Text("Lines: \(lines.count) / \(G1TextHelper.maxLines)")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Text Message")
                } footer: {
                    Text("Text will be word-wrapped to fit the 576×135px display")
                }
                
                Section {
                    HStack(spacing: 12) {
                        Button {
                            bluetoothManager.sendText(textToSend)
                            isTextFieldFocused = false
                        } label: {
                            Label("Send", systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .accessibilityIdentifier("display.sendButton")
                        .buttonStyle(.borderedProminent)
                        .disabled(textToSend.isEmpty || bluetoothManager.connectionState != .fullyConnected)
                        
                        Button {
                            bluetoothManager.clearDisplay()
                            textToSend = ""
                        } label: {
                            Label("Clear", systemImage: "xmark")
                        }
                        .accessibilityIdentifier("display.clearButton")
                        .buttonStyle(.bordered)
                        .disabled(bluetoothManager.connectionState != .fullyConnected)
                    }
                }
                
                // Quick Text Samples
                Section("Quick Tests") {
                    Button("Hello World") {
                        textToSend = "Hello World!"
                        bluetoothManager.sendText(textToSend)
                    }
                    
                    Button("Time Test") {
                        let formatter = DateFormatter()
                        formatter.dateFormat = "HH:mm:ss"
                        textToSend = "Time: \(formatter.string(from: Date()))"
                        bluetoothManager.sendText(textToSend)
                    }
                    
                    Button("Long Text Test") {
                        textToSend = "This is a longer text message that should wrap across multiple lines on the G1 display."
                        bluetoothManager.sendText(textToSend)
                    }
                    
                    Button("Character Test") {
                        textToSend = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
                        bluetoothManager.sendText(textToSend)
                    }
                }
                .disabled(bluetoothManager.connectionState != .fullyConnected)

                Section("Notification Transport") {
                    TextField("Title", text: $notificationTitle)
                        .focused($isTextFieldFocused)
                        .accessibilityIdentifier("display.notificationTitleField")

                    TextField("Message", text: $notificationMessage, axis: .vertical)
                        .lineLimit(2...4)
                        .focused($isTextFieldFocused)
                        .accessibilityIdentifier("display.notificationMessageField")

                    Button {
                        Task {
                            await sendTestNotification()
                        }
                    } label: {
                        if isNotificationSending {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Sending...")
                            }
                        } else {
                            Label("Configure & Send Test", systemImage: "bell.badge")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("display.notificationSendButton")
                    .disabled(
                        bluetoothManager.connectionState != .fullyConnected ||
                        notificationTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        notificationMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        isNotificationSending
                    )

                    Text(notificationStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("display.notificationStatus")

                    Text("Exercises the vendor 0x04 whitelist and 0x4B notification APIs. iOS does not allow apps to read other apps' Notification Center content, so this is an explicit app-generated test.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("MTA Next Train") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(mtaViewModel.nearestStationName)
                            .font(.headline)
                            .accessibilityIdentifier("mta.statusLabel")

                        Text(mtaViewModel.lockStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("\(mtaViewModel.visualPageIndexText) • \(mtaViewModel.bitmapDeliveryStatus)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if !mtaViewModel.upcomingTrains.isEmpty {
                            ForEach(mtaViewModel.upcomingTrains) { train in
                                HStack {
                                    Text("\(train.routeID) \(mtaDirectionDualLabel(for: train.direction))")
                                        .font(.subheadline)
                                    Spacer()
                                    Text("\(train.minutesAway)m")
                                        .font(.subheadline.bold())
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        Text(mtaViewModel.statusDetail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("mta.statusDetailLabel")

                        if let topAlertSummary = mtaViewModel.topAlertSummary {
                            Text("Alert: \(topAlertSummary)")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                                .accessibilityIdentifier("mta.alertSummaryLabel")

                            if mtaViewModel.additionalAlertCount > 0 {
                                Text("+\(mtaViewModel.additionalAlertCount) more active alerts")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("mta.alertCountLabel")
                            }
                        }

                        if mtaViewModel.alertsUnavailable {
                            Text("Service alerts are temporarily unavailable. Train arrival data is still live.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("mta.alertUnavailableLabel")
                        }

                        if let lastUpdatedAt = mtaViewModel.lastUpdatedAt {
                            Text("Updated \(lastUpdatedAt.formatted(.dateTime.hour().minute().second()))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if mtaViewModel.isRefreshing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .accessibilityIdentifier("mta.loadingIndicator")
                            Text("Refreshing...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        Task {
                            await mtaViewModel.refreshNow(trigger: .manualButton)
                        }
                    } label: {
                        Label("Refresh Nearby Train", systemImage: "train.side.front.car")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mta.refreshButton")
                    .disabled(mtaViewModel.isRefreshing)

                    Toggle(
                        "Auto Refresh (30s)",
                        isOn: Binding(
                            get: { mtaViewModel.autoRefreshEnabled },
                            set: { mtaViewModel.setAutoRefreshEnabled($0) }
                        )
                    )
                    .accessibilityIdentifier("mta.autoRefreshToggle")
                    .disabled(mtaViewModel.isRefreshing)

                    Picker(
                        "Current Station Mode",
                        selection: Binding(
                            get: { mtaViewModel.currentStationPreferenceMode },
                            set: { mode in
                                Task {
                                    await mtaViewModel.setCurrentStationPreferenceMode(mode)
                                }
                            }
                        )
                    ) {
                        ForEach(MTADirectionPreferenceMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(mtaViewModel.selectedStation == nil)

                    HStack(spacing: 10) {
                        Button("Lock Nearest") {
                            mtaViewModel.lockToNearestStation()
                        }
                        .buttonStyle(.bordered)
                        .disabled(mtaViewModel.selectedStation == nil)

                        Button("Pick Lock") {
                            stationPickerPurpose = .lockStation
                        }
                        .buttonStyle(.bordered)

                        Button("Unlock") {
                            mtaViewModel.clearManualLock()
                        }
                        .buttonStyle(.bordered)
                        .disabled(mtaViewModel.lockedStation == nil)
                    }

                    Button("Set Preference For Station") {
                        showPreferenceModeDialog = true
                    }
                    .buttonStyle(.bordered)

                    if !mtaViewModel.savedDirectionPreferences.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Saved Preferences")
                                .font(.subheadline.weight(.semibold))

                            ForEach(mtaViewModel.savedDirectionPreferences) { preference in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(preference.stationName)
                                            .font(.caption)
                                        Text("\(preference.stationID) • \(preference.mode.displayName)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(role: .destructive) {
                                        mtaViewModel.removePreference(id: preference.id)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }

                    if bluetoothManager.connectionState != .fullyConnected {
                        Text("Results still appear in-app. Connect glasses to mirror updates.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Double-tap/head-up refresh. Swipe forward/back pages. Stem wording is shown on-glasses.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Tilt Dashboard") {
                    Toggle("Enable Tilt Activation", isOn: $tiltDashboardEnabled)

                    Picker("Head-Up Mode", selection: $tiltHeadUpMode) {
                        ForEach(G1HeadUpMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .disabled(!tiltDashboardEnabled)

                    Toggle("App Event Fallback", isOn: $tiltAppEventFallback)
                        .disabled(!tiltDashboardEnabled)

                    HStack(spacing: 12) {
                        Button("Apply") {
                            Task {
                                await applyTiltDashboardConfig()
                            }
                        }
                        .buttonStyle(.bordered)

                        Button("Show") {
                            Task {
                                _ = await bluetoothManager.setDashboardVisible(true)
                            }
                        }
                        .buttonStyle(.bordered)

                        Button("Hide") {
                            Task {
                                _ = await bluetoothManager.setDashboardVisible(false)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .disabled(bluetoothManager.connectionState != .fullyConnected)

                    Text("Dashboard: \(bluetoothManager.isDashboardVisible ? "Visible" : "Hidden")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Display Position") {
                    Toggle("Enable Raster", isOn: $displayPositionEnabled)
                        .accessibilityIdentifier("display.positionEnabled")

                    Stepper("Height: \(displayHeight)", value: $displayHeight, in: 0...8)
                        .accessibilityIdentifier("display.positionHeight")
                    Stepper("Eye Distance: \(displayDistance)", value: $displayDistance, in: 0...8)
                        .accessibilityIdentifier("display.positionDistance")

                    Button("Apply Position") {
                        Task {
                            let settings = G1DisplayPositionSettings(
                                enabled: displayPositionEnabled,
                                height: displayHeight,
                                distance: displayDistance
                            )
                            _ = await bluetoothManager.setDisplayPosition(settings)
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("display.positionApply")

                    Text("Uses the vendor 0x26 raster-position command. Height and eye distance range from 0 to 8.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(bluetoothManager.connectionState != .fullyConnected)

                Section("Microphone") {
                    LabeledContent("State") {
                        Text(bluetoothManager.microphoneState.displayName)
                            .font(.subheadline.monospaced())
                    }

                    LabeledContent("Packets") {
                        Text("\(bluetoothManager.microphoneStats.packetCount)")
                            .monospacedDigit()
                    }

                    LabeledContent("Bytes") {
                        Text("\(bluetoothManager.microphoneStats.byteCount)")
                            .monospacedDigit()
                    }

                    LabeledContent("Last Seq") {
                        if let sequence = bluetoothManager.microphoneStats.lastSequence {
                            Text("\(sequence)")
                                .monospacedDigit()
                        } else {
                            Text("-")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Playback Monitor", isOn: $micAudioPipeline.isPlaybackEnabled)
                        .disabled(bluetoothManager.connectionState != .fullyConnected)

                    Picker("Decoder", selection: $micAudioPipeline.decoderMode) {
                        ForEach(G1MicrophoneAudioPipeline.DecoderMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .disabled(!micAudioPipeline.isPlaybackEnabled)

                    Stepper(
                        "Playback Rate: \(Int(micAudioPipeline.sampleRate)) Hz",
                        value: $micAudioPipeline.sampleRate,
                        in: 8_000...48_000,
                        step: 1_000
                    )
                    .disabled(!micAudioPipeline.isPlaybackEnabled || micAudioPipeline.decoderMode == .lc3_16k_20b)

                    LabeledContent("Decoded Packets") {
                        Text("\(micAudioPipeline.decodedPacketCount)")
                            .monospacedDigit()
                    }

                    LabeledContent("Played Samples") {
                        Text("\(micAudioPipeline.playedSampleCount)")
                            .monospacedDigit()
                    }

                    LabeledContent("Active LC3 Frame") {
                        if micAudioPipeline.activeLC3FrameBytes > 0 {
                            Text("\(micAudioPipeline.activeLC3FrameBytes) bytes")
                                .monospacedDigit()
                        } else {
                            Text("-")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("G1 microphone audio is decoded as vendor-specified 20-byte LC3 frames at 16 kHz. PCM modes remain available only for protocol diagnostics.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let error = micAudioPipeline.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    HStack(spacing: 12) {
                        Button("Start") {
                            Task {
                                _ = await bluetoothManager.startMicrophone()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(bluetoothManager.connectionState != .fullyConnected || isMicrophoneBusyOrStreaming)

                        Button("Stop") {
                            Task {
                                _ = await bluetoothManager.stopMicrophone()
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(bluetoothManager.connectionState != .fullyConnected || isMicrophoneIdleOrStopping)

                        Button("Reset Stats") {
                            bluetoothManager.resetMicrophoneStats()
                            micAudioPipeline.resetStats()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                
                // Brightness Control
                Section("Brightness") {
                    VStack(spacing: 12) {
                        HStack {
                            Image(systemName: "sun.min")
                                .foregroundStyle(.secondary)
                            Slider(value: $brightnessValue, in: 0...100, step: 5)
                            Image(systemName: "sun.max")
                                .foregroundStyle(.secondary)
                            Text("\(Int(brightnessValue))%")
                                .frame(width: 45, alignment: .trailing)
                                .monospacedDigit()
                        }
                        
                        HStack(spacing: 12) {
                            Button("Apply") {
                                bluetoothManager.setBrightness(Int(brightnessValue))
                            }
                            .buttonStyle(.bordered)
                            
                            Button("Auto Mode") {
                                bluetoothManager.setBrightness(Int(brightnessValue), autoMode: true)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .disabled(bluetoothManager.connectionState != .fullyConnected)
            }
            .navigationTitle("Display")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isTextFieldFocused = false
                    }
                }
            }
            .onAppear {
                mtaViewModel.bind(bluetoothManager: bluetoothManager)
                mtaViewModel.setDisplayTabActive(isActive)
                syncTiltDashboardFormState()
                syncDisplayPositionFormState()
                micAudioPipeline.bind(to: bluetoothManager)
            }
            .onDisappear {
                micAudioPipeline.unbind()
            }
            .onChange(of: isActive) { _, newValue in
                mtaViewModel.setDisplayTabActive(newValue)
            }
            .onChange(of: bluetoothManager.tiltDashboardConfig) { _, _ in
                syncTiltDashboardFormState()
            }
            .onChange(of: bluetoothManager.displayPositionSettings) { _, _ in
                syncDisplayPositionFormState()
            }
            .onChange(of: bluetoothManager.eventRevision) { _, _ in
                guard let latestEvent = bluetoothManager.events.first else {
                    return
                }

                Task {
                    await mtaViewModel.handleGlassesEvent(latestEvent)
                }
            }
            .sheet(item: $stationPickerPurpose) { purpose in
                MTAStationPickerSheet(
                    title: purpose == .lockStation ? "Pick Lock Station" : "Pick Station For Preference",
                    pickerViewModel: stationPickerViewModel,
                    userCoordinate: mtaViewModel.currentUserCoordinate(),
                    onSelect: { station in
                        switch purpose {
                        case .lockStation:
                            mtaViewModel.lockToStation(station)
                        case .stationPreference:
                            mtaViewModel.setPreferenceMode(pendingPreferenceMode, for: station)
                        }
                    }
                )
            }
            .confirmationDialog(
                "Choose Direction Preference",
                isPresented: $showPreferenceModeDialog,
                titleVisibility: .visible
            ) {
                ForEach(MTADirectionPreferenceMode.allCases) { mode in
                    Button(mode.displayName) {
                        pendingPreferenceMode = mode
                        stationPickerPurpose = .stationPreference
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Select preference mode, then pick a station.")
            }
        }
    }

    private var isMicrophoneBusyOrStreaming: Bool {
        switch bluetoothManager.microphoneState {
        case .starting, .streaming:
            return true
        case .idle, .stopping, .failed:
            return false
        }
    }

    private var isMicrophoneIdleOrStopping: Bool {
        switch bluetoothManager.microphoneState {
        case .idle, .stopping:
            return true
        case .starting, .streaming, .failed:
            return false
        }
    }

    private func syncTiltDashboardFormState() {
        guard let config = bluetoothManager.tiltDashboardConfig else {
            return
        }

        tiltDashboardEnabled = config.enabled
        tiltHeadUpMode = config.headUpMode
        tiltAppEventFallback = config.appEventFallback
    }

    private func sendTestNotification() async {
        isNotificationSending = true
        defer { isNotificationSending = false }

        let appIdentifier = Bundle.main.bundleIdentifier ?? "com.eveng1.swift"
        let app = G1NotificationApp(identifier: appIdentifier, displayName: "EvenG1 Swift")
        notificationStatus = "Configuring whitelist..."

        guard await bluetoothManager.configureNotificationWhitelist(
            G1NotificationWhitelist(apps: [app])
        ) else {
            notificationStatus = "Whitelist command was not acknowledged"
            return
        }

        notificationStatus = "Sending notification..."
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let notification = G1Notification(
            messageID: timestamp,
            appIdentifier: appIdentifier,
            title: notificationTitle,
            message: notificationMessage,
            timestampMilliseconds: timestamp,
            displayName: app.displayName
        )

        let sent = await bluetoothManager.sendNotification(notification)
        notificationStatus = sent ? "Notification acknowledged" : "Notification command was not acknowledged"
        if sent {
            isTextFieldFocused = false
        }
    }

    private func applyTiltDashboardConfig() async {
        let config = G1TiltDashboardConfig(
            enabled: tiltDashboardEnabled,
            headUpMode: tiltHeadUpMode,
            appEventFallback: tiltAppEventFallback
        )
        _ = await bluetoothManager.configureTiltDashboard(config)
    }

    private func syncDisplayPositionFormState() {
        guard let settings = bluetoothManager.displayPositionSettings else {
            return
        }
        displayPositionEnabled = settings.enabled
        displayHeight = settings.height
        displayDistance = settings.distance
    }
}

struct MTAStationPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    @ObservedObject var pickerViewModel: MTAStationPickerViewModel
    let userCoordinate: CLLocationCoordinate2D?
    let onSelect: (MTAStationSelection) -> Void

    var body: some View {
        NavigationStack {
            List {
                if pickerViewModel.isLoading {
                    ProgressView("Loading stations...")
                }

                if let errorMessage = pickerViewModel.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.orange)
                }

                if !pickerViewModel.recentStations.isEmpty {
                    Section("Recent") {
                        ForEach(filteredRecentStations) { station in
                            stationButton(station)
                        }
                    }
                }

                Section("Stations") {
                    ForEach(pickerViewModel.filteredStations) { station in
                        stationButton(station)
                    }
                }
            }
            .searchable(text: $pickerViewModel.query)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task(id: userCoordinate?.latitude ?? 0) {
                await pickerViewModel.reloadStations(userCoordinate: userCoordinate)
            }
        }
    }

    private var filteredRecentStations: [MTAStationSelection] {
        let query = pickerViewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return pickerViewModel.recentStations
        }

        return pickerViewModel.recentStations.filter { station in
            station.stationName.lowercased().contains(query) ||
            station.stationID.lowercased().contains(query)
        }
    }

    private func stationButton(_ station: MTAStationSelection) -> some View {
        Button {
            pickerViewModel.markRecent(station)
            onSelect(station)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(station.stationName)
                    .font(.body)
                Text(stationDetailText(station))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func stationDetailText(_ station: MTAStationSelection) -> String {
        if let distance = station.distanceMeters {
            return "\(Int(distance))m • \(station.stationID)"
        }
        return station.stationID
    }
}

// MARK: - Logs Tab

struct LogsTab: View {
    @EnvironmentObject var bluetoothManager: G1BluetoothManager
    @State private var showEvents = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Toggle between Logs and Events
                Picker("View", selection: $showEvents) {
                    Text("Logs (\(bluetoothManager.logs.count))").tag(false)
                    Text("Events (\(bluetoothManager.events.count))").tag(true)
                }
                .pickerStyle(.segmented)
                .padding()
                
                if showEvents {
                    EventsListView()
                } else {
                    LogsListView()
                }
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") {
                        bluetoothManager.clearLogs()
                    }
                }
            }
        }
    }
}

struct LogsListView: View {
    @EnvironmentObject var bluetoothManager: G1BluetoothManager
    
    var body: some View {
        if bluetoothManager.logs.isEmpty {
            ContentUnavailableView {
                Label("No Logs", systemImage: "doc.text")
            } description: {
                Text("Bluetooth activity will appear here")
            }
            .accessibilityIdentifier("logs.emptyState")
        } else {
            List {
                ForEach(bluetoothManager.logs.reversed()) { entry in
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
    @EnvironmentObject var bluetoothManager: G1BluetoothManager
    
    var body: some View {
        if bluetoothManager.events.isEmpty {
            ContentUnavailableView {
                Label("No Events", systemImage: "hand.tap")
            } description: {
                Text("Tap or gesture on your glasses to see events here")
            }
            .accessibilityIdentifier("events.emptyState")
        } else {
            List {
                ForEach(bluetoothManager.events.indices, id: \.self) { index in
                    Text(bluetoothManager.events[index].displayString)
                        .font(.body)
                }
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(G1BluetoothManager())
}
