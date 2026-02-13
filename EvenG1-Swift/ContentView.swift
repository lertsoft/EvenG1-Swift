import SwiftUI
import EvenG1Core

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
            
            DisplayTab(isActive: selectedTab == 1)
                .tabItem {
                    Label("Display", systemImage: "text.bubble")
                }
                .tag(1)
            
            LogsTab()
                .tabItem {
                    Label("Logs", systemImage: "doc.text")
                }
                .tag(2)
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

struct DisplayTab: View {
    @EnvironmentObject var bluetoothManager: G1BluetoothManager
    let isActive: Bool

    @State private var textToSend = ""
    @State private var brightnessValue: Double = 50
    @State private var tiltDashboardEnabled = false
    @State private var tiltHeadUpMode: G1HeadUpMode = .dashboard
    @State private var tiltAppEventFallback = true
    @StateObject private var mtaViewModel = MTATrainViewModel()
    @StateObject private var micAudioPipeline = G1MicrophoneAudioPipeline()
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

                Section("MTA Next Train") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(mtaViewModel.statusTitle)
                            .font(.headline)
                            .accessibilityIdentifier("mta.statusLabel")

                        Text(mtaViewModel.statusDetail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

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

                    if bluetoothManager.connectionState != .fullyConnected {
                        Text("Results still appear in-app. Connect glasses to mirror updates.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Double-tap or head-up gesture refreshes instantly.")
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

                    Toggle("Auto LC3 Frame Size", isOn: $micAudioPipeline.lc3AutoFrameSize)
                        .disabled(!micAudioPipeline.isPlaybackEnabled || micAudioPipeline.decoderMode != .lc3_16k_20b)

                    Picker("LC3 Frame Size", selection: $micAudioPipeline.lc3FrameSize) {
                        ForEach(G1MicrophoneAudioPipeline.LC3FrameSize.allCases) { frameSize in
                            Text(frameSize.displayName).tag(frameSize)
                        }
                    }
                    .disabled(
                        !micAudioPipeline.isPlaybackEnabled ||
                        micAudioPipeline.decoderMode != .lc3_16k_20b ||
                        micAudioPipeline.lc3AutoFrameSize
                    )

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
                        Text("\(micAudioPipeline.activeLC3FrameBytes) bytes")
                            .monospacedDigit()
                    }

                    Text("Use LC3 mode for glasses microphone playback. PCM modes are for protocol experimentation.")
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
            .onChange(of: bluetoothManager.events.count) { oldValue, newValue in
                guard newValue > oldValue, let latestEvent = bluetoothManager.events.first else {
                    return
                }

                Task {
                    await mtaViewModel.handleGlassesEvent(latestEvent)
                }
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

    private func applyTiltDashboardConfig() async {
        let config = G1TiltDashboardConfig(
            enabled: tiltDashboardEnabled,
            headUpMode: tiltHeadUpMode,
            appEventFallback: tiltAppEventFallback
        )
        _ = await bluetoothManager.configureTiltDashboard(config)
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
