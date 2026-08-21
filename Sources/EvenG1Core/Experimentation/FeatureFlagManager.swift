import Foundation
#if canImport(DatadogFlags)
import DatadogFlags
#endif

/// Evaluates feature flags from Datadog Feature Flags, local mocks, or caller defaults,
/// and reports exposures to Datadog RUM when the SDK does not do so automatically.
public final class FeatureFlagManager: @unchecked Sendable {
    public static let shared = FeatureFlagManager()

    /// Flags are read from the Bluetooth queue and the main actor, and overridden
    /// from tests, so the backing store is locked.
    private let lock = NSLock()
    private var mockFlags: [String: Any] = [:]

    private init() {}

    /// Register fallback / mock flag values (used for feature overrides, unit tests, or offline development).
    public func setMockFlag(key: String, value: Any) {
        lock.withLock { mockFlags[key] = value }
    }

    /// Clear all registered mock flags.
    public func clearMockFlags() {
        lock.withLock { mockFlags.removeAll() }
    }

    // MARK: - Flag Evaluation Methods

    /// Evaluate a boolean feature flag and track evaluation in Datadog RUM.
    public func boolValue(forKey key: String, defaultValue: Bool = false) -> Bool {
        if let mockValue = mockValue(forKey: key, as: Bool.self) {
            reportExposure(name: key, value: mockValue)
            return mockValue
        }

        #if canImport(DatadogFlags)
        if let client = DatadogTelemetryService.shared.flagsClient {
            return client.getBooleanValue(key: key, defaultValue: defaultValue)
        }
        #endif

        reportExposure(name: key, value: defaultValue)
        return defaultValue
    }

    /// Evaluate a string feature flag variant and track evaluation in Datadog RUM.
    public func stringValue(forKey key: String, defaultValue: String) -> String {
        if let mockValue = mockValue(forKey: key, as: String.self) {
            reportExposure(name: key, value: mockValue)
            return mockValue
        }

        #if canImport(DatadogFlags)
        if let client = DatadogTelemetryService.shared.flagsClient {
            return client.getStringValue(key: key, defaultValue: defaultValue)
        }
        #endif

        reportExposure(name: key, value: defaultValue)
        return defaultValue
    }

    /// Evaluate an integer feature flag and track evaluation in Datadog RUM.
    public func intValue(forKey key: String, defaultValue: Int) -> Int {
        if let mockValue = mockValue(forKey: key, as: Int.self) {
            reportExposure(name: key, value: mockValue)
            return mockValue
        }

        #if canImport(DatadogFlags)
        if let client = DatadogTelemetryService.shared.flagsClient {
            return client.getIntegerValue(key: key, defaultValue: defaultValue)
        }
        #endif

        reportExposure(name: key, value: defaultValue)
        return defaultValue
    }

    /// Evaluate a double / floating-point feature flag and track evaluation in Datadog RUM.
    public func doubleValue(forKey key: String, defaultValue: Double) -> Double {
        if let mockValue = mockValue(forKey: key, as: Double.self) {
            reportExposure(name: key, value: mockValue)
            return mockValue
        }

        #if canImport(DatadogFlags)
        if let client = DatadogTelemetryService.shared.flagsClient {
            return client.getDoubleValue(key: key, defaultValue: defaultValue)
        }
        #endif

        reportExposure(name: key, value: defaultValue)
        return defaultValue
    }

    /// Resolve a flag without reporting it, for callers that report the evaluation
    /// themselves under a different name.
    func resolve<T>(key: String, defaultValue: T) -> T {
        lock.withLock { (mockFlags[key] as? T) ?? defaultValue }
    }

    private func mockValue<T>(forKey key: String, as type: T.Type) -> T? {
        lock.withLock { mockFlags[key] as? T }
    }

    private func reportExposure<T: Encodable>(name: String, value: T) {
        DatadogTelemetryService.shared.trackFeatureFlagEvaluation(name: name, value: value)
    }
}

// MARK: - Property Wrapper

@propertyWrapper
public struct FeatureFlag<T> {
    public let key: String
    public let defaultValue: T

    public init(key: String, defaultValue: T) {
        self.key = key
        self.defaultValue = defaultValue
    }

    public var wrappedValue: T {
        if T.self == Bool.self {
            return FeatureFlagManager.shared.boolValue(forKey: key, defaultValue: (defaultValue as? Bool) ?? false) as! T
        } else if T.self == String.self {
            return FeatureFlagManager.shared.stringValue(forKey: key, defaultValue: (defaultValue as? String) ?? "") as! T
        } else if T.self == Int.self {
            return FeatureFlagManager.shared.intValue(forKey: key, defaultValue: (defaultValue as? Int) ?? 0) as! T
        } else if T.self == Double.self {
            return FeatureFlagManager.shared.doubleValue(forKey: key, defaultValue: (defaultValue as? Double) ?? 0.0) as! T
        }
        return defaultValue
    }
}
