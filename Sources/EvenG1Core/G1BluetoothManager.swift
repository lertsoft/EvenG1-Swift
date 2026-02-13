import Foundation
import CoreBluetooth
import Combine
import os.log

/// Logger for G1 Bluetooth operations
private let logger = Logger(subsystem: "com.eveng1", category: "Bluetooth")

/// Main Bluetooth manager for Even G1 glasses
/// Inspired by MentraOS patterns with dedicated queues, reconnection, and persistence
@MainActor
public final class G1BluetoothManager: NSObject, ObservableObject {
    
    // MARK: - Published State
    
    /// Current connection state
    @Published public private(set) var connectionState: GlassesConnectionState = .disconnected
    
    /// Discovered glasses pairs (may be partial)
    @Published public private(set) var discoveredPairs: [String: DiscoveredGlassesPair] = [:]
    
    /// Currently connected glasses (nil if not connected)
    @Published public private(set) var connectedGlasses: ConnectedGlassesPair?
    
    /// Log entries for debugging
    @Published public private(set) var logs: [LogEntry] = []
    
    /// Parsed events from glasses
    @Published public private(set) var events: [G1Event] = []
    
    /// Latest frames (for raw data view)
    @Published public private(set) var recentFrames: [G1Frame] = []
    
    /// Is currently scanning
    @Published public private(set) var isScanning: Bool = false

    /// Tilt dashboard behavior configuration.
    @Published public private(set) var tiltDashboardConfig: G1TiltDashboardConfig?

    /// Whether the glasses dashboard is currently shown (tracked app-side).
    @Published public private(set) var isDashboardVisible: Bool = false

    /// Glasses microphone capture state.
    @Published public private(set) var microphoneState: G1MicrophoneState = .idle

    /// Aggregate metrics for microphone packets received from glasses.
    @Published public private(set) var microphoneStats: G1MicrophoneStats = .init(
        startedAt: nil,
        packetCount: 0,
        byteCount: 0,
        lastSequence: nil
    )

    /// Callback stream for raw microphone packet payloads.
    public let microphonePackets = PassthroughSubject<G1MicrophonePacket, Never>()
    
    // MARK: - Configuration
    
    /// Enable automatic reconnection on disconnect
    public var autoReconnect: Bool = true

    /// Protocol compatibility mode for command IDs and event parsing.
    public var protocolMode: G1ProtocolMode = .auto {
        didSet {
            frameParser.protocolMode = protocolMode
            heartbeatMode = initialHeartbeatMode()
        }
    }

    /// Enables verbose per-device discovery rejection logs.
    public var verboseDiscoveryLogging: Bool = false
    
    /// Frame parser configuration
    public let frameParser = G1FrameParser()
    
    /// Text helper for font metrics and text commands
    public let textHelper = G1TextHelper()
    
    // MARK: - Private Properties
    
    /// Dedicated BLE queue (MentraOS pattern)
    private let bleQueue = DispatchQueue(label: "com.eveng1.bluetooth", qos: .userInitiated)
    
    /// Central manager
    private var centralManager: CBCentralManager!
    
    /// Peripheral references by UUID
    private var peripheralsByUUID: [UUID: CBPeripheral] = [:]
    
    /// Heartbeat timer
    private var heartbeatTimer: Timer?
    private var heartbeatCounter: UInt8 = 0
    private var missedHeartbeatAcks: Int = 0
    
    /// Heartbeat packet compatibility mode
    private enum HeartbeatMode {
        case short
        case extended
    }
    private var heartbeatMode: HeartbeatMode = .extended
    
    /// Pending ACK tracking
    private struct AckKey: Hashable {
        let side: GlassesSide
        let command: UInt8
        let sequence: UInt8?
    }
    
    private struct PendingAck {
        let timeoutTask: Task<Void, Never>
        let continuation: CheckedContinuation<Bool, Never>
    }
    
    private var pendingAcks: [AckKey: PendingAck] = [:]
    
    /// Reconnection state
    private var reconnectionAttempts: Int = 0
    private var reconnectionTimer: DispatchSourceTimer?
    private var isIntentionalDisconnect: Bool = false

    /// Dashboard fallback debounce for event-driven show/hide.
    private var lastDashboardFallbackActionAt: Date?
    nonisolated private static let dashboardFallbackDebounceSeconds: TimeInterval = 0.3

    /// Side currently handling microphone control.
    private var activeMicrophoneSide: GlassesSide?
    
    /// Persistence keys
    private static let lastLeftUUIDKey = "G1_LastLeftPeripheralUUID"
    private static let lastRightUUIDKey = "G1_LastRightPeripheralUUID"
    private static let lastChannelKey = "G1_LastChannel"
    
    // MARK: - Log Entry
    
    public struct LogEntry: Identifiable, Sendable {
        public let id = UUID()
        public let timestamp: Date
        public let message: String
        public let level: LogLevel
        
        public enum LogLevel: String, Sendable {
            case debug = "🔍"
            case info = "ℹ️"
            case warning = "⚠️"
            case error = "❌"
            case success = "✅"
        }
        
