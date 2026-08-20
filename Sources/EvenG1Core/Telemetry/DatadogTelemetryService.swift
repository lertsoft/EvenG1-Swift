import Foundation
import os.log
import DatadogCore
import DatadogCrashReporting
import DatadogLogs
import DatadogRUM
import DatadogInternal

/// Central service managing Datadog Core, RUM, Logs, and crash reporting initialization and telemetry reporting.
public final class DatadogTelemetryService: @unchecked Sendable {
    public static let shared = DatadogTelemetryService()

    /// Guards the mutable state below. Telemetry is reported from the Bluetooth
    /// queue, URLSession callbacks, and the main actor, so every access is locked.
    private let lock = NSLock()
    private var _isInitialized = false
    private var _setupStarted = false
    private var _config: DatadogConfig?
    private var _logger: DatadogLogs.LoggerProtocol?

    /// SDK lifecycle messages go to unified logging: they describe whether remote
    /// telemetry is available, so they cannot depend on it.
    private let diagnostics = os.Logger(subsystem: "com.eveng1", category: "Telemetry")

    public var isInitialized: Bool { lock.withLock { _isInitialized } }
    public var config: DatadogConfig? { lock.withLock { _config } }

    private init() {}

    /// Initializes Datadog Core, RUM, Logs, and crash reporting with the provided or default configuration.
    public func initialize(config: DatadogConfig = DatadogConfig()) {
        // The lock is released before the SDK calls below. Holding it across them
        // would deadlock if enabling a feature logged back through this service.
        let shouldSetUp: Bool = lock.withLock {
            guard !_setupStarted else { return false }
            _config = config
            guard config.isValid else { return false }
            _setupStarted = true
            return true
        }

        guard shouldSetUp else {
            if lock.withLock({ _setupStarted }) {
                diagnostics.notice("Already initialized.")
            } else {
                diagnostics.warning("Datadog credentials missing or placeholder. Telemetry running in mock mode.")
            }
            return
        }

        let coreConfig = Datadog.Configuration(
            clientToken: config.clientToken,
            env: config.environment,
            site: config.site.sdkValue,
            service: config.service
        )
        Datadog.initialize(
            with: coreConfig,
            trackingConsent: config.trackingConsent.sdkValue
        )

        // Real User Monitoring, including main-thread stalls and watchdog terminations.
        // Crash Reporting supplies stack traces for hangs.
        //
        // `swiftUIViewsPredicate` is deliberately omitted. Automatic SwiftUI view
        // detection does not yet suppress views tracked by the view modifier
        // (dd-sdk-ios RUM-9888), so enabling both reports every screen twice.
        // Views come from `trackDatadogRUMView(name:)` instead, which also gives
        // stable names rather than ones reflected out of SwiftUI internals.
        let rumConfig = RUM.Configuration(
            applicationID: config.applicationID,
            sessionSampleRate: config.sessionSampleRate,
            uiKitViewsPredicate: DefaultUIKitRUMViewsPredicate(),
            uiKitActionsPredicate: DefaultUIKitRUMActionsPredicate(),
            swiftUIActionsPredicate: DefaultSwiftUIRUMActionsPredicate(isLegacyDetectionEnabled: true),
            trackBackgroundEvents: config.trackBackgroundEvents,
            longTaskThreshold: config.longTaskThreshold,
            appHangThreshold: config.appHangThreshold,
            trackWatchdogTerminations: config.trackWatchdogTerminations,
            vitalsUpdateFrequency: config.vitalsUpdateFrequency.sdkValue,
            telemetrySampleRate: config.telemetrySampleRate
        )
        RUM.enable(with: rumConfig)

        Logs.enable()
        let logger = DatadogLogs.Logger.create(
            with: DatadogLogs.Logger.Configuration(
                service: config.service,
                name: "EvenG1",
                networkInfoEnabled: true,
                bundleWithRumEnabled: true,
                remoteSampleRate: config.logsSampleRate,
                remoteLogThreshold: config.logsRemoteThreshold.sdkValue,
                // Callers already mirror to unified logging, so console output
                // here would duplicate every line in Xcode.
                consoleLogFormat: nil
            )
        )

        // Native crashes are persisted by the SDK and uploaded on the next launch.
        CrashReporting.enable()

        lock.withLock {
            _logger = logger
            _isInitialized = true
        }

        diagnostics.notice("Successfully initialized Datadog (RUM + Logs + crash/hang reporting).")
    }

