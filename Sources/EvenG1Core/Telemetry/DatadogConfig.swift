import Foundation
import DatadogCore
import DatadogInternal

/// Configuration settings for Datadog telemetry initialization.
public struct DatadogConfig: @unchecked Sendable {
    public var clientToken: String
    public var applicationID: String
    public var environment: String
    public var site: DatadogSite
    public var sessionSampleRate: Float
    public var telemetrySampleRate: Float
    public var trackBackgroundEvents: Bool
    public var trackWatchdogTerminations: Bool
    public var longTaskThreshold: TimeInterval?
    public var appHangThreshold: TimeInterval?
    public var trackingConsent: TrackingConsent
    
    public init(
        clientToken: String = Bundle.main.object(forInfoDictionaryKey: "DATADOG_CLIENT_TOKEN") as? String ?? "",
        applicationID: String = Bundle.main.object(forInfoDictionaryKey: "DATADOG_APPLICATION_ID") as? String ?? "",
        environment: String = Bundle.main.object(forInfoDictionaryKey: "DATADOG_ENV") as? String ?? "development",
        site: DatadogSite = .us1,
        sessionSampleRate: Float = 100.0,
        telemetrySampleRate: Float = 100.0,
        trackBackgroundEvents: Bool = true,
        trackWatchdogTerminations: Bool = true,
        longTaskThreshold: TimeInterval? = 0.25,
        appHangThreshold: TimeInterval? = 2.0,
        trackingConsent: TrackingConsent = .granted
    ) {
        self.clientToken = clientToken
        self.applicationID = applicationID
        self.environment = environment
        self.site = site
        self.sessionSampleRate = sessionSampleRate
        self.telemetrySampleRate = telemetrySampleRate
        self.trackBackgroundEvents = trackBackgroundEvents
        self.trackWatchdogTerminations = trackWatchdogTerminations
        self.longTaskThreshold = longTaskThreshold
        self.appHangThreshold = appHangThreshold
        self.trackingConsent = trackingConsent
    }
    
    /// Returns true if valid credentials exist for Datadog SDK initialization.
    public var isValid: Bool {
        !clientToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !applicationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