        public var formattedTime: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            return formatter.string(from: timestamp)
        }
    }
    
    // MARK: - Initialization
    
    public override init() {
        super.init()
        frameParser.protocolMode = protocolMode
        heartbeatMode = initialHeartbeatMode()
        // Initialize central manager on BLE queue
        centralManager = CBCentralManager(delegate: self, queue: bleQueue, options: [
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
    }
    
    deinit {
        heartbeatTimer?.invalidate()
        reconnectionTimer?.cancel()
    }
    
    // MARK: - Public API
    
    /// Start scanning for Even G1 glasses
    public func startScanning() {
        guard centralManager.state == .poweredOn else {
            log("Cannot scan: Bluetooth not powered on", level: .warning)
            return
        }
        
        isScanning = true
        connectionState = .scanning
        discoveredPairs.removeAll()
        
        log("Starting scan for Even G1 glasses...", level: .info)

        // Seed scan results from any peripherals already connected to the UART service.
        // This improves recoverability when devices were previously paired and reconnect quickly.
        let connectedPeripherals = centralManager.retrieveConnectedPeripherals(withServices: [G1BLEConstants.uartServiceUUID])
        if !connectedPeripherals.isEmpty {
            log("Seeding discovery with \(connectedPeripherals.count) connected UART peripheral(s)", level: .debug)
        }
        for peripheral in connectedPeripherals {
            let evaluation = Self.evaluateDiscovery(
                localName: nil,
                peripheralName: peripheral.name,
                hasUARTService: true
            )
            ingestDiscoveredPeripheral(peripheral, evaluation: evaluation)
        }
        
        // Broad scan first, then filter in didDiscover.
        // Some firmware versions may not advertise UART service UUIDs during scan.
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }
    
    /// Stop scanning
    public func stopScanning() {
        centralManager.stopScan()
        isScanning = false
        log("Stopped scanning", level: .info)
    }
    
    /// Connect to a discovered glasses pair
    public func connect(to pair: DiscoveredGlassesPair) {
        guard pair.isComplete else {
            log("Cannot connect: Pair incomplete (need both L and R)", level: .warning)
            return
        }
        
        stopScanning()
        isIntentionalDisconnect = false
        reconnectionAttempts = 0
        
        // Create connected glasses pair
        let connected = ConnectedGlassesPair(channel: pair.channel)
        
        // Get peripheral references
        if let leftInfo = pair.leftInfo,
           let leftPeripheral = peripheralsByUUID[leftInfo.id] {
            connected.leftPeripheral = leftPeripheral
            connected.leftState = .connecting
            centralManager.connect(leftPeripheral, options: [
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
            ])
            log("Connecting to LEFT (\(leftInfo.name))...", level: .info)
        }
        
        if let rightInfo = pair.rightInfo,
           let rightPeripheral = peripheralsByUUID[rightInfo.id] {
            connected.rightPeripheral = rightPeripheral
            connected.rightState = .connecting
            centralManager.connect(rightPeripheral, options: [
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
            ])
            log("Connecting to RIGHT (\(rightInfo.name))...", level: .info)
        }
        
        connectedGlasses = connected
        connectionState = .partiallyConnected
    }
    
    /// Disconnect from current glasses
    public func disconnect() {
        isIntentionalDisconnect = true
        stopReconnectionTimer()
        stopHeartbeat()
        cancelAllPendingAcks()
        
        if let glasses = connectedGlasses {
            if let left = glasses.leftPeripheral {
                centralManager.cancelPeripheralConnection(left)
            }
            if let right = glasses.rightPeripheral {
                centralManager.cancelPeripheralConnection(right)
            }
        }
        
        connectedGlasses = nil
        connectionState = .disconnected
        isDashboardVisible = false
        activeMicrophoneSide = nil
        microphoneState = .idle
        microphoneStats = G1MicrophoneStats(startedAt: nil, packetCount: 0, byteCount: 0, lastSequence: nil)
        log("Disconnected", level: .info)
    }
    
    /// Send command to both glasses
    public func sendCommand(_ data: Data, to side: GlassesSide? = nil) {
        guard let glasses = connectedGlasses else {
            log("Cannot send: Not connected", level: .warning)
            return
        }
        
        let sendToLeft = side == nil || side == .left
        let sendToRight = side == nil || side == .right
        
        if sendToLeft {
            write(data, to: glasses.leftPeripheral, using: glasses.leftTXCharacteristic, side: .left)
        }
        if sendToRight {
            write(data, to: glasses.rightPeripheral, using: glasses.rightTXCharacteristic, side: .right)
        }
    }
    
    /// Send command and await ACK on one or both sides.
    /// Returns true only if all requested sides ACK within timeout.
    public func sendCommandAwaitAck(_ data: Data,
                                    to side: GlassesSide? = nil,
                                    sequence: UInt8? = nil,
                                    timeoutMs: Int = G1BLEConstants.commandTimeoutMs) async -> Bool {
        guard let glasses = connectedGlasses else {
            log("Cannot send with ACK: Not connected", level: .warning)
            return false
        }
        
        let command = data.first ?? 0x00
        for targetSide in Self.ackSendOrder(for: side) {
            let peripheral: CBPeripheral?
            let characteristic: CBCharacteristic?

            switch targetSide {
            case .left:
                peripheral = glasses.leftPeripheral
                characteristic = glasses.leftTXCharacteristic
            case .right:
                peripheral = glasses.rightPeripheral
                characteristic = glasses.rightTXCharacteristic
            }

            let acked = await writeAndAwaitAck(
                data,
                command: command,
                sequence: sequence,
                to: peripheral,
                using: characteristic,
                side: targetSide,
                timeoutMs: timeoutMs
            )

            if !acked {
                return false
            }
        }

        return true
    }

    nonisolated static func ackSendOrder(for side: GlassesSide?) -> [GlassesSide] {
        switch side {
        case .left:
            return [.left]
        case .right:
            return [.right]
        case .none:
            return [.left, .right]
        }
    }

    nonisolated static func prefersExtendedHeartbeat(for mode: G1ProtocolMode) -> Bool {
        switch mode {
        case .legacy:
            return false
        case .official, .auto:
            return true
        }
    }

    nonisolated static func headUpModePayload(for mode: G1HeadUpMode) -> [UInt8] {
        [mode.rawValue]
    }

    nonisolated static func dashboardVisibilityPayload(visible: Bool) -> [UInt8] {
        [visible ? 0x01 : 0x00]
    }

    nonisolated static func microphoneCommandCandidates(enable: Bool) -> [Data] {
        let flag: UInt8 = enable ? 0x01 : 0x00
        return [
            Data([G1CompatibilityCommand.microphonePrimary, flag]),
            Data([G1CompatibilityCommand.microphoneFallback, flag])
        ]
    }

    nonisolated static func microphoneControlOrder(preferredSide: GlassesSide,
                                                   activeSide: GlassesSide?) -> [GlassesSide] {
        var sides: [GlassesSide] = []
        if let activeSide {
            sides.append(activeSide)
        }
        sides.append(preferredSide)
        sides.append(preferredSide == .right ? .left : .right)

        var deduped: [GlassesSide] = []
        for side in sides where !deduped.contains(side) {
            deduped.append(side)
        }
        return deduped
    }

    nonisolated static func parseMicrophonePayload(_ payload: Data) -> (sequence: UInt8?, audioPayload: Data) {
        guard !payload.isEmpty else {
            return (nil, Data())
        }

        // Some firmwares emit `F1 + sequence + audio`, others emit `F1 + audio`.
        // Preserve LC3 frame alignment by inspecting likely audio lengths.
        let rawAudioLikely = looksLikeLC3AudioLength(payload.count)
        let strippedAudioLikely = looksLikeLC3AudioLength(payload.count - 1)

        if rawAudioLikely && !strippedAudioLikely {
            return (nil, payload)
        }

        if strippedAudioLikely, let sequence = payload.first {
            return (sequence, Data(payload.dropFirst()))
        }

        // Ambiguous case: prefer sequence-first for compatibility.
        if let sequence = payload.first {
            return (sequence, Data(payload.dropFirst()))
        }

        return (nil, payload)
    }

    nonisolated private static func looksLikeLC3AudioLength(_ byteCount: Int) -> Bool {
        guard byteCount > 0 else { return false }
        let commonFrameSizes = [20, 30, 40, 60]
        return commonFrameSizes.contains { byteCount % $0 == 0 }
    }

    nonisolated static func fallbackDashboardVisibility(config: G1TiltDashboardConfig?,
                                                        event: G1Event,
                                                        isDashboardVisible: Bool,
                                                        lastActionAt: Date?,
                                                        now: Date,
                                                        debounceSeconds: TimeInterval = dashboardFallbackDebounceSeconds) -> Bool? {
        guard let config, config.enabled, config.appEventFallback else { return nil }

        let desiredVisibility: Bool
        switch event {
        case .headUp:
            desiredVisibility = true
        case .headDown:
            desiredVisibility = false
        default:
            return nil
        }

        guard desiredVisibility != isDashboardVisible else { return nil }

        if let lastActionAt, now.timeIntervalSince(lastActionAt) < debounceSeconds {
            return nil
        }

        return desiredVisibility
    }

    nonisolated static func routesAck(for command: UInt8) -> Bool {
        switch command {
        case G1Command.INIT.rawValue,
             G1Command.HEARTBEAT.rawValue,
             G1CompatibilityCommand.brightnessV2,
             G1CompatibilityCommand.brightnessLegacy,
             G1Command.SILENT_MODE.rawValue,
             G1CompatibilityCommand.dashboardVisibility,
             G1CompatibilityCommand.headUpMode,
             G1CompatibilityCommand.headUpModeAlt,
             G1CompatibilityCommand.microphonePrimary,
             G1CompatibilityCommand.microphoneFallback,
             G1Command.WHITELIST.rawValue,
             G1Command.BMP_END.rawValue,
             G1Command.CRC_CHECK.rawValue,
             G1Command.SEND_TEXT.rawValue:
            return true
        default:
            return false
        }
    }
    
    /// Request battery status from both glasses
    public func requestBatteryStatus() {
        let batteryCommand = Data([G1Command.BATTERY.rawValue, 0x01])
        sendCommand(batteryCommand)
    }
    
    /// Send text to the glasses display
    public func sendText(_ text: String) {
        sendText(G1TextSendRequest(text: text, mode: .text))
    }

    /// Send text using a structured request
    public func sendText(_ request: G1TextSendRequest) {
        guard connectionState == .fullyConnected else {
            log("Cannot send text: Not fully connected", level: .warning)
            return
        }

        let builder = G1TextPacketBuilder(textHelper: textHelper)
        let packets = builder.buildPackets(for: request)

        if packets.isEmpty {
            log("No text packets to send", level: .warning)
            return
        }

        let preview = request.text.prefix(30)
        let suffix = request.text.count > 30 ? "..." : ""
        log("Sending \(request.mode.displayName) text: \"\(preview)\(suffix)\" (packets: \(packets.count), ack: \(request.awaitAck))", level: .info)

        Task {
            for (index, packet) in packets.enumerated() {
                if request.awaitAck {
                    let acked = await sendCommandAwaitAck(packet.data, sequence: nil)
                    if !acked {
                        log("Text send stopped after missing ACK (packet \(index + 1)/\(packets.count))", level: .warning)
                        break
                    }
                } else {
                    sendCommand(packet.data)
                }

                if index < packets.count - 1 {
                    try? await Task.sleep(nanoseconds: request.interPacketDelayMs * 1_000_000)
                }
            }
        }
    }
    
    /// Clear the glasses display
    public func clearDisplay() {
        let exitCommand = Data([G1Command.EXIT_ALL.rawValue])
        sendCommand(exitCommand)
        log("Display cleared", level: .info)
    }
    
    /// Set display brightness (0-100)
    public func setBrightness(_ level: Int, autoMode: Bool = false) {
        // Map 0-100 to 0-41 (G1 brightness range)
        let mappedLevel = min(41, max(0, Int((Double(level) / 100.0) * 41.0)))
        log("Setting brightness to \(level)% (mapped: \(mappedLevel))...", level: .info)

        Task {
            let payload = [UInt8(mappedLevel), autoMode ? 0x01 : 0x00]
            let acked = await sendCompatibilityCommand(
                .brightness,
                payload: payload,
                to: nil,
                sequence: nil,
                timeoutMs: max(700, G1BLEConstants.commandTimeoutMs)
            )

            if acked {
                log("Brightness set to \(level)% (mapped: \(mappedLevel))", level: .info)
            } else {
                log("Brightness command failed (official + legacy mappings)", level: .warning)
            }
        }
    }
    
    /// Set silent mode
    public func setSilentMode(_ enabled: Bool) {
        let command = Data([G1Command.SILENT_MODE.rawValue, enabled ? 0x0C : 0x0A, 0x00])
        sendCommand(command)
        log("Silent mode: \(enabled ? "ON" : "OFF")", level: .info)
    }

    /// Configure firmware-assisted dashboard activation via head-up behavior.
    /// Optionally enables app-side fallback on head-up/head-down events.
    public func configureTiltDashboard(_ config: G1TiltDashboardConfig) async -> Bool {
        tiltDashboardConfig = config
        lastDashboardFallbackActionAt = nil

        // In app-fallback mode we intentionally disable firmware dashboard activation
        // so head gestures can drive the app's custom flow instead of the stock dashboard.
        let mode: G1HeadUpMode
        if config.enabled {
            mode = config.appEventFallback ? .off : config.headUpMode
        } else {
            mode = .off
        }
        let modePayload = Self.headUpModePayload(for: mode)
        let rightModeAcked = await sendCompatibilityCommand(
            .headUpMode,
            payload: modePayload,
            to: .right,
            sequence: nil,
            timeoutMs: max(700, G1BLEConstants.commandTimeoutMs)
        )
        let leftModeAcked = await sendCompatibilityCommand(
            .headUpMode,
            payload: modePayload,
            to: .left,
            sequence: nil,
            timeoutMs: max(700, G1BLEConstants.commandTimeoutMs)
        )
        let modeAcked = rightModeAcked || leftModeAcked

        if !modeAcked {
            log("Tilt dashboard mode command failed", level: .warning)
        } else {
            if !rightModeAcked {
                log("Tilt mode update did not ACK on RIGHT", level: .warning)
            }
            if !leftModeAcked {
                log("Tilt mode update did not ACK on LEFT", level: .warning)
            }
        }

        if config.appEventFallback, config.enabled {
            log("Tilt dashboard configured for app-driven mode (firmware head-up disabled)", level: .info)
        }

        let visibilityAcked = await setDashboardVisible(false)
        if !visibilityAcked {
            log("Failed to reset dashboard visibility while configuring tilt mode", level: .warning)
        }

        return modeAcked && visibilityAcked
    }

    /// Show or hide the built-in dashboard UI on one side or both sides.
    @discardableResult
    public func setDashboardVisible(_ visible: Bool, to side: GlassesSide? = nil) async -> Bool {
        let payload = Self.dashboardVisibilityPayload(visible: visible)
        let acked = await sendCompatibilityCommand(
            .dashboardVisibility,
            payload: payload,
            to: side,
            sequence: nil,
            timeoutMs: max(700, G1BLEConstants.commandTimeoutMs)
        )

        if acked {
            isDashboardVisible = visible
            log("Dashboard \(visible ? "shown" : "hidden")", level: .info)
        } else {
            log("Dashboard visibility command failed", level: .warning)
        }

        return acked
    }

    /// Start microphone streaming from glasses.
    @discardableResult
    public func startMicrophone(preferredSide: GlassesSide = .right) async -> Bool {
        if case .streaming = microphoneState {
            return true
        }

        microphoneState = .starting
        resetMicrophoneStats()
        microphoneStats = G1MicrophoneStats(
            startedAt: Date(),
            packetCount: 0,
            byteCount: 0,
            lastSequence: nil
        )

        for side in Self.microphoneControlOrder(preferredSide: preferredSide, activeSide: nil) {
            let acked = await sendCompatibilityCommand(
                .microphoneControl,
                payload: [0x01],
                to: side,
                sequence: nil,
                timeoutMs: max(700, G1BLEConstants.commandTimeoutMs)
            )

            if acked {
                activeMicrophoneSide = side
                microphoneState = .streaming
                log("Microphone started on \(side.rawValue)", level: .info)
                return true
            }
        }

        microphoneState = .failed("Unable to start microphone on either side")
        log("Microphone start failed on all candidate sides", level: .warning)
        return false
    }

    /// Stop microphone streaming from glasses.
    @discardableResult
    public func stopMicrophone(preferredSide: GlassesSide = .right) async -> Bool {
        if case .idle = microphoneState {
            return true
        }

        microphoneState = .stopping

        for side in Self.microphoneControlOrder(preferredSide: preferredSide, activeSide: activeMicrophoneSide) {
            let acked = await sendCompatibilityCommand(
                .microphoneControl,
                payload: [0x00],
                to: side,
                sequence: nil,
                timeoutMs: max(700, G1BLEConstants.commandTimeoutMs)
            )

            if acked {
                activeMicrophoneSide = nil
                microphoneState = .idle
                log("Microphone stopped on \(side.rawValue)", level: .info)
                return true
            }
        }

        microphoneState = .failed("Unable to stop microphone on either side")
        log("Microphone stop failed on all candidate sides", level: .warning)
        return false
    }

    /// Reset packet counters while keeping current stream state untouched.
    public func resetMicrophoneStats() {
        let existingStartedAt: Date?
        switch microphoneState {
        case .starting, .streaming, .stopping:
            existingStartedAt = microphoneStats.startedAt ?? Date()
        case .idle, .failed:
            existingStartedAt = nil
        }

        microphoneStats = G1MicrophoneStats(
            startedAt: existingStartedAt,
            packetCount: 0,
            byteCount: 0,
            lastSequence: nil
        )
    }
    
    /// Clear logs
    public func clearLogs() {
        logs.removeAll()
        events.removeAll()
        recentFrames.removeAll()
    }
    
    /// Try to reconnect to last known glasses
    public func reconnectToLastKnown() {
        guard let leftUUIDString = UserDefaults.standard.string(forKey: Self.lastLeftUUIDKey),
              let rightUUIDString = UserDefaults.standard.string(forKey: Self.lastRightUUIDKey),
              let leftUUID = UUID(uuidString: leftUUIDString),
              let rightUUID = UUID(uuidString: rightUUIDString),
              let channel = UserDefaults.standard.string(forKey: Self.lastChannelKey) else {
            log("No previously connected glasses found", level: .info)
            return
        }
        
        log("Attempting to reconnect to last known glasses (channel: \(channel))...", level: .info)
        
        // Retrieve peripherals by UUID
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [leftUUID, rightUUID])
        
        if peripherals.count == 2 {
            let connected = ConnectedGlassesPair(channel: channel)
            
            for peripheral in peripherals {
                if peripheral.identifier == leftUUID {
                    connected.leftPeripheral = peripheral
                    connected.leftState = .connecting
                    peripheral.delegate = self
                    centralManager.connect(peripheral, options: [
                        CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
                    ])
                    peripheralsByUUID[peripheral.identifier] = peripheral
                } else if peripheral.identifier == rightUUID {
                    connected.rightPeripheral = peripheral
                    connected.rightState = .connecting
                    peripheral.delegate = self
                    centralManager.connect(peripheral, options: [
                        CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
                    ])
                    peripheralsByUUID[peripheral.identifier] = peripheral
                }
            }
            
            connectedGlasses = connected
            connectionState = .partiallyConnected
            isIntentionalDisconnect = false
        } else {
            log("Could not retrieve previously connected peripherals, starting scan...", level: .warning)
            startScanning()
        }
    }
    
    // MARK: - Private Methods

    private enum CompatibilityCommand: String {
        case brightness
        case headUpMode
        case dashboardVisibility
        case microphoneControl
    }

    private struct CompatibilityCommandPlan {
        let primary: UInt8
        let fallback: UInt8?
    }

    private func compatibilityPlan(for command: CompatibilityCommand) -> CompatibilityCommandPlan {
        switch command {
        case .brightness:
            switch protocolMode {
            case .legacy:
                return CompatibilityCommandPlan(
                    primary: G1CompatibilityCommand.brightnessLegacy,
                    fallback: nil
                )
            case .official, .auto:
                return CompatibilityCommandPlan(
                    primary: G1CompatibilityCommand.brightnessV2,
                    fallback: G1CompatibilityCommand.brightnessLegacy
                )
            }
        case .headUpMode:
            return CompatibilityCommandPlan(
                primary: G1CompatibilityCommand.headUpMode,
                fallback: G1CompatibilityCommand.headUpModeAlt
            )
        case .dashboardVisibility:
            return CompatibilityCommandPlan(
                primary: G1CompatibilityCommand.dashboardVisibility,
                fallback: nil
            )
        case .microphoneControl:
            return CompatibilityCommandPlan(
                primary: G1CompatibilityCommand.microphonePrimary,
                fallback: G1CompatibilityCommand.microphoneFallback
            )
        }
    }

    private func sendCompatibilityCommand(_ command: CompatibilityCommand,
                                          payload: [UInt8],
                                          to side: GlassesSide?,
                                          sequence: UInt8?,
                                          timeoutMs: Int) async -> Bool {
        let plan = compatibilityPlan(for: command)
        let primary = Data([plan.primary] + payload)

        if await sendCommandAwaitAck(primary, to: side, sequence: sequence, timeoutMs: timeoutMs) {
            return true
        }

        guard let fallback = plan.fallback, fallback != plan.primary else {
            return false
        }

        let fallbackData = Data([fallback] + payload)
        log(
            "Primary \(command.rawValue) command 0x\(String(format: "%02X", plan.primary)) failed; retrying 0x\(String(format: "%02X", fallback))",
            level: .warning
        )
        return await sendCommandAwaitAck(fallbackData, to: side, sequence: sequence, timeoutMs: timeoutMs)
    }
    
    private func write(_ data: Data, to peripheral: CBPeripheral?, using characteristic: CBCharacteristic?, side: GlassesSide) {
        guard let peripheral = peripheral,
              let characteristic = characteristic else {
            log("Write failed [\(side.rawValue)]: No peripheral or characteristic", level: .warning)
            return
        }
        
        peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        
        // Don't log heartbeats to avoid spam
        if data.first != G1Command.HEARTBEAT.rawValue {
            let hex = data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            log("TX [\(side.rawValue)]: \(hex)\(data.count > 8 ? "..." : "")", level: .debug)
        }
    }
    
    private func writeAndAwaitAck(_ data: Data,
                                  command: UInt8,
                                  sequence: UInt8?,
                                  to peripheral: CBPeripheral?,
                                  using characteristic: CBCharacteristic?,
                                  side: GlassesSide,
                                  timeoutMs: Int) async -> Bool {
        guard let peripheral = peripheral,
              let characteristic = characteristic else {
            log("Write+ACK failed [\(side.rawValue)]: No peripheral or characteristic", level: .warning)
            return false
        }
        
        let ackKey = AckKey(side: side, command: command, sequence: sequence)
        
        return await withCheckedContinuation { continuation in
            // Cancel and fail an older waiter if the same key is reused.
            if let existing = pendingAcks.removeValue(forKey: ackKey) {
                existing.timeoutTask.cancel()
                existing.continuation.resume(returning: false)
            }
            
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                guard let self else { return }
                if let expired = self.pendingAcks.removeValue(forKey: ackKey) {
                    expired.continuation.resume(returning: false)
                    self.log("ACK timeout [\(side.rawValue)] cmd=0x\(String(format: "%02X", command))", level: .warning)
                }
            }
            
            pendingAcks[ackKey] = PendingAck(timeoutTask: timeoutTask, continuation: continuation)
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            
            if command != G1Command.HEARTBEAT.rawValue {
                let hex = data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
                log("TX+ACK [\(side.rawValue)]: \(hex)\(data.count > 8 ? "..." : "")", level: .debug)
            }
        }
    }
    
    private func resolvePendingAck(side: GlassesSide, command: UInt8, sequence: UInt8?, success: Bool) -> Bool {
        let exactKey = AckKey(side: side, command: command, sequence: sequence)
        if let pending = pendingAcks.removeValue(forKey: exactKey) {
            pending.timeoutTask.cancel()
            pending.continuation.resume(returning: success)
            return true
        }
        
        // Fallback: resolve non-sequenced waiter for this command.
        let fallbackKey = AckKey(side: side, command: command, sequence: nil)
        if let pending = pendingAcks.removeValue(forKey: fallbackKey) {
            pending.timeoutTask.cancel()
            pending.continuation.resume(returning: success)
            return true
        }
        
        return false
    }
    
    private func cancelAllPendingAcks() {
        let allPending = pendingAcks.values
        pendingAcks.removeAll()
        
        for pending in allPending {
            pending.timeoutTask.cancel()
            pending.continuation.resume(returning: false)
        }
    }
    
    private func cancelPendingAcks(for side: GlassesSide) {
        let keys = pendingAcks.keys.filter { $0.side == side }
        for key in keys {
            guard let pending = pendingAcks.removeValue(forKey: key) else { continue }
            pending.timeoutTask.cancel()
            pending.continuation.resume(returning: false)
        }
    }
    
    private func log(_ message: String, level: LogEntry.LogLevel = .info) {
        let entry = LogEntry(timestamp: Date(), message: message, level: level)
        
        Task { @MainActor in
            self.logs.append(entry)
            // Keep last 200 logs
            if self.logs.count > 200 {
                self.logs.removeFirst(self.logs.count - 200)
            }
        }
        
        // Also log to system
        logger.log("\(level.rawValue) \(message)")
    }
    
    private func addEvent(_ event: G1Event) {
        Task { @MainActor in
            self.events.insert(event, at: 0)
            if self.events.count > 50 {
                self.events.removeLast()
            }
        }
    }
    
    private func addFrame(_ frame: G1Frame) {
        Task { @MainActor in
            self.recentFrames.insert(frame, at: 0)
            if self.recentFrames.count > 100 {
                self.recentFrames.removeLast()
            }
        }
    }
    
    // MARK: - Connection State Machine
    
    private func handlePeripheralConnected(_ peripheral: CBPeripheral) {
        guard let glasses = connectedGlasses else { return }
        
        let side: GlassesSide
        if peripheral.identifier == glasses.leftPeripheral?.identifier {
            side = .left
            glasses.leftState = .discoveringServices
        } else if peripheral.identifier == glasses.rightPeripheral?.identifier {
            side = .right
            glasses.rightState = .discoveringServices
        } else {
            return
        }
        
        log("Connected [\(side.rawValue)]: \(peripheral.name ?? "Unknown")", level: .success)
        
        peripheral.delegate = self
        peripheral.discoverServices([G1BLEConstants.uartServiceUUID])
        
        updateConnectionState()
    }
    
    private func handleServicesDiscovered(_ peripheral: CBPeripheral) {
        guard let glasses = connectedGlasses,
              let services = peripheral.services else { return }
        
        let side = sideForPeripheral(peripheral)
        glasses.setState(.discoveringCharacteristics, for: side)
        
        for service in services where service.uuid == G1BLEConstants.uartServiceUUID {
            peripheral.discoverCharacteristics(
                [G1BLEConstants.uartTXCharacteristicUUID, G1BLEConstants.uartRXCharacteristicUUID],
                for: service
            )
        }
    }
    
    private func handleCharacteristicsDiscovered(_ peripheral: CBPeripheral, service: CBService) {
        guard let glasses = connectedGlasses,
              let characteristics = service.characteristics else { return }
        
        let side = sideForPeripheral(peripheral)
        
        for characteristic in characteristics {
            if characteristic.uuid == G1BLEConstants.uartRXCharacteristicUUID {
                // Subscribe to notifications
                peripheral.setNotifyValue(true, for: characteristic)
                glasses.setState(.enablingNotifications, for: side)
                log("Subscribing to RX notifications [\(side.rawValue)]", level: .debug)
            }
            
            if characteristic.uuid == G1BLEConstants.uartTXCharacteristicUUID {
                // Store TX characteristic
                switch side {
                case .left: glasses.leftTXCharacteristic = characteristic
                case .right: glasses.rightTXCharacteristic = characteristic
                }
                log("Found TX characteristic [\(side.rawValue)]", level: .debug)
            }
        }
    }
    
    private func handleNotificationsEnabled(_ peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard let glasses = connectedGlasses,
              characteristic.uuid == G1BLEConstants.uartRXCharacteristicUUID else { return }
        
        let side = sideForPeripheral(peripheral)
        glasses.setState(.initializing, for: side)
        
        log("RX notifications enabled [\(side.rawValue)], sending init...", level: .info)
        
        // Send init command: 0x4D 0x01
        let initData = Data([G1Command.INIT.rawValue, 0x01])
        if let txChar = glasses.txCharacteristic(for: side) {
            peripheral.writeValue(initData, for: txChar, type: .withoutResponse)
            log("Sent INIT command [\(side.rawValue)]", level: .debug)
        }
    }
    
    private func handleInitAck(side: GlassesSide) {
        guard let glasses = connectedGlasses else { return }
        
        glasses.setState(.ready, for: side)
        log("Init ACK received [\(side.rawValue)] - Ready!", level: .success)
        
        updateConnectionState()
        
        // Check if fully connected
        if glasses.overallState == .fullyConnected {
            onFullyConnected()
        }
    }
    
    private func onFullyConnected() {
        guard let glasses = connectedGlasses else { return }
        
        log("🎉 Glasses fully connected!", level: .success)
        connectionState = .fullyConnected
        
        // Persist UUIDs for reconnection
        if let leftUUID = glasses.leftPeripheral?.identifier.uuidString,
           let rightUUID = glasses.rightPeripheral?.identifier.uuidString {
            UserDefaults.standard.set(leftUUID, forKey: Self.lastLeftUUIDKey)
            UserDefaults.standard.set(rightUUID, forKey: Self.lastRightUUIDKey)
            UserDefaults.standard.set(glasses.channel, forKey: Self.lastChannelKey)
        }
        
        heartbeatMode = initialHeartbeatMode()
        missedHeartbeatAcks = 0
        
        // Start heartbeat
        startHeartbeat()
        
        // Request battery status
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.requestBatteryStatus()
        }
    }
    
    private func handleIncomingData(_ data: Data, from peripheral: CBPeripheral) {
        let side = sideForPeripheral(peripheral)
        let frame = frameParser.parseFrame(data: data, side: side)
        routeAckIfNeeded(frame, side: side)

        if frame.commandByte == G1Command.MIC_DATA.rawValue {
            handleMicrophoneFrame(frame)
        }
        
        // Check for init ACK
        if frame.commandByte == G1Command.INIT.rawValue,
           frame.payload.first == G1Response.ACK.rawValue {
            handleInitAck(side: side)
            return
        }
        
        // Parse event
        if let event = frameParser.parseEvent(from: frame) {
            addEvent(event)
            log("Event [\(side.rawValue)]: \(event.displayString)", level: .info)
            
            // Handle battery updates
            if case .batteryUpdate(let batterySide, let level) = event {
                if let glasses = connectedGlasses {
                    switch batterySide {
                    case .left: glasses.leftBattery = level
                    case .right: glasses.rightBattery = level
                    }
                }
            }

            handleTiltDashboardFallbackIfNeeded(event)
        }
        
        // Add to frames if not filtered
        if !frameParser.shouldFilter(frame: frame) {
            addFrame(frame)
        }
    }

    private func handleMicrophoneFrame(_ frame: G1Frame) {
        let parsed = Self.parseMicrophonePayload(frame.payload)
        guard !parsed.audioPayload.isEmpty else { return }

        let packet = G1MicrophonePacket(
            timestamp: frame.timestamp,
            side: frame.side,
            sequence: parsed.sequence,
            payload: parsed.audioPayload
        )
        microphonePackets.send(packet)

        microphoneStats = Self.applyingMicrophonePacket(
            packet,
            to: microphoneStats,
            fallbackStartDate: frame.timestamp
        )

        if case .starting = microphoneState {
            microphoneState = .streaming
        }
    }

    nonisolated static func applyingMicrophonePacket(_ packet: G1MicrophonePacket,
                                                     to stats: G1MicrophoneStats,
                                                     fallbackStartDate: Date) -> G1MicrophoneStats {
        G1MicrophoneStats(
            startedAt: stats.startedAt ?? fallbackStartDate,
            packetCount: stats.packetCount + 1,
            byteCount: stats.byteCount + packet.payload.count,
            lastSequence: packet.sequence ?? stats.lastSequence
        )
    }

    private func handleTiltDashboardFallbackIfNeeded(_ event: G1Event) {
        guard let config = tiltDashboardConfig, config.enabled else {
            return
        }

        let now = Date()

        // Backstop for firmwares that still pop the stock dashboard even when mode is set to off.
        // Keep sending "hide" on head gestures when the user explicitly chose no dashboard mode.
        let isHeadGesture: Bool
        switch event {
        case .headUp, .headDown:
            isHeadGesture = true
        default:
            isHeadGesture = false
        }

        if !config.appEventFallback,
           config.headUpMode == .off,
           isHeadGesture {
            if let lastActionAt = lastDashboardFallbackActionAt,
               now.timeIntervalSince(lastActionAt) < Self.dashboardFallbackDebounceSeconds {
                return
            }
            lastDashboardFallbackActionAt = now
            log("Tilt suppression requested dashboard hide", level: .debug)
            Task { @MainActor in
                _ = await self.setDashboardVisible(false)
            }
            return
        }

        guard let desiredVisibility = Self.fallbackDashboardVisibility(
            config: config,
            event: event,
            isDashboardVisible: isDashboardVisible,
            lastActionAt: lastDashboardFallbackActionAt,
            now: now
        ) else {
            return
        }

        lastDashboardFallbackActionAt = now
        if config.appEventFallback {
            isDashboardVisible = desiredVisibility
            log("Tilt event set app dashboard state: \(desiredVisibility ? "visible" : "hidden")", level: .info)
            return
        }

        Task { @MainActor in
            _ = await self.setDashboardVisible(desiredVisibility)
        }
    }
    
    private func routeAckIfNeeded(_ frame: G1Frame, side: GlassesSide) {
        guard shouldRouteAck(for: frame.commandByte) else { return }
        
        let command = frame.commandByte
        var success = true
        var sequence: UInt8? = nil
        
        if command == G1Command.HEARTBEAT.rawValue {
            let payload = frame.payload
            // Extended heartbeat response shape: [lenLo, lenHi, seq, 0x04, seq]
            if payload.count >= 5 && payload[3] == 0x04 {
                sequence = payload[2]
            } else if payload.count >= 2 && payload[0] == 0x04 {
                // Alternate response shape: [0x04, seq]
                sequence = payload[1]
            } else if payload.count >= 1 {
                // Short heartbeat response shape: [seq]
                sequence = payload[0]
            }
        } else if let status = frame.payload.first {
            if status == G1Response.ACK.rawValue || status == G1Response.CONTINUE.rawValue {
                success = true
            } else if status == G1Response.NACK.rawValue {
                success = false
            } else {
                // Some responses are effectively ACK without explicit C9.
                success = true
            }
        }
        
        _ = resolvePendingAck(side: side, command: command, sequence: sequence, success: success)
    }
    
    private func shouldRouteAck(for command: UInt8) -> Bool {
        Self.routesAck(for: command)
    }
    
    private func handlePeripheralDisconnected(_ peripheral: CBPeripheral, error: Error?) {
        guard let glasses = connectedGlasses else { return }
        
        let side = sideForPeripheral(peripheral)
        glasses.setState(.disconnected, for: side)
        cancelPendingAcks(for: side)
        
        if let error = error {
            log("Disconnected [\(side.rawValue)] with error: \(error.localizedDescription)", level: .error)
        } else {
            log("Disconnected [\(side.rawValue)]", level: .warning)
        }

        if activeMicrophoneSide == side {
            activeMicrophoneSide = nil
            microphoneState = .failed("Active microphone side disconnected")
        }
        
        updateConnectionState()
        
        // Attempt reconnection if not intentional
        if !isIntentionalDisconnect && autoReconnect {
            startReconnectionTimer()
        }
    }
    
    private func updateConnectionState() {
        guard let glasses = connectedGlasses else {
            connectionState = .disconnected
            return
        }
        connectionState = glasses.overallState
    }
    
    private func sideForPeripheral(_ peripheral: CBPeripheral) -> GlassesSide {
        if peripheral.identifier == connectedGlasses?.leftPeripheral?.identifier {
            return .left
        }
        return .right
    }
    
    // MARK: - Heartbeat

    private func initialHeartbeatMode() -> HeartbeatMode {
        Self.prefersExtendedHeartbeat(for: protocolMode) ? .extended : .short
    }
    
    private func startHeartbeat() {
        stopHeartbeat()
        
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: G1BLEConstants.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.sendHeartbeat()
            }
        }
    }
    
    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        missedHeartbeatAcks = 0
    }
    
    private func sendHeartbeat() async {
        heartbeatCounter = heartbeatCounter &+ 1
        
        let sequence = heartbeatCounter
        let heartbeatData: Data
        switch heartbeatMode {
        case .short:
            heartbeatData = Data([G1Command.HEARTBEAT.rawValue, sequence])
        case .extended:
            heartbeatData = Data([G1Command.HEARTBEAT.rawValue, 0x06, 0x00, sequence, 0x04, sequence])
        }
        
        let acked = await sendCommandAwaitAck(
            heartbeatData,
            sequence: sequence,
            timeoutMs: max(900, G1BLEConstants.commandTimeoutMs)
        )
        
        if acked {
            if missedHeartbeatAcks > 0 {
                log("Heartbeat recovered (\(heartbeatMode == .short ? "short" : "extended") mode)", level: .info)
            }
            missedHeartbeatAcks = 0
            return
        }
        
        missedHeartbeatAcks += 1
        if missedHeartbeatAcks >= 2 {
            heartbeatMode = heartbeatMode == .short ? .extended : .short
            missedHeartbeatAcks = 0
            log("Heartbeat ACKs missing; switching heartbeat mode to \(heartbeatMode == .short ? "short" : "extended")", level: .warning)
        }
    }
    
    // MARK: - Reconnection
    
    private func startReconnectionTimer() {
        guard reconnectionAttempts < G1BLEConstants.maxReconnectionAttempts else {
            log("Max reconnection attempts reached", level: .error)
            return
        }
        
        stopReconnectionTimer()
        
        reconnectionAttempts += 1
        log("Scheduling reconnection attempt \(reconnectionAttempts)/\(G1BLEConstants.maxReconnectionAttempts)...", level: .info)
        
        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        timer.schedule(deadline: .now() + G1BLEConstants.reconnectionDelay)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.attemptReconnection()
            }
        }
        reconnectionTimer = timer
        timer.resume()
    }
    
    private func stopReconnectionTimer() {
        reconnectionTimer?.cancel()
        reconnectionTimer = nil
    }
    
    private func attemptReconnection() {
        log("Attempting reconnection...", level: .info)
        reconnectToLastKnown()
    }
    
    private func ingestDiscoveredPeripheral(_ peripheral: CBPeripheral,
                                            evaluation: DiscoveryEvaluation) {
        if verboseDiscoveryLogging {
            for rejection in evaluation.rejections {
                let source = rejection.source?.rawValue ?? "none"
                let name = rejection.name ?? "n/a"
                log("Discovery reject [\(rejection.reason.rawValue)] source=\(source) name=\(name)", level: .debug)
            }
        }

        guard let parsed = evaluation.parsed else { return }

        log("Discovery accepted source=\(parsed.source.rawValue) name=\(parsed.selectedName)", level: .debug)
        peripheralsByUUID[peripheral.identifier] = peripheral

        var pair = discoveredPairs[parsed.pairID] ?? DiscoveredGlassesPair(channel: parsed.channel)
        let info = G1PeripheralInfo(peripheral: peripheral, side: parsed.side, channel: parsed.channel)

        switch parsed.side {
        case .left:
            if pair.leftInfo == nil {
                pair.leftInfo = info
                log("Found LEFT: \(parsed.selectedName)", level: .info)
            }
        case .right:
            if pair.rightInfo == nil {
                pair.rightInfo = info
                log("Found RIGHT: \(parsed.selectedName)", level: .info)
            }
        }

        discoveredPairs[parsed.pairID] = pair

        if pair.isComplete {
            log("Complete pair found for \(pair.displayName)!", level: .success)
        }
    }
    
    // MARK: - Discovery Parsing
    
    enum DiscoveryNameSource: String, Equatable, Sendable {
        case localName
        case peripheralName
    }
    
    enum DiscoveryRejectReason: String, Equatable, Sendable {
        case missingSideMarker = "missing_side_marker"
        case notG1LikeAndNoUARTService = "not_g1_like_and_no_uart_service"
        case pairIDExtractionFailed = "pair_id_extraction_failed"
        case nameUnavailable = "name_unavailable"
    }
    
    struct DiscoveryRejection: Equatable, Sendable {
        let reason: DiscoveryRejectReason
        let source: DiscoveryNameSource?
        let name: String?
    }
    
    struct DiscoveryParseResult: Equatable, Sendable {
        let source: DiscoveryNameSource
        let selectedName: String
        let side: GlassesSide
        let pairID: String
        let channel: String
    }
    
    struct DiscoveryEvaluation: Equatable, Sendable {
        let parsed: DiscoveryParseResult?
        let rejections: [DiscoveryRejection]
    }

    nonisolated static func evaluateDiscovery(localName: String?,
                                              peripheralName: String?,
                                              hasUARTService: Bool) -> DiscoveryEvaluation {
        var candidates: [(DiscoveryNameSource, String)] = []
        var seenNames = Set<String>()
        
        func appendCandidate(source: DiscoveryNameSource, name: String?) {
            guard let candidate = Self.sanitizedName(name) else { return }
            guard seenNames.insert(candidate).inserted else { return }
            candidates.append((source, candidate))
        }
        
        appendCandidate(source: .localName, name: localName)
        appendCandidate(source: .peripheralName, name: peripheralName)
        
        guard !candidates.isEmpty else {
            return DiscoveryEvaluation(
                parsed: nil,
                rejections: [DiscoveryRejection(reason: .nameUnavailable, source: nil, name: nil)]
            )
        }
        
        var rejections: [DiscoveryRejection] = []
        
        for (source, candidateName) in candidates {
            guard let side = GlassesSide.from(name: candidateName) else {
                rejections.append(DiscoveryRejection(
                    reason: .missingSideMarker,
                    source: source,
                    name: candidateName
                ))
                continue
            }
            
            guard hasUARTService || Self.isLikelyG1Name(candidateName) else {
                rejections.append(DiscoveryRejection(
                    reason: .notG1LikeAndNoUARTService,
                    source: source,
                    name: candidateName
                ))
                continue
            }
            
            guard let pairID = Self.extractPairID(from: candidateName) else {
                rejections.append(DiscoveryRejection(
                    reason: .pairIDExtractionFailed,
                    source: source,
                    name: candidateName
                ))
                continue
            }
            
            let channel = Self.extractChannel(from: candidateName, fallback: pairID)
            return DiscoveryEvaluation(
                parsed: DiscoveryParseResult(
                    source: source,
                    selectedName: candidateName,
                    side: side,
                    pairID: pairID,
                    channel: channel
                ),
                rejections: rejections
            )
        }
        
        return DiscoveryEvaluation(parsed: nil, rejections: rejections)
    }

    nonisolated private static func sanitizedName(_ name: String?) -> String? {
        guard let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    nonisolated private static func advertisedLocalName(from advertisementData: [String: Any]) -> String? {
        sanitizedName(advertisementData[CBAdvertisementDataLocalNameKey] as? String)
    }
    
    nonisolated private static func normalizedDeviceName(_ name: String) -> String {
        var normalized = name
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        while normalized.contains("__") {
            normalized = normalized.replacingOccurrences(of: "__", with: "_")
        }
        return normalized
    }

    nonisolated static func hasUARTService(in advertisementData: [String: Any]) -> Bool {
        guard let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] else {
            return false
        }
        return serviceUUIDs.contains(G1BLEConstants.uartServiceUUID)
    }

    /// Accept the canonical Even naming and common shortened G1 variants.
    nonisolated static func isLikelyG1Name(_ name: String) -> Bool {
        let normalized = name.lowercased()
        if normalized.contains("even g1") {
            return true
        }

        let tokens = normalized
            .replacingOccurrences(of: "-", with: "_")
            .split(separator: "_")
            .map(String.init)

        return tokens.contains("g1") || normalized.hasPrefix("g1")
    }

    /// Pair both sides by removing only the side marker from the name.
    /// This works for "Even G1_74_L_57863C" and "G1_L_1234" style names.
    nonisolated static func extractPairID(from name: String) -> String? {
        var normalized = Self.normalizedDeviceName(name)
        let hasLeftMarker = normalized.range(of: "_L_", options: [.caseInsensitive]) != nil
        let hasRightMarker = normalized.range(of: "_R_", options: [.caseInsensitive]) != nil
        guard hasLeftMarker || hasRightMarker else { return nil }

        let channel = Self.extractChannel(from: normalized, fallback: "")
        if !channel.isEmpty {
            // Channel is the stable identity shared by L/R arms for Even G1 naming.
            return "g1_channel_\(channel.lowercased())"
        }

        normalized = normalized.replacingOccurrences(of: "_L_", with: "_", options: [.caseInsensitive], range: nil)
        normalized = normalized.replacingOccurrences(of: "_R_", with: "_", options: [.caseInsensitive], range: nil)
        while normalized.contains("__") {
            normalized = normalized.replacingOccurrences(of: "__", with: "_")
        }
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "_ ").union(.whitespacesAndNewlines))

        return normalized.isEmpty ? nil : normalized
    }

    /// Channel for display/persistence.
    /// Preferred token is the value immediately before L/R marker, else fallback.
    nonisolated static func extractChannel(from name: String, fallback: String) -> String {
        let parts = Self.normalizedDeviceName(name).split(separator: "_").map(String.init)
        if let sideIndex = parts.firstIndex(where: {
            $0.caseInsensitiveCompare("L") == .orderedSame || $0.caseInsensitiveCompare("R") == .orderedSame
        }) {
            if sideIndex > 0 {
                let tokenBeforeSide = parts[sideIndex - 1]
                if tokenBeforeSide.uppercased() != "G1" {
                    return tokenBeforeSide
                }
            }
            if sideIndex + 1 < parts.count {
                return parts[sideIndex + 1]
            }
        }
        return parts.last ?? fallback
    }
}