    /// Set user identity and attributes for session correlation in RUM and logs.
    public func setUserInfo(id: String, name: String? = nil, email: String? = nil, extraInfo: [String: Encodable] = [:]) {
        guard isInitialized else { return }
        Datadog.setUserInfo(id: id, name: name, email: email, extraInfo: extraInfo)
    }

    /// Clear user identity on logout.
    public func clearUserInfo() {
        guard isInitialized else { return }
        Datadog.clearUserInfo()
    }

    // MARK: - Logs

    /// Forward a log to Datadog. No-ops in mock mode; callers are expected to keep
    /// their own local logging so nothing is lost when telemetry is unconfigured.
    public func log(
        _ level: TelemetryLogLevel,
        _ message: String,
        error: Error? = nil,
        attributes: [String: Encodable] = [:]
    ) {
        guard let logger = lock.withLock({ _logger }) else { return }
        logger.log(level: level.sdkValue, message: message, error: error, attributes: attributes)
    }

    // MARK: - RUM

    /// Track custom user action or event in RUM.
    public func trackAction(type: TelemetryActionType, name: String, attributes: [String: Encodable] = [:]) {
        guard isInitialized else { return }
        RUMMonitor.shared().addAction(type: type.sdkValue, name: name, attributes: attributes)
    }

    /// Report an error to RUM.
    public func trackError(message: String, type: String? = nil, stack: String? = nil, attributes: [String: Encodable] = [:]) {
        guard isInitialized else { return }
        RUMMonitor.shared().addError(message: message, type: type, stack: stack, source: .source, attributes: attributes)
    }

    /// Report a feature-flag or experiment evaluation so it correlates with the current RUM session.
    public func trackFeatureFlagEvaluation(name: String, value: some Encodable) {
        guard isInitialized else { return }
        RUMMonitor.shared().addFeatureFlagEvaluation(name: name, value: value)
    }

    /// Record a custom performance timing on the active RUM view.
    public func trackTiming(name: String) {
        guard isInitialized else { return }
        RUMMonitor.shared().addTiming(name: name)
    }

    /// Track hardware-specific state (e.g. G1 Bluetooth connection state, battery level).
    public func trackHardwareEvent(name: String, state: String, attributes: [String: Encodable] = [:]) {
        var mergedAttributes = attributes
        mergedAttributes["hardware.state"] = state
        mergedAttributes["device.model"] = "Even Realities G1"
        trackAction(type: .custom, name: "hardware_\(name)", attributes: mergedAttributes)
    }
}

private extension DatadogConfig.Site {
    var sdkValue: DatadogSite {
        switch self {
        case .us1: return .us1
        case .us3: return .us3
        case .us5: return .us5
        case .eu1: return .eu1
        case .ap1: return .ap1
        case .ap2: return .ap2
        case .us1Fed: return .us1_fed
        }
    }
}

private extension DatadogConfig.Consent {
    var sdkValue: TrackingConsent {
        switch self {
        case .granted: return .granted
        case .notGranted: return .notGranted
        case .pending: return .pending
        }
    }
}

private extension TelemetryActionType {
    var sdkValue: RUMActionType {
        switch self {
        case .tap: return .tap
        case .scroll: return .scroll
        case .swipe: return .swipe
        case .custom: return .custom
        }
    }
}

private extension TelemetryLogLevel {
    var sdkValue: LogLevel {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .notice: return .notice
        case .warn: return .warn
        case .error: return .error
        case .critical: return .critical
        }
    }
}

private extension TelemetryVitalsUpdateFrequency {
    var sdkValue: RUM.Configuration.VitalsFrequency? {
        switch self {
        case .frequent: return .frequent
        case .average: return .average
        case .rare: return .rare
        case .disabled: return nil
        }
    }
}
