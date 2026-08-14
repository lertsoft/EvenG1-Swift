import Foundation
import DatadogRUM

/// Manages Datadog Feature Flags evaluation and reports flag evaluations to Datadog RUM.
public final class FeatureFlagManager: @unchecked Sendable {
    public static let shared = FeatureFlagManager()
    
    private var mockFlags: [String: Any] = [:]
    
    private init() {}
    
    /// Register fallback / mock flag values (used for feature overrides, unit tests, or offline development).
    public func setMockFlag(key: String, value: Any) {
        mockFlags[key] = value
    }
    
    /// Clear all registered mock flags.
    public func clearMockFlags() {
        mockFlags.removeAll()
    }
    
    // MARK: - Flag Evaluation Methods
    
    /// Evaluate a boolean feature flag and track evaluation in Datadog RUM.
    public func boolValue(forKey key: String, defaultValue: Bool = false) -> Bool {
        let value = (mockFlags[key] as? Bool) ?? defaultValue
        if DatadogTelemetryService.shared.isInitialized {
            RUMMonitor.shared().addFeatureFlagEvaluation(name: key, value: value)
        }
        return value
    }
    
    /// Evaluate a string feature flag variant and track evaluation in Datadog RUM.
    public func stringValue(forKey key: String, defaultValue: String) -> String {
        let value = (mockFlags[key] as? String) ?? defaultValue
        if DatadogTelemetryService.shared.isInitialized {
            RUMMonitor.shared().addFeatureFlagEvaluation(name: key, value: value)
        }
        return value
    }
    
    /// Evaluate an integer feature flag and track evaluation in Datadog RUM.
    public func intValue(forKey key: String, defaultValue: Int) -> Int {
        let value = (mockFlags[key] as? Int) ?? defaultValue
        if DatadogTelemetryService.shared.isInitialized {
            RUMMonitor.shared().addFeatureFlagEvaluation(name: key, value: value)
        }
        return value
    }
    
    /// Evaluate a double / floating-point feature flag and track evaluation in Datadog RUM.
    public func doubleValue(forKey key: String, defaultValue: Double) -> Double {
        let value = (mockFlags[key] as? Double) ?? defaultValue
        if DatadogTelemetryService.shared.isInitialized {
            RUMMonitor.shared().addFeatureFlagEvaluation(name: key, value: value)
        }
        return value
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