// MARK: - CBCentralManagerDelegate

extension G1BluetoothManager: CBCentralManagerDelegate {
    
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                self.log("Bluetooth powered on", level: .success)
            case .poweredOff:
                self.log("Bluetooth powered off", level: .warning)
                self.connectionState = .disconnected
            case .unauthorized:
                self.log("Bluetooth unauthorized", level: .error)
            case .unsupported:
                self.log("Bluetooth unsupported", level: .error)
            case .resetting:
                self.log("Bluetooth resetting", level: .warning)
            case .unknown:
                self.log("Bluetooth state unknown", level: .warning)
            @unknown default:
                self.log("Bluetooth state: \(central.state.rawValue)", level: .warning)
            }
        }
    }
    
    nonisolated public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                           advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let evaluation = Self.evaluateDiscovery(
            localName: Self.advertisedLocalName(from: advertisementData),
            peripheralName: peripheral.name,
            hasUARTService: Self.hasUARTService(in: advertisementData)
        )
        
        Task { @MainActor in
            self.ingestDiscoveredPeripheral(peripheral, evaluation: evaluation)
        }
    }
    
    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.handlePeripheralConnected(peripheral)
        }
    }
    
    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                           error: Error?) {
        Task { @MainActor in
            self.handlePeripheralDisconnected(peripheral, error: error)
        }
    }
    
    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                           error: Error?) {
        Task { @MainActor in
            let name = peripheral.name ?? "Unknown"
            self.log("Failed to connect to \(name): \(error?.localizedDescription ?? "Unknown error")", level: .error)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension G1BluetoothManager: CBPeripheralDelegate {
    
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            Task { @MainActor in
                self.log("Service discovery error: \(error.localizedDescription)", level: .error)
            }
            return
        }
        
        Task { @MainActor in
            self.handleServicesDiscovered(peripheral)
        }
    }
    
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                       error: Error?) {
        if let error = error {
            Task { @MainActor in
                self.log("Characteristic discovery error: \(error.localizedDescription)", level: .error)
            }
            return
        }
        
        Task { @MainActor in
            self.handleCharacteristicsDiscovered(peripheral, service: service)
        }
    }
    
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                       error: Error?) {
        if let error = error {
            Task { @MainActor in
                self.log("Notification state error: \(error.localizedDescription)", level: .error)
            }
            return
        }
        
        if characteristic.isNotifying {
            Task { @MainActor in
                self.handleNotificationsEnabled(peripheral, characteristic: characteristic)
            }
        }
    }
    
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                       error: Error?) {
        guard error == nil,
              let data = characteristic.value,
              !data.isEmpty else { return }
        
        Task { @MainActor in
            self.handleIncomingData(data, from: peripheral)
        }
    }
    
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                                       error: Error?) {
        if let error = error {
            Task { @MainActor in
                let side = self.sideForPeripheral(peripheral)
                self.log("Write error [\(side.rawValue)]: \(error.localizedDescription)", level: .error)
            }
        }
    }
}
