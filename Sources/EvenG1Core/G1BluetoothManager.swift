import Foundation
import CoreBluetooth
import Combine
import os.log

/// Logger for G1 Bluetooth operations
private let logger = Logger(subsystem: "com.eveng1", category: "Bluetooth")

/// FIFO async gate used on the main actor to prevent command-state races across
/// suspension points. A resumed waiter owns the gate until it releases it.
@MainActor
private final class G1AsyncGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var waiterHead = 0

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }

        if !isLocked {
            isLocked = true
            return true
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }

        if Task.isCancelled {
            release()
            return false
        }
        return true
    }

    func release() {
        guard waiterHead < waiters.count else {
            waiters.removeAll(keepingCapacity: true)
            waiterHead = 0
            isLocked = false
            return
        }

        let continuation = waiters[waiterHead]
        waiterHead += 1
        if waiterHead >= 64, waiterHead * 2 >= waiters.count {
            waiters.removeFirst(waiterHead)
            waiterHead = 0
        }
        continuation.resume()
    }
}

/// Main Bluetooth manager for Even G1 glasses
/// Inspired by MentraOS patterns with reconnection and persistence.
@MainActor
public final class G1BluetoothManager: NSObject, ObservableObject {

    // MARK: - Published State

    /// Current connection state
    @Published public private(set) var connectionState: GlassesConnectionState = .disconnected
    
    /// Discovered glasses pairs (may be partial)
    @Published public private(set) var discoveredPairs: [String: DiscoveredGlassesPair] = [:]
    
    /// Currently connected glasses (nil if not connected)
    @Published public private(set) var connectedGlasses: ConnectedGlassesPair?

    /// High-frequency diagnostics buffers, isolated from consumer-tab observation.
    public let diagnostics = G1DiagnosticsStore()

    /// Lightweight revision counter for glasses gesture routing.
    public let glassesEvents = G1GlassesEventNotifier()
    
    /// Is currently scanning
    @Published public private(set) var isScanning: Bool = false

    /// Tilt dashboard behavior configuration.
    @Published public private(set) var tiltDashboardConfig: G1TiltDashboardConfig?

    /// Whether the glasses dashboard is currently shown (tracked app-side).
    @Published public private(set) var isDashboardVisible: Bool = false

    /// Whether an app feature is currently drawing its own content on the single
    /// display surface. While claimed, head gestures must not toggle the stock
    /// dashboard, which would otherwise cover that content.
    @Published public private(set) var isCustomDisplaySurfaceClaimed: Bool = false

    /// Last display-position setting acknowledged by both arms.
    @Published public private(set) var displayPositionSettings: G1DisplayPositionSettings?

    /// Whether silent mode is believed to be on, tracked app-side because the
    /// glasses do not report the setting back.
    @Published public private(set) var isSilentModeEnabled: Bool = false

    /// Brightness last requested through ``setBrightness(_:autoMode:)``.
    @Published public private(set) var brightnessLevel: Int = 50

    /// Whether automatic brightness was requested with the last brightness command.
    @Published public private(set) var isAutoBrightnessEnabled: Bool = false

    /// Glasses microphone capture state.
    @Published public private(set) var microphoneState: G1MicrophoneState = .idle

    /// Aggregate metrics for microphone packets received from glasses.
    @Published public private(set) var microphoneStats: G1MicrophoneStats = .init(
        startedAt: nil,
        packetCount: 0,
        byteCount: 0,
        lastSequence: nil
    )

    /// Navigation session lifecycle state.
    @Published public private(set) var navigationSessionState: G1NavigationSessionState = .inactive

    /// Active navigation mode for the current or next session.
    @Published public private(set) var navigationMode: G1NavigationMode = .walking

    /// Current transport mode for navigation payload delivery.
    @Published public private(set) var navigationTransportMode: G1NavigationTransportMode = .nativePackets

    /// Whether navigation overlay content should be shown on phone UI.
    @Published public private(set) var isNavigationOverlayVisible: Bool = true

    /// Whether periodic navigation status announcements are muted.
    @Published public private(set) var isNavigationMuted: Bool = false

    /// Most recent instruction mirrored to glasses.
    @Published public private(set) var lastNavigationInstruction: G1NavigationInstruction?

    /// Structured trace entries for navigation TX/RX flow (exportable JSONL).
    @Published public private(set) var navigationTraceEntries: [G1NavigationTraceEntry] = []

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
    
    /// Central manager
    private var centralManager: CBCentralManager!
    
    /// Peripheral references by UUID
    private var peripheralsByUUID: [UUID: CBPeripheral] = [:]
    
    /// Structured heartbeat loop
    private var heartbeatTask: Task<Void, Never>?
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

    /// A protocol packet waiting for Core Bluetooth's write-without-response
    /// transmit buffer. Packet boundaries must remain intact for the glasses.
    private struct PendingWrite {
        let peripheralIdentifier: UUID
        let data: Data
        let side: GlassesSide
        let logPrefix: String
        let prepareForWrite: (() -> Void)?
        let failBeforeWrite: (() -> Void)?
    }

    /// Amortized O(1) FIFO storage. Array.removeFirst() copied the remaining
    /// write backlog for every BLE packet during bitmap transfers.
    private struct PendingWriteQueue {
        private var storage: [PendingWrite] = []
        private var head = 0

        var count: Int { storage.count - head }

        mutating func append(_ write: PendingWrite) {
            storage.append(write)
        }

        mutating func popFirst() -> PendingWrite? {
            guard head < storage.count else { return nil }
            let write = storage[head]
            head += 1

            if head >= 64, head * 2 >= storage.count {
                storage.removeFirst(head)
                head = 0
            }
            return write
        }

        mutating func removeAll() -> [PendingWrite] {
            let remaining = head < storage.count ? Array(storage[head...]) : []
            storage.removeAll(keepingCapacity: true)
            head = 0
            return remaining
        }
    }
    
    private var pendingAcks: [AckKey: PendingAck] = [:]
    private let ackCommandGate = G1AsyncGate()
    private let navigationCommandGate = G1AsyncGate()
    private let displayCommandGate = G1AsyncGate()
    private var pendingWrites: [GlassesSide: PendingWriteQueue] = [
        .left: PendingWriteQueue(),
        .right: PendingWriteQueue()
    ]
    private static let maxPendingWritesPerSide = 512
    
    /// Reconnection state
    private var reconnectionAttempts: Int = 0
    private var reconnectionTask: Task<Void, Never>?
    private var isIntentionalDisconnect: Bool = false
    private var shouldReconnectAfterCentralRecovery: Bool = false
    private var isReconnecting: Bool = false
    private var hasAttemptedLaunchReconnect: Bool = false

    /// Dashboard fallback debounce for event-driven show/hide.
    private var lastDashboardFallbackActionAt: Date?
    nonisolated private static let dashboardFallbackDebounceSeconds: TimeInterval = 0.3

    /// Side currently handling microphone control.
    private var activeMicrophoneSide: GlassesSide?

    /// Sequence used by the vendor-documented 0x26 display settings packet.
    private var displaySettingsSequence: UInt8 = 0

    /// Transport ID used by the vendor notification packet header.
    private var notificationTransportID: UInt8 = 0

