import Foundation
import DatadogCore
import DatadogCrashReporting
import DatadogRUM
import DatadogInternal

/// Central service managing Datadog Core, RUM, and Feature Flags initialization and telemetry reporting.
public final class DatadogTelemetryService: @unchecked Sendable {
    public static let shared = DatadogTelemetryService()
    
    private(set) public var isInitialized: Bool = false
    private(set) public var config: DatadogConfig?
    
    private init() {}
    
    /// Initializes Datadog Core and RUM telemetry with the provided or default configuration.
    public func initialize(config: DatadogConfig = DatadogConfig()) {
        guard !isInitialized else {
            print("[DatadogTelemetryService] Already initialized.")
            return
        }
        
        self.config = config
        
        guard config.isValid else {
            print("[DatadogTelemetryService] Datadog credentials missing or placeholder. Telemetry running in mock mode.")
            return
        }
        
        // 1. Initialize Datadog Core
        let coreConfig = Datadog.Configuration(
            clientToken: config.clientToken,
            env: config.environment,
            site: config.site
        )
        Datadog.initialize(
            with: coreConfig,
            trackingConsent: config.trackingConsent
        )
        
        // 2. Initialize Real User Monitoring (RUM), including main-thread stalls
        // and watchdog terminations. Crash Reporting supplies stack traces for hangs.
        let rumConfig = RUM.Configuration(
            applicationID: config.applicationID,
            sessionSampleRate: config.sessionSampleRate,
            trackBackgroundEvents: config.trackBackgroundEvents,
            longTaskThreshold: config.longTaskThreshold,
            appHangThreshold: config.appHangThreshold,
            trackWatchdogTerminations: config.trackWatchdogTerminations,
            telemetrySampleRate: config.telemetrySampleRate
        )
        RUM.enable(with: rumConfig)

        // Native crashes are persisted by the SDK and uploaded on the next launch.
        CrashReporting.enable()
        
        isInitialized = true
        print("[DatadogTelemetryService] Successfully initialized Datadog (RUM + crash/hang reporting).")
    }
    
    /// Set user identity and attributes for session correlation in RUM and logs.
    public func setUserInfo(id: String, name: String? = nil, email: String? = nil, extraInfo: [String: Encodable] = [:]) {
        guard isInitialized else { return }
        Datadog.setUserInfo(id: id, name: name, email: email, extraInfo: extraInfo)
    }
    
    /// Clear user identity on logout.
    public func clearUserInfo() {
        guard isInitialized else { return }
        Datadog.setUserInfo(id: "", name: nil, email: nil, extraInfo: [:])
    }
    
    /// Track custom user action or event in RUM.
    public func trackAction(type: RUMActionType, name: String, attributes: [String: Encodable] = [:]) {
        guard isInitialized else { return }
        RUMMonitor.shared().addAction(type: type, name: name, attributes: attributes)
    }
    
    /// Report an error to RUM.
    public func trackError(message: String, type: String? = nil, stack: String? = nil, attributes: [String: Encodable] = [:]) {
        guard isInitialized else { return }
        RUMMonitor.shared().addError(message: message, type: type, stack: stack, source: .source, attributes: attributes)
    }
    
    /// Track hardware-specific state (e.g. G1 Bluetooth connection state, battery level).
    public func trackHardwareEvent(name: String, state: String, attributes: [String: Encodable] = [:]) {
        var mergedAttributes = attributes
        mergedAttributes["hardware.state"] = state
        mergedAttributes["device.model"] = "Even Realities G1"
        trackAction(type: .custom, name: "hardware_\(name)", attributes: mergedAttributes)
    }
}
