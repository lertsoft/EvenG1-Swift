import Foundation

/// Configuration settings for Datadog telemetry initialization.
public struct DatadogConfig: Sendable {
    public enum Site: Sendable {
        case us1
        case us3
        case us5
        case eu1
        case ap1
        case ap2
        case us1Fed
    }

    public enum Consent: Sendable {
        case granted
        case notGranted
        case pending
    }

    public var clientToken: String
    public var applicationID: String
    public var environment: String
    public var service: String?
    public var site: Site
    public var sessionSampleRate: Float
    public var telemetrySampleRate: Float
    public var trackBackgroundEvents: Bool
    public var trackWatchdogTerminations: Bool
    public var trackAnonymousUser: Bool
    public var trackMemoryWarnings: Bool
    public var longTaskThreshold: TimeInterval?
    public var appHangThreshold: TimeInterval?
    public var vitalsUpdateFrequency: TelemetryVitalsUpdateFrequency
    public var trackingConsent: Consent
    public var logsSampleRate: Float
    public var logsRemoteThreshold: TelemetryLogLevel
    /// When true, enables the Datadog Feature Flags client after RUM initialization.
    public var featureFlagsEnabled: Bool

    public init(
        clientToken: String = DatadogConfig.infoPlistValue(for: "DATADOG_CLIENT_TOKEN") ?? "",
        applicationID: String = DatadogConfig.infoPlistValue(for: "DATADOG_APPLICATION_ID") ?? "",
        environment: String = DatadogConfig.infoPlistValue(for: "DATADOG_ENV") ?? "development",
        service: String? = DatadogConfig.infoPlistValue(for: "DATADOG_SERVICE"),
        site: Site = DatadogConfig.infoPlistValue(for: "DATADOG_SITE").flatMap(Site.init(identifier:)) ?? .us1,
        sessionSampleRate: Float = 100.0,
        telemetrySampleRate: Float = 100.0,
        trackBackgroundEvents: Bool = true,
        trackWatchdogTerminations: Bool = true,
        trackAnonymousUser: Bool = true,
        trackMemoryWarnings: Bool = true,
        longTaskThreshold: TimeInterval? = 0.25,
        appHangThreshold: TimeInterval? = 2.0,
        vitalsUpdateFrequency: TelemetryVitalsUpdateFrequency = .frequent,
        trackingConsent: Consent = .granted,
        logsSampleRate: Float = 100.0,
        logsRemoteThreshold: TelemetryLogLevel = .debug,
        featureFlagsEnabled: Bool = true
    ) {
        self.clientToken = clientToken
        self.applicationID = applicationID
        self.environment = environment
        self.service = service
        self.site = site
        self.sessionSampleRate = sessionSampleRate
        self.telemetrySampleRate = telemetrySampleRate
        self.trackBackgroundEvents = trackBackgroundEvents
        self.trackWatchdogTerminations = trackWatchdogTerminations
        self.trackAnonymousUser = trackAnonymousUser
        self.trackMemoryWarnings = trackMemoryWarnings
        self.longTaskThreshold = longTaskThreshold
        self.appHangThreshold = appHangThreshold
        self.vitalsUpdateFrequency = vitalsUpdateFrequency
        self.trackingConsent = trackingConsent
        self.logsSampleRate = logsSampleRate
        self.logsRemoteThreshold = logsRemoteThreshold
        self.featureFlagsEnabled = featureFlagsEnabled
    }

    /// Reads a build-time Info.plist string, treating blanks and unexpanded
    /// `$(BUILD_SETTING)` placeholders as absent so a partially configured
    /// build falls back to mock mode instead of shipping a bogus credential.
    public static func infoPlistValue(for key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else {
            return nil
        }
        return trimmed
    }

    /// Returns true if valid credentials exist for Datadog SDK initialization.
    public var isValid: Bool {
        DatadogConfig.isUsableCredential(clientToken) && DatadogConfig.isUsableCredential(applicationID)
    }

    private static func isUsableCredential(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("$(")
    }
}

public extension DatadogConfig.Site {
    /// Resolves a site from either a Datadog site identifier (`us5`) or the
    /// organization's web domain (`us5.datadoghq.com`), which is what the
    /// Datadog UI shows and what developers are most likely to copy.
    init?(identifier: String) {
        switch identifier.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "us1", "datadoghq.com", "app.datadoghq.com":
            self = .us1
        case "us3", "us3.datadoghq.com":
            self = .us3
        case "us5", "us5.datadoghq.com":
            self = .us5
        case "eu1", "datadoghq.eu", "app.datadoghq.eu":
            self = .eu1
        case "ap1", "ap1.datadoghq.com":
            self = .ap1
        case "ap2", "ap2.datadoghq.com":
            self = .ap2
        case "us1_fed", "us1fed", "ddog-gov.com":
            self = .us1Fed
        default:
            return nil
        }
    }
}

/// Log severities used by EvenG1Core. Mapped to Datadog `LogLevel` on iOS.
public enum TelemetryLogLevel: Int, Sendable, Comparable {
    case debug
    case info
    case notice
    case warn
    case error
    case critical

    public static func < (lhs: TelemetryLogLevel, rhs: TelemetryLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Mobile vitals sampling cadence for RUM frozen-frame and memory charts.
public enum TelemetryVitalsUpdateFrequency: Sendable {
    case frequent
    case average
    case rare
    case disabled
}

/// RUM action kinds used by EvenG1Core. Mapped to Datadog `RUMActionType` on iOS.
public enum TelemetryActionType: Sendable {
    case tap
    case scroll
    case swipe
    case custom
}