    /// Native-first navigation delivery controller.
    private var navigationTransport = G1NavigationTransport()

    /// Suppresses heartbeat traffic while a display transaction is in flight.
    private var displayTransactionDepth = 0

    /// Last known progress context for trace enrichment.
    private var lastNavigationProgress: G1NavigationProgress?
    
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

            var telemetryLevel: TelemetryLogLevel {
                switch self {
                case .debug: return .debug
                case .info: return .info
                case .warning: return .warn
                case .error: return .error
                case .success: return .notice
                }
            }
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
        // A nil queue delivers delegate callbacks on the main queue, matching
        // this manager's main-actor-isolated delegate implementations.
        centralManager = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
    }
    
    deinit {
        heartbeatTask?.cancel()
        reconnectionTask?.cancel()
    }
    
    // MARK: - Public API
    
    /// Start scanning for Even G1 glasses
    public func startScanning() {
        beginScanning(forReconnection: false)
    }

    private func beginScanning(forReconnection: Bool) {
        guard centralManager.state == .poweredOn else {
            log("Cannot scan: Bluetooth not powered on", level: .warning)
            return
        }

        if !forReconnection {
            isReconnecting = false
            stopReconnectionTimer()
            reconnectionAttempts = 0
            hasAttemptedLaunchReconnect = true
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

        // Seeding may have completed an automatic reconnection synchronously.
        guard isScanning else { return }
        
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
        connect(to: pair, forReconnection: false)
    }

    private func connect(to pair: DiscoveredGlassesPair, forReconnection: Bool) {
        guard pair.isComplete else {
            log("Cannot connect: Pair incomplete (need both L and R)", level: .warning)
            return
        }
        
        stopScanning()
        isIntentionalDisconnect = false
        isReconnecting = forReconnection
        if !forReconnection {
            reconnectionAttempts = 0
        }
        
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
        shouldReconnectAfterCentralRecovery = false
        isReconnecting = false
        stopReconnectionTimer()
        stopHeartbeat()
        cancelAllPendingAcks()
        failAllQueuedWrites()
        
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
        isCustomDisplaySurfaceClaimed = false
        displayPositionSettings = nil
        activeMicrophoneSide = nil
        microphoneState = .idle
        microphoneStats = G1MicrophoneStats(startedAt: nil, packetCount: 0, byteCount: 0, lastSequence: nil)
        navigationSessionState = .inactive
        navigationMode = .walking
        isNavigationOverlayVisible = true
        isNavigationMuted = false
        lastNavigationInstruction = nil
        lastNavigationProgress = nil
        navigationTransport.reset(transportMode: .nativePackets)
        navigationTransportMode = navigationTransport.transportMode
        log("Disconnected", level: .info)
    }
    
    /// Send command to both glasses
    @discardableResult
    public func sendCommand(_ data: Data, to side: GlassesSide? = nil) -> Bool {
        guard let glasses = connectedGlasses else {
            log("Cannot send: Not connected", level: .warning)
            return false
        }
        
        let sendToLeft = side == nil || side == .left
        let sendToRight = side == nil || side == .right
        
        var accepted = true
        if sendToLeft {
            accepted = write(data, to: glasses.leftPeripheral, using: glasses.leftTXCharacteristic, side: .left) && accepted
        }
        if sendToRight {
            accepted = write(data, to: glasses.rightPeripheral, using: glasses.rightTXCharacteristic, side: .right) && accepted
        }
        return accepted
    }
    
    /// Send command and await ACK on one or both sides.
    /// Returns true only if all requested sides ACK within timeout.
    public func sendCommandAwaitAck(_ data: Data,
                                    to side: GlassesSide? = nil,
                                    sequence: UInt8? = nil,
                                    timeoutMs: Int = G1BLEConstants.commandTimeoutMs) async -> Bool {
        guard await ackCommandGate.acquire(), !Task.isCancelled else { return false }
        defer { ackCommandGate.release() }

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
        return byteCount.isMultiple(of: G1LC3Decoder.encodedFrameByteCount)
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
             G1Command.EXIT_ALL.rawValue,
             G1CompatibilityCommand.dashboardVisibility,
             G1CompatibilityCommand.headUpMode,
             G1CompatibilityCommand.headUpModeAlt,
             G1CompatibilityCommand.microphonePrimary,
             G1CompatibilityCommand.microphoneFallback,
             G1CompatibilityCommand.navigationPrimary,
             G1Command.DISPLAY_SETTINGS.rawValue,
             G1Command.WHITELIST.rawValue,
             G1Command.NOTIFICATION.rawValue,
             G1Command.BMP_DATA.rawValue,
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
        Task {
            _ = await sendTextAwaitingCompletion(request)
        }
    }

    /// Send text and return only after the display command gate has serialized the
    /// upload. Callers that follow a text write with another display command need
    /// this ordering guarantee; the fire-and-forget `sendText` cannot provide it
    /// because a later command can win the gate first.
    @discardableResult
    public func sendTextAwaitingCompletion(_ request: G1TextSendRequest) async -> Bool {
        let builder = G1TextPacketBuilder(textHelper: textHelper)
        let packets = builder.buildPackets(for: request)

        if packets.isEmpty {
            log("No text packets to send", level: .warning)
            return false
        }

        guard await displayCommandGate.acquire(), !Task.isCancelled else { return false }
        defer { displayCommandGate.release() }

        guard connectionState == .fullyConnected else {
            log("Cannot send text: Not fully connected", level: .warning)
            return false
        }

        _ = await ensureCustomDisplaySurfaceVisible()

        // Notification and navigation text can contain private content.
        // Retain delivery dimensions without shipping the body remotely.
        log("Sending \(request.mode.displayName) text (characters: \(request.text.count), packets: \(packets.count), ack: \(request.awaitAck))", level: .info)

        for (index, packet) in packets.enumerated() {
            guard !Task.isCancelled else {
                log("Text send cancelled", level: .debug)
                return false
            }

            if request.awaitAck {
                let acked = await sendCommandAwaitAck(packet.data, sequence: nil)
                if !acked {
                    log("Text send stopped after missing ACK (packet \(index + 1)/\(packets.count))", level: .warning)
                    return false
                }
            } else {
                guard sendCommand(packet.data) else {
                    log("Text send stopped because packet \(index + 1)/\(packets.count) could not be queued", level: .warning)
                    return false
                }
            }

            if index < packets.count - 1 {
                do {
                    try await Task.sleep(for: .milliseconds(Int64(clamping: request.interPacketDelayMs)))
                } catch {
                    log("Text send cancelled", level: .debug)
                    return false
                }
            }
        }

        return true
    }

    /// Send a full bitmap frame using BMP upload commands, then finalize with end + CRC.
    @discardableResult
    public func sendBitmap(_ frame: G1BitmapFrame,
                           awaitChunkAck: Bool = false,
                           interPacketDelayMs: UInt64 = 8) async -> Bool {
        guard await displayCommandGate.acquire(), !Task.isCancelled else { return false }
        defer { displayCommandGate.release() }

        beginDisplayTransaction()
        defer { endDisplayTransaction() }

        guard connectionState == .fullyConnected else {
            log("Cannot send bitmap: Not fully connected", level: .warning)
            return false
        }

        _ = await ensureCustomDisplaySurfaceVisible()

        let builder = G1BitmapPacketBuilder()
        let envelope: G1BitmapPacketEnvelope
        do {
            envelope = try builder.buildPackets(for: frame)
        } catch {
            log("Bitmap packet build failed: \(error)", level: .warning)
            return false
        }

        for (index, packet) in envelope.dataPackets.enumerated() {
            if awaitChunkAck {
                let chunkAcked = await sendCommandAwaitAck(
                    packet,
                    sequence: nil,
                    timeoutMs: max(700, G1BLEConstants.commandTimeoutMs)
                )
                if !chunkAcked {
                    log("Bitmap chunk ACK failed (\(index + 1)/\(envelope.dataPackets.count))", level: .warning)
                    return false
                }
            } else {
                guard sendCommand(packet) else {
                    log("Bitmap chunk could not be queued (\(index + 1)/\(envelope.dataPackets.count))", level: .warning)
                    return false
                }
            }

            if index < envelope.dataPackets.count - 1, interPacketDelayMs > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(Int64(clamping: interPacketDelayMs)))
                } catch {
                    log("Bitmap send cancelled", level: .debug)
                    return false
                }
            }
        }

        guard await awaitDrainWriteQueues(timeoutMs: 5_000) else {
            log("Bitmap chunk queues did not drain before finalize", level: .warning)
            return false
        }

        // Core Bluetooth's application queue being empty means writeValue was
        // called, not that the peripheral has consumed the final chunk.
        // Preserve a short firmware settle window before finalization.
        do {
            try await Task.sleep(for: .milliseconds(100))
        } catch {
            return false
        }

        for side in Self.ackSendOrder(for: nil) {
            let endAcked = await sendCommandAwaitAck(
                envelope.endPacket,
                to: side,
                sequence: nil,
                timeoutMs: max(700, G1BLEConstants.commandTimeoutMs)
            )
            guard endAcked else {
                log("Bitmap end packet ACK failed [\(side.rawValue)]", level: .warning)
                return false
            }
        }

        for side in Self.ackSendOrder(for: nil) {
            let crcAcked = await sendCommandAwaitAck(
                envelope.crcPacket,
                to: side,
                sequence: nil,
                timeoutMs: max(700, G1BLEConstants.commandTimeoutMs)
            )
            guard crcAcked else {
                log("Bitmap CRC packet ACK failed [\(side.rawValue)]", level: .warning)
                return false
            }
        }

        log("Bitmap sent (\(frame.width)x\(frame.height), packets: \(envelope.dataPackets.count))", level: .info)
        return true
    }
    
    /// Clear the glasses display
    public func clearDisplay() {
        Task {
            _ = await clearDisplayAwaitingCompletion()
        }
    }

    /// Clear the glasses display and return only after the display command gate
    /// has serialized the operation with any in-flight bitmap upload. Also used
    /// when one feature hands the lens to another so the old frame cannot race
    /// and reappear after the new feature starts.
    @discardableResult
    public func clearDisplayAwaitingCompletion() async -> Bool {
        guard await displayCommandGate.acquire(), !Task.isCancelled else { return false }
        defer { displayCommandGate.release() }

        guard connectionState == .fullyConnected else {
            log("Cannot clear display: Not fully connected", level: .warning)
            return false
        }

        let exitCommand = Data([G1Command.EXIT_ALL.rawValue])
        let acked = await sendCommandAwaitAck(
            exitCommand,
            timeoutMs: max(1_500, G1BLEConstants.commandTimeoutMs)
        )
        if acked {
            log("Display cleared", level: .info)
        } else {
            log("Exit-all command was not acknowledged", level: .warning)
        }
        return acked
    }

    /// Backwards-compatible alias for `clearDisplayAwaitingCompletion()`.
    @discardableResult
    public func clearDisplayAndWait() async -> Bool {
        await clearDisplayAwaitingCompletion()
    }

    /// Configure the vendor notification whitelist on the left arm.
    ///
    /// The official demo routes notification configuration only through the
    /// left BLE peripheral; the glasses firmware coordinates display state.
    @discardableResult
    public func configureNotificationWhitelist(
        _ whitelist: G1NotificationWhitelist,
        retryAttempts: Int = 3
    ) async -> Bool {
        let packets: [Data]
        do {
            packets = try G1NotificationPacketBuilder().buildWhitelistPackets(for: whitelist)
        } catch {
            log("Notification whitelist packet build failed: \(error)", level: .warning)
            return false
        }

        return await sendNotificationPacketTransaction(
            packets,
            label: "Notification whitelist",
            retryAttempts: retryAttempts
        )
    }

    /// Send a vendor-formatted notification to the glasses through the left arm.
    @discardableResult
    public func sendNotification(
        _ notification: G1Notification,
        retryAttempts: Int = 6
    ) async -> Bool {
        _ = await ensureCustomDisplaySurfaceVisible()

        let transportID = notificationTransportID
        notificationTransportID &+= 1

        let packets: [Data]
        do {
            packets = try G1NotificationPacketBuilder().buildNotificationPackets(
                for: notification,
                transportID: transportID
            )
        } catch {
            log("Notification packet build failed: \(error)", level: .warning)
            return false
        }

        return await sendNotificationPacketTransaction(
            packets,
            label: "Notification",
            retryAttempts: retryAttempts
        )
    }
    
    /// Set display brightness (0-100)
    public func setBrightness(_ level: Int, autoMode: Bool = false) {
        // Map 0-100 to 0-41 (G1 brightness range)
        let mappedLevel = min(41, max(0, Int((Double(level) / 100.0) * 41.0)))
        brightnessLevel = min(100, max(0, level))
        isAutoBrightnessEnabled = autoMode
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
        let previousValue = isSilentModeEnabled
        // Reflect the request immediately so a bound toggle does not lag the tap,
        // then roll back if the glasses never acknowledge the command.
        isSilentModeEnabled = enabled
        Task {
            let acked = await sendCommandAwaitAck(
                command,
                timeoutMs: max(1_500, G1BLEConstants.commandTimeoutMs)
            )
            if acked {
                log("Silent mode: \(enabled ? "ON" : "OFF")", level: .info)
            } else {
                isSilentModeEnabled = previousValue
                log("Silent-mode command was not acknowledged", level: .warning)
            }
        }
    }

    /// Configure firmware-assisted dashboard activation via head-up behavior.
    /// Optionally enables app-side fallback on head-up/head-down events.
    public func configureTiltDashboard(_ config: G1TiltDashboardConfig) async -> Bool {
        guard await displayCommandGate.acquire(), !Task.isCancelled else { return false }
        defer { displayCommandGate.release() }

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
        let leftModeAcked = await sendCompatibilityCommand(
            .headUpMode,
            payload: modePayload,
            to: .left,
            sequence: nil,
            timeoutMs: max(700, G1BLEConstants.commandTimeoutMs)
        )
        let rightModeAcked = await sendCompatibilityCommand(
            .headUpMode,
            payload: modePayload,
            to: .right,
            sequence: nil,
            timeoutMs: max(700, G1BLEConstants.commandTimeoutMs)
        )
        let modeAcked = leftModeAcked || rightModeAcked

        if !modeAcked {
            log("Tilt dashboard mode command failed", level: .warning)
        } else {
            if !leftModeAcked {
                log("Tilt mode update did not ACK on LEFT", level: .warning)
            }
            if !rightModeAcked {
                log("Tilt mode update did not ACK on RIGHT", level: .warning)
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

    /// Apply the vendor-documented raster height and eye-distance settings.
    @discardableResult
    public func setDisplayPosition(_ settings: G1DisplayPositionSettings) async -> Bool {
        guard connectionState == .fullyConnected else {
            log("Cannot set display position: Glasses are not fully connected", level: .warning)
            return false
        }

        let sequence = displaySettingsSequence
        displaySettingsSequence &+= 1
        let packet = G1DisplaySettingsPacketBuilder.positionPacket(settings: settings, sequence: sequence)
        let acked = await sendCommandAwaitAck(
            packet,
            sequence: nil,
            timeoutMs: max(700, G1BLEConstants.commandTimeoutMs)
        )

        if acked {
            displayPositionSettings = settings
            log("Display position set: height \(settings.height), distance \(settings.distance)", level: .info)
        } else {
            log("Display position command failed", level: .warning)
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

    /// Update visibility state for in-app navigation overlay.
    public func setNavigationOverlayVisible(_ visible: Bool) {
        isNavigationOverlayVisible = visible
    }

    public func setNavigationSessionState(_ state: G1NavigationSessionState) {
        navigationSessionState = state
    }

    /// Declare whether an app feature currently owns the custom display surface.
    public func setCustomDisplaySurfaceClaimed(_ claimed: Bool) {
        guard isCustomDisplaySurfaceClaimed != claimed else { return }
        isCustomDisplaySurfaceClaimed = claimed
    }

    /// Toggle navigation guidance mute state and return the new value.
    @discardableResult
    public func toggleNavigationMute() -> Bool {
        isNavigationMuted.toggle()
        return isNavigationMuted
    }

    /// Set active navigation mode on glasses.
    @discardableResult
    public func setNavigationMode(_ mode: G1NavigationMode) async -> Bool {
        guard await navigationCommandGate.acquire(), !Task.isCancelled else { return false }
        defer { navigationCommandGate.release() }
        return await setNavigationModeWhileLocked(mode)
    }

    private func setNavigationModeWhileLocked(_ mode: G1NavigationMode) async -> Bool {
        guard connectionState == .fullyConnected else {
            log("Cannot set navigation mode: Glasses are not fully connected", level: .warning)
            return false
        }

        navigationMode = mode
        let packet = G1NavigationPacketBuilder.modePacket(mode: mode)
        var transport = navigationTransport
        let result = await transport.performNativePreferred(
            nativeSend: {
                await self.sendNavigationNativePacket(
                    packet,
                    mode: mode,
                    progress: self.lastNavigationProgress,
                    note: "set_mode"
                )
            },
            fallbackSend: {
                self.sendText("NAV \(mode.shortLabel)")
            }
        )
        guard connectionState == .fullyConnected else { return false }
        navigationTransport = transport
        navigationTransportMode = navigationTransport.transportMode
        if result.downgradedToText {
            log("Navigation transport downgraded to text fallback", level: .warning)
        }
        return result.nativeAcked || result.deliveryMode == .textFallback
    }

    /// Start a navigation session.
    @discardableResult
    public func startNavigationSession(mode: G1NavigationMode,
                                       initialInstruction: G1NavigationInstruction? = nil) async -> Bool {
        guard await navigationCommandGate.acquire(), !Task.isCancelled else { return false }
        defer { navigationCommandGate.release() }

        guard connectionState == .fullyConnected else {
            log("Cannot start navigation transport: Glasses are not fully connected", level: .warning)
            navigationSessionState = .inactive
            return false
        }

        navigationMode = mode
        navigationSessionState = .active
        isNavigationMuted = false
        isNavigationOverlayVisible = true
        lastNavigationProgress = nil
        lastNavigationInstruction = nil
        navigationTransport.reset(transportMode: .nativePackets)
        navigationTransportMode = navigationTransport.transportMode

        guard await setNavigationModeWhileLocked(mode), connectionState == .fullyConnected else {
            navigationSessionState = .inactive
            return false
        }

        let startPacket = G1NavigationPacketBuilder.startPacket(mode: mode)
        var transport = navigationTransport
        let startResult = await transport.performNativePreferred(
            nativeSend: {
                await self.sendNavigationNativePacket(startPacket, mode: mode, progress: nil, note: "start_session")
            },
            fallbackSend: {
                self.sendText("Start \(mode.displayName) navigation")
            }
        )
        guard connectionState == .fullyConnected else {
            navigationSessionState = .inactive
            return false
        }
        navigationTransport = transport
        navigationTransportMode = navigationTransport.transportMode

        if let initialInstruction {
            _ = await sendNavigationInstructionWhileLocked(initialInstruction)
        }

        return startResult.nativeAcked || startResult.deliveryMode == .textFallback
    }

    /// Push updated route progress to glasses.
    @discardableResult
    public func updateNavigationSession(progress: G1NavigationProgress) async -> Bool {
        guard await navigationCommandGate.acquire(), !Task.isCancelled else { return false }
        defer { navigationCommandGate.release() }

        guard connectionState == .fullyConnected else {
            return false
        }

        navigationSessionState = .active
        lastNavigationProgress = progress

        let nativePacket: Data?
        do {
            nativePacket = try G1NavigationPacketBuilder.progressPacket(progress)
        } catch {
            nativePacket = nil
        }

        guard let nativePacket else {
            navigationTransport.forceTextFallback()
            navigationTransportMode = navigationTransport.transportMode
            sendText(G1NavigationPacketBuilder.fallbackSummaryText(mode: navigationMode, progress: progress))
            return true
        }

        var transport = navigationTransport
        let result = await transport.performNativePreferred(
            nativeSend: {
                await self.sendNavigationNativePacket(nativePacket, mode: self.navigationMode, progress: progress, note: "progress")
            },
            fallbackSend: {
                self.sendText(G1NavigationPacketBuilder.fallbackSummaryText(mode: self.navigationMode, progress: progress))
            }
        )
        guard connectionState == .fullyConnected else { return false }
        navigationTransport = transport
        navigationTransportMode = navigationTransport.transportMode
        if result.downgradedToText {
            log("Navigation progress switched to text fallback", level: .warning)
        }
        return result.nativeAcked || result.deliveryMode == .textFallback
    }

    /// Send the current maneuver instruction to glasses.
    @discardableResult
    public func sendNavigationInstruction(_ instruction: G1NavigationInstruction) async -> Bool {
        guard await navigationCommandGate.acquire(), !Task.isCancelled else { return false }
        defer { navigationCommandGate.release() }
        return await sendNavigationInstructionWhileLocked(instruction)
    }

    private func sendNavigationInstructionWhileLocked(_ instruction: G1NavigationInstruction) async -> Bool {
        guard connectionState == .fullyConnected else {
            return false
        }

        lastNavigationInstruction = instruction

        let nativePacket: Data?
        do {
            nativePacket = try G1NavigationPacketBuilder.instructionPacket(instruction)
        } catch {
            nativePacket = nil
        }

        guard let nativePacket else {
            navigationTransport.forceTextFallback()
            navigationTransportMode = navigationTransport.transportMode
            sendText(instruction.fallbackText())
            return true
        }

        let progress = G1NavigationProgress(
            stepIndex: instruction.stepIndex,
            totalSteps: instruction.totalSteps,
            remainingDistanceMeters: instruction.remainingDistanceMeters,
            remainingDurationSeconds: max(0, (instruction.etaEpochSeconds ?? 0) - Int(Date().timeIntervalSince1970)),
            etaEpochSeconds: instruction.etaEpochSeconds
        )
        lastNavigationProgress = progress

        var transport = navigationTransport
        let result = await transport.performNativePreferred(
            nativeSend: {
                await self.sendNavigationNativePacket(nativePacket, mode: self.navigationMode, progress: progress, note: "instruction")
            },
            fallbackSend: {
                self.sendText(instruction.fallbackText())
            }
        )
        guard connectionState == .fullyConnected else { return false }
        navigationTransport = transport
        navigationTransportMode = navigationTransport.transportMode
        if result.downgradedToText {
            log("Navigation instruction switched to text fallback", level: .warning)
        }
        return result.nativeAcked || result.deliveryMode == .textFallback
    }

    /// End the current navigation session.
    @discardableResult
    public func stopNavigationSession(sendSummary: Bool = true) async -> Bool {
        guard await navigationCommandGate.acquire(), !Task.isCancelled else { return false }
        defer { navigationCommandGate.release() }

        guard connectionState == .fullyConnected else {
            navigationSessionState = .inactive
            lastNavigationInstruction = nil
            lastNavigationProgress = nil
            navigationTransport.reset(transportMode: .nativePackets)
            navigationTransportMode = navigationTransport.transportMode
            return false
        }

        let endPacket = G1NavigationPacketBuilder.endPacket()
        var transport = navigationTransport
        let result = await transport.performNativePreferred(
            nativeSend: {
                await self.sendNavigationNativePacket(endPacket, mode: self.navigationMode, progress: self.lastNavigationProgress, note: "end_session")
            },
            fallbackSend: {
                if sendSummary {
                    self.sendText("Navigation ended")
                }
            }
        )
        navigationTransport = transport
        navigationSessionState = .inactive
        lastNavigationInstruction = nil
        lastNavigationProgress = nil
        isNavigationOverlayVisible = true
        navigationTransport.reset(transportMode: .nativePackets)
        navigationTransportMode = navigationTransport.transportMode
        return result.nativeAcked || result.deliveryMode == .textFallback
    }

    public func clearNavigationTrace() {
        navigationTraceEntries.removeAll()
    }

    public func exportNavigationTraceJSONL() -> String {
        G1NavigationTraceExporter.jsonLines(newestFirst: navigationTraceEntries)
    }
    
    /// Clear diagnostics buffers and navigation trace.
    public func clearLogs() {
        diagnostics.clearAll()
        navigationTraceEntries.removeAll()
    }
    
    /// Whether a previously connected pair is stored and can be reconnected without a scan.
    public var hasRememberedGlasses: Bool {
        UserDefaults.standard.string(forKey: Self.lastLeftUUIDKey) != nil &&
        UserDefaults.standard.string(forKey: Self.lastRightUUIDKey) != nil &&
        UserDefaults.standard.string(forKey: Self.lastChannelKey) != nil
    }

    /// Reconnect to the remembered pair if there is one, otherwise scan.
    /// This is the single entry point the UI needs for "get me connected".
    public func connectToPreferredGlasses() {
        if hasRememberedGlasses {
            reconnectToLastKnown()
        } else {
            startScanning()
        }
    }

    /// Try to reconnect to last known glasses
    public func reconnectToLastKnown() {
        if !isReconnecting {
            reconnectionAttempts = 0
        }
        isReconnecting = true

        guard centralManager.state == .poweredOn else {
            shouldReconnectAfterCentralRecovery = true
            log("Reconnect deferred until Bluetooth is powered on", level: .warning)
            return
        }

        guard let leftUUIDString = UserDefaults.standard.string(forKey: Self.lastLeftUUIDKey),
              let rightUUIDString = UserDefaults.standard.string(forKey: Self.lastRightUUIDKey),
              let leftUUID = UUID(uuidString: leftUUIDString),
              let rightUUID = UUID(uuidString: rightUUIDString),
              let channel = UserDefaults.standard.string(forKey: Self.lastChannelKey) else {
            isReconnecting = false
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
            beginScanning(forReconnection: true)
        }
    }

    // MARK: - Private Methods

    private enum CompatibilityCommand: String {
        case brightness
        case headUpMode
        case dashboardVisibility
        case microphoneControl
    }

    /// Ensures custom text, notification, and bitmap content is not written to
    /// a firmware-hidden display surface. `0x07 00` persists independently of
    /// successful payload ACKs, so an upload may succeed while remaining blank.
    @discardableResult
    private func ensureCustomDisplaySurfaceVisible() async -> Bool {
        guard connectionState == .fullyConnected else {
            return false
        }

        guard !isDashboardVisible else {
            return true
        }

        let visible = await setDashboardVisible(true)
        if visible {
            try? await Task.sleep(for: .milliseconds(50))
        } else {
            log("Could not enable custom display surface", level: .warning)
        }
        return visible
    }

    private func sendNotificationPacketTransaction(
        _ packets: [Data],
        label: String,
        retryAttempts: Int
    ) async -> Bool {
        guard await displayCommandGate.acquire(), !Task.isCancelled else { return false }
        defer { displayCommandGate.release() }

        guard connectionState == .fullyConnected else {
            log("Cannot send \(label.lowercased()): Not fully connected", level: .warning)
            return false
        }

        let attempts = max(1, retryAttempts)
        for attempt in 1...attempts {
            var transactionSucceeded = true

            for packet in packets {
                guard !Task.isCancelled else { return false }
                let acked = await sendCommandAwaitAck(
                    packet,
                    to: .left,
                    sequence: nil,
                    timeoutMs: max(1_000, G1BLEConstants.commandTimeoutMs)
                )
                if !acked {
                    transactionSucceeded = false
                    break
                }
            }

            if transactionSucceeded {
                log("\(label) sent (packets: \(packets.count))", level: .success)
                return true
            }

            if attempt < attempts {
                do {
                    try await Task.sleep(for: .milliseconds(75))
                } catch {
                    return false
                }
            }
        }

        log("\(label) failed after \(attempts) attempt(s)", level: .warning)
        return false
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

    private func sendNavigationNativePacket(_ packet: Data,
                                            mode: G1NavigationMode?,
                                            progress: G1NavigationProgress?,
                                            note: String?) async -> Bool {
        let acked = await sendCommandAwaitAck(
            packet,
            to: nil,
            sequence: nil,
            timeoutMs: max(700, G1BLEConstants.commandTimeoutMs)
        )

        addNavigationTrace(
            direction: .tx,
            command: packet.first ?? G1CompatibilityCommand.navigationPrimary,
            payload: Data(packet.dropFirst()),
            mode: mode,
            progress: progress,
            note: note.flatMap { acked ? $0 : "\($0)_nack" }
        )

        return acked
    }

    private func addNavigationTrace(direction: G1NavigationTraceDirection,
                                    command: UInt8,
                                    payload: Data,
                                    mode: G1NavigationMode?,
                                    progress: G1NavigationProgress?,
                                    note: String?) {
        let payloadHex = payload.map { String(format: "%02X", $0) }.joined(separator: " ")
        let entry = G1NavigationTraceEntry(
            timestamp: Date(),
            direction: direction,
            command: command,
            payloadHex: payloadHex,
            mode: mode,
            transportMode: navigationTransportMode,
            stepIndex: progress?.stepIndex,
            totalSteps: progress?.totalSteps,
            remainingDistanceMeters: progress?.remainingDistanceMeters,
            etaEpochSeconds: progress?.etaEpochSeconds,
            note: note
        )

        navigationTraceEntries.insert(entry, at: 0)
        if navigationTraceEntries.count > 800 {
            navigationTraceEntries.removeLast(navigationTraceEntries.count - 800)
        }
    }
    
    @discardableResult
    private func write(_ data: Data,
                       to peripheral: CBPeripheral?,
                       using characteristic: CBCharacteristic?,
                       side: GlassesSide) -> Bool {
        enqueueWrite(
            data,
            to: peripheral,
            using: characteristic,
            side: side,
            logPrefix: "TX"
        )
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
            let accepted = enqueueWrite(
                data,
                to: peripheral,
                using: characteristic,
                side: side,
                logPrefix: "TX+ACK",
                prepareForWrite: { [weak self] in
                    guard let self else {
                        continuation.resume(returning: false)
                        return
                    }

                    // Install the waiter immediately before writeValue so a fast
                    // response cannot race ahead of ACK registration.
                    if let existing = self.pendingAcks.removeValue(forKey: ackKey) {
                        existing.timeoutTask.cancel()
                        existing.continuation.resume(returning: false)
                    }

                    let timeoutTask = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(max(1, timeoutMs)))
                        guard let self else { return }
                        if let expired = self.pendingAcks.removeValue(forKey: ackKey) {
                            expired.continuation.resume(returning: false)
                            self.log("ACK timeout [\(side.rawValue)] cmd=0x\(String(format: "%02X", command))", level: .warning)
                        }
                    }

                    self.pendingAcks[ackKey] = PendingAck(
                        timeoutTask: timeoutTask,
                        continuation: continuation
                    )
                },
                failBeforeWrite: {
                    continuation.resume(returning: false)
                }
            )

            if !accepted {
                continuation.resume(returning: false)
            }
        }
    }

    /// Enqueues one complete G1 protocol packet and drains it only while Core
    /// Bluetooth reports available write-without-response capacity.
    @discardableResult
    private func enqueueWrite(_ data: Data,
                              to peripheral: CBPeripheral?,
                              using characteristic: CBCharacteristic?,
                              side: GlassesSide,
                              logPrefix: String,
                              prepareForWrite: (() -> Void)? = nil,
                              failBeforeWrite: (() -> Void)? = nil) -> Bool {
        guard !data.isEmpty else {
            log("Write failed [\(side.rawValue)]: Empty packet", level: .warning)
            return false
        }

        guard let peripheral, let characteristic else {
            log("Write failed [\(side.rawValue)]: No peripheral or characteristic", level: .warning)
            return false
        }

        guard peripheral.state == .connected else {
            log("Write failed [\(side.rawValue)]: Peripheral is not connected", level: .warning)
            return false
        }

        guard characteristic.properties.contains(.writeWithoutResponse) else {
            log("Write failed [\(side.rawValue)]: TX characteristic does not support write without response", level: .error)
            return false
        }

        let maximumLength = peripheral.maximumWriteValueLength(for: .withoutResponse)
        guard Self.isValidWriteLength(data.count, maximumWriteLength: maximumLength) else {
            log(
                "Write failed [\(side.rawValue)]: Packet is \(data.count) bytes, negotiated maximum is \(maximumLength)",
                level: .error
            )
            return false
        }

        let pending = PendingWrite(
            peripheralIdentifier: peripheral.identifier,
            data: data,
            side: side,
            logPrefix: logPrefix,
            prepareForWrite: prepareForWrite,
            failBeforeWrite: failBeforeWrite
        )

        let queuedCount = pendingWrites[side]?.count ?? 0
        guard queuedCount < Self.maxPendingWritesPerSide else {
            log("Write failed [\(side.rawValue)]: BLE queue reached \(Self.maxPendingWritesPerSide) packets", level: .error)
            return false
        }

        pendingWrites[side, default: PendingWriteQueue()].append(pending)
        drainWriteQueue(for: side)
        return true
    }

    private func drainWriteQueue(for side: GlassesSide) {
        guard let glasses = connectedGlasses,
              let peripheral = glasses.peripheral(for: side),
              let characteristic = glasses.txCharacteristic(for: side) else {
            failQueuedWrites(for: side)
            return
        }

        while peripheral.canSendWriteWithoutResponse,
              let pending = pendingWrites[side]?.popFirst() {

            guard pending.peripheralIdentifier == peripheral.identifier,
                  peripheral.state == .connected else {
                pending.failBeforeWrite?()
                continue
            }

            pending.prepareForWrite?()
            peripheral.writeValue(pending.data, for: characteristic, type: .withoutResponse)

            if pending.data.first != G1Command.HEARTBEAT.rawValue {
                let hex = pending.data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
                log(
                    "\(pending.logPrefix) [\(side.rawValue)]: \(hex)\(pending.data.count > 8 ? "..." : "")",
                    level: .debug
                )
            }
        }
    }

    private func failQueuedWrites(for side: GlassesSide) {
        let queued = pendingWrites[side]?.removeAll() ?? []
        for pending in queued {
            pending.failBeforeWrite?()
        }
    }

    private func failAllQueuedWrites() {
        failQueuedWrites(for: .left)
        failQueuedWrites(for: .right)
    }

    private func beginDisplayTransaction() {
        displayTransactionDepth += 1
        if displayTransactionDepth == 1 {
            heartbeatTask?.cancel()
            heartbeatTask = nil
            missedHeartbeatAcks = 0
        }
    }

    private func endDisplayTransaction() {
        guard displayTransactionDepth > 0 else { return }
        displayTransactionDepth -= 1
        if displayTransactionDepth == 0, connectionState == .fullyConnected {
            startHeartbeat()
        }
    }

    private func awaitDrainWriteQueues(timeoutMs: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(max(1, timeoutMs)) / 1_000)
        while Date() < deadline {
            if Task.isCancelled {
                return false
            }

            let leftPending = pendingWrites[.left]?.count ?? 0
            let rightPending = pendingWrites[.right]?.count ?? 0
            if leftPending == 0, rightPending == 0 {
                return true
            }

            try? await Task.sleep(for: .milliseconds(5))
        }

        let leftPending = pendingWrites[.left]?.count ?? 0
        let rightPending = pendingWrites[.right]?.count ?? 0
        log(
            "Write queue drain timed out (L: \(leftPending), R: \(rightPending))",
            level: .warning
        )
        return false
    }

    nonisolated static func isValidWriteLength(_ byteCount: Int, maximumWriteLength: Int) -> Bool {
        byteCount > 0 && maximumWriteLength > 0 && byteCount <= maximumWriteLength
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

        diagnostics.appendLog(entry)
        
        // Also log to system
        logger.log("\(level.rawValue) \(message)")

        // The emoji stays out of the remote message so Datadog can group on it.
        DatadogTelemetryService.shared.log(
            level.telemetryLevel,
            message,
            attributes: ["component": "bluetooth"]
        )
        if level == .error {
            DatadogTelemetryService.shared.trackError(
                message: message,
                type: "BluetoothError",
                attributes: ["component": "bluetooth"]
            )
        }
    }
    
    private func addEvent(_ event: G1Event) {
        diagnostics.appendEvent(event)
        glassesEvents.notify(event)
    }
    
    private func addFrame(_ frame: G1Frame) {
        diagnostics.appendFrame(frame)
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
              let services = peripheral.services,
              let side = sideForPeripheral(peripheral) else { return }

        guard let uartService = services.first(where: { $0.uuid == G1BLEConstants.uartServiceUUID }) else {
            failPeripheralSetup(peripheral, message: "UART service not found")
            return
        }

        glasses.setState(.discoveringCharacteristics, for: side)
        peripheral.discoverCharacteristics(
            [G1BLEConstants.uartTXCharacteristicUUID, G1BLEConstants.uartRXCharacteristicUUID],
            for: uartService
        )
    }
    
    private func handleCharacteristicsDiscovered(_ peripheral: CBPeripheral, service: CBService) {
        guard let glasses = connectedGlasses,
              let characteristics = service.characteristics,
              let side = sideForPeripheral(peripheral) else { return }

        guard let rxCharacteristic = characteristics.first(where: {
            $0.uuid == G1BLEConstants.uartRXCharacteristicUUID
        }), let txCharacteristic = characteristics.first(where: {
            $0.uuid == G1BLEConstants.uartTXCharacteristicUUID
        }) else {
            failPeripheralSetup(peripheral, message: "UART RX/TX characteristics not found")
            return
        }

        guard txCharacteristic.properties.contains(.writeWithoutResponse) else {
            failPeripheralSetup(peripheral, message: "UART TX does not support write without response")
            return
        }

        switch side {
        case .left:
            glasses.leftTXCharacteristic = txCharacteristic
        case .right:
            glasses.rightTXCharacteristic = txCharacteristic
        }
        log("Found TX characteristic [\(side.rawValue)]", level: .debug)

        peripheral.setNotifyValue(true, for: rxCharacteristic)
        glasses.setState(.enablingNotifications, for: side)
        log("Subscribing to RX notifications [\(side.rawValue)]", level: .debug)
    }
    
    private func handleNotificationsEnabled(_ peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard let glasses = connectedGlasses,
              characteristic.uuid == G1BLEConstants.uartRXCharacteristicUUID,
              let side = sideForPeripheral(peripheral) else { return }
        
        glasses.setState(.initializing, for: side)
        
        log("RX notifications enabled [\(side.rawValue)], sending init...", level: .info)
        
        // Send init command: 0x4D 0x01 and bound the initialization phase.
        let initData = Data([G1Command.INIT.rawValue, 0x01])
        Task { [weak self] in
            guard let self else { return }
            let acked = await self.sendCommandAwaitAck(
                initData,
                to: side,
                sequence: nil,
                timeoutMs: max(1_500, G1BLEConstants.commandTimeoutMs)
            )

            guard self.connectedGlasses?.peripheral(for: side)?.identifier == peripheral.identifier,
                  self.connectedGlasses?.state(for: side) == .initializing else {
                return
            }

            if acked {
                self.handleInitAck(side: side)
            } else {
                self.failPeripheralSetup(peripheral, message: "Initialization ACK timed out")
            }
        }
    }

    private func failPeripheralSetup(_ peripheral: CBPeripheral, message: String) {
        guard let glasses = connectedGlasses,
              let side = sideForPeripheral(peripheral) else {
            log("Peripheral setup failed: \(message)", level: .error)
            return
        }

        glasses.setState(.error(message), for: side)
        cancelPendingAcks(for: side)
        failQueuedWrites(for: side)
        updateConnectionState()
        log("Setup failed [\(side.rawValue)]: \(message)", level: .error)
        centralManager.cancelPeripheralConnection(peripheral)
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
        DatadogTelemetryService.shared.trackHardwareEvent(
            name: "connection",
            state: "connected"
        )
        stopReconnectionTimer()
        reconnectionAttempts = 0
        isReconnecting = false
        
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
        guard let side = sideForPeripheral(peripheral) else {
            log("Ignoring data from an unknown peripheral", level: .warning)
            return
        }
        let frame = frameParser.parseFrame(data: data, side: side)
        routeAckIfNeeded(frame, side: side)

        if navigationSessionState != .inactive,
           frame.commandByte == G1CompatibilityCommand.navigationPrimary {
            addNavigationTrace(
                direction: .rx,
                command: frame.commandByte,
                payload: frame.payload,
                mode: navigationMode,
                progress: lastNavigationProgress,
                note: "rx_\(side.rawValue.lowercased())"
            )
        }

        if frame.commandByte == G1Command.MIC_DATA.rawValue {
            handleMicrophoneFrame(frame)
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
                    objectWillChange.send()
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
        // Navigation uses head-up/down to swap its custom map bitmap. The stock
        // dashboard shares the display surface and would cover that bitmap, so
        // navigation has exclusive ownership of tilt events for the session.
        guard navigationSessionState == .inactive else {
            return
        }

        // Same reasoning for any other feature drawing its own content, such as
        // the notification mirror showing an icon or a message being read.
        guard !isCustomDisplaySurfaceClaimed else {
            return
        }

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
        guard let glasses = connectedGlasses,
              let side = sideForPeripheral(peripheral) else { return }
        
        glasses.setState(.disconnected, for: side)
        stopHeartbeat()
        cancelPendingAcks(for: side)
        failQueuedWrites(for: side)
        
        if let error = error {
            log("Disconnected [\(side.rawValue)] with error: \(error.localizedDescription)", level: .error)
        } else {
            log("Disconnected [\(side.rawValue)]", level: .warning)
        }

        if activeMicrophoneSide == side {
            activeMicrophoneSide = nil
            microphoneState = .failed("Active microphone side disconnected")
        }

        if navigationSessionState != .inactive {
            navigationSessionState = .inactive
            navigationTransport.reset(transportMode: .nativePackets)
            navigationTransportMode = navigationTransport.transportMode
        }
        
        updateConnectionState()
        DatadogTelemetryService.shared.trackHardwareEvent(
            name: "connection",
            state: "disconnected",
            attributes: [
                "glasses.side": side.rawValue,
                "connection.unexpected": !isIntentionalDisconnect,
                "connection.has_error": error != nil
            ]
        )
        
        // Attempt reconnection if not intentional
        if !isIntentionalDisconnect && autoReconnect {
            startReconnectionTimer()
        }
    }

    private func handlePeripheralConnectionFailure(_ peripheral: CBPeripheral, error: Error?) {
        guard let glasses = connectedGlasses,
              let side = sideForPeripheral(peripheral) else {
            log(
                "Failed to connect to \(peripheral.name ?? "Unknown"): \(error?.localizedDescription ?? "Unknown error")",
                level: .error
            )
            return
        }

        glasses.setState(.disconnected, for: side)
        cancelPendingAcks(for: side)
        failQueuedWrites(for: side)
        updateConnectionState()
        log(
            "Failed to connect [\(side.rawValue)]: \(error?.localizedDescription ?? "Unknown error")",
            level: .error
        )

        if !isIntentionalDisconnect && autoReconnect {
            startReconnectionTimer()
        }
    }

    private func handleCentralStateUpdate(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            log("Bluetooth powered on", level: .success)
            if shouldReconnectAfterCentralRecovery, autoReconnect, !isIntentionalDisconnect {
                shouldReconnectAfterCentralRecovery = false
                startReconnectionTimer()
            } else if !hasAttemptedLaunchReconnect,
                      autoReconnect,
                      !isIntentionalDisconnect,
                      connectedGlasses == nil,
                      hasRememberedGlasses {
                // Radio readiness is the earliest safe moment to restore the last
                // pair, so the app is connected before the user opens it.
                hasAttemptedLaunchReconnect = true
                log("Restoring last known glasses on launch", level: .info)
                reconnectToLastKnown()
            }

        case .poweredOff, .resetting:
            log(state == .poweredOff ? "Bluetooth powered off" : "Bluetooth resetting", level: .warning)
            shouldReconnectAfterCentralRecovery = connectedGlasses != nil && autoReconnect && !isIntentionalDisconnect
            isScanning = false
            stopHeartbeat()
            cancelAllPendingAcks()
            failAllQueuedWrites()
            connectedGlasses?.leftState = .disconnected
            connectedGlasses?.rightState = .disconnected
            connectionState = .disconnected

        case .unauthorized:
            log("Bluetooth unauthorized", level: .error)
            shouldReconnectAfterCentralRecovery = false
            isScanning = false
            stopHeartbeat()
            cancelAllPendingAcks()
            failAllQueuedWrites()
            connectionState = .disconnected

        case .unsupported:
            log("Bluetooth unsupported", level: .error)
            shouldReconnectAfterCentralRecovery = false
            isScanning = false
            stopHeartbeat()
            cancelAllPendingAcks()
            failAllQueuedWrites()
            connectionState = .disconnected

        case .unknown:
            log("Bluetooth state unknown", level: .warning)

        @unknown default:
            log("Bluetooth state: \(state.rawValue)", level: .warning)
        }
    }
    
    private func updateConnectionState() {
        guard let glasses = connectedGlasses else {
            connectionState = .disconnected
            return
        }
        connectionState = glasses.overallState
    }
    
    private func sideForPeripheral(_ peripheral: CBPeripheral) -> GlassesSide? {
        if peripheral.identifier == connectedGlasses?.leftPeripheral?.identifier {
            return .left
        }
        if peripheral.identifier == connectedGlasses?.rightPeripheral?.identifier {
            return .right
        }
        return nil
    }
    
    // MARK: - Heartbeat

    private func initialHeartbeatMode() -> HeartbeatMode {
        Self.prefersExtendedHeartbeat(for: protocolMode) ? .extended : .short
    }
    
    private func startHeartbeat() {
        stopHeartbeat()

        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(G1BLEConstants.heartbeatInterval))
                } catch {
                    break
                }
                await self?.sendHeartbeat()
            }
        }
    }
    
    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
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
        guard centralManager.state == .poweredOn else {
            shouldReconnectAfterCentralRecovery = true
            return
        }

        guard reconnectionAttempts < G1BLEConstants.maxReconnectionAttempts else {
            isReconnecting = false
            log("Max reconnection attempts reached", level: .error)
            return
        }

        // Both arms often report the same outage independently. One timer is
        // sufficient and avoids consuming two retry attempts for one event.
        guard reconnectionTask == nil else { return }
        
        reconnectionAttempts += 1
        isReconnecting = true
        log("Scheduling reconnection attempt \(reconnectionAttempts)/\(G1BLEConstants.maxReconnectionAttempts)...", level: .info)
        
        reconnectionTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(G1BLEConstants.reconnectionDelay))
            } catch {
                return
            }
            self?.attemptReconnection()
        }
    }
    
    private func stopReconnectionTimer() {
        reconnectionTask?.cancel()
        reconnectionTask = nil
    }
    
    private func attemptReconnection() {
        stopReconnectionTimer()
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

            if isReconnecting, isScanning,
               let lastChannel = UserDefaults.standard.string(forKey: Self.lastChannelKey),
               pair.channel == lastChannel {
                log("Recovered the last known pair during scan; reconnecting...", level: .info)
                connect(to: pair, forReconnection: true)
            }
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

extension G1BluetoothManager: @preconcurrency CBCentralManagerDelegate {

    /// Core Bluetooth is initialized with a nil delegate queue, so Apple
    /// guarantees these callbacks arrive on the main dispatch queue.
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        handleCentralStateUpdate(central.state)
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let evaluation = Self.evaluateDiscovery(
            localName: Self.advertisedLocalName(from: advertisementData),
            peripheralName: peripheral.name,
            hasUARTService: Self.hasUARTService(in: advertisementData)
        )
        ingestDiscoveredPeripheral(peripheral, evaluation: evaluation)
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        handlePeripheralConnected(peripheral)
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        handlePeripheralDisconnected(peripheral, error: error)
    }
    
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        handlePeripheralConnectionFailure(peripheral, error: error)
    }
}

// MARK: - CBPeripheralDelegate

extension G1BluetoothManager: @preconcurrency CBPeripheralDelegate {
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            failPeripheralSetup(peripheral, message: "Service discovery: \(error.localizedDescription)")
            return
        }
        handleServicesDiscovered(peripheral)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        if let error {
            failPeripheralSetup(peripheral, message: "Characteristic discovery: \(error.localizedDescription)")
            return
        }
        handleCharacteristicsDiscovered(peripheral, service: service)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error {
            failPeripheralSetup(peripheral, message: "Notification subscription: \(error.localizedDescription)")
            return
        }

        if characteristic.isNotifying {
            handleNotificationsEnabled(peripheral, characteristic: characteristic)
        } else if characteristic.uuid == G1BLEConstants.uartRXCharacteristicUUID {
            failPeripheralSetup(peripheral, message: "UART RX notifications were not enabled")
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error {
            let side = sideForPeripheral(peripheral)?.rawValue ?? "?"
            log("Notification error [\(side)]: \(error.localizedDescription)", level: .error)
            return
        }

        guard let data = characteristic.value, !data.isEmpty else { return }
        handleIncomingData(data, from: peripheral)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error {
            let side = sideForPeripheral(peripheral)?.rawValue ?? "?"
            log("Write error [\(side)]: \(error.localizedDescription)", level: .error)
        }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let side = sideForPeripheral(peripheral) else { return }
        drainWriteQueue(for: side)
    }
}
