import Foundation
import DatadogRUM

/// Model representing an active experiment and assigned variant.
public struct ExperimentAssignment: Sendable {
    public let experimentKey: String
    public let variant: String
    public let timestamp: Date
}

/// Service managing Datadog Experiments (A/B testing) built on Feature Flags and RUM telemetry.
public final class ExperimentManager: @unchecked Sendable {
    public static let shared = ExperimentManager()
    
    private var activeAssignments: [String: ExperimentAssignment] = [:]
    private var mockAssignments: [String: String] = [:]
    
    private init() {}
    
    /// Set a mock experiment assignment for testing or local debugging.
    public func setMockVariant(experimentKey: String, variant: String) {
        mockAssignments[experimentKey] = variant
    }
    
    /// Clear registered mock experiment variants.
    public func clearMockVariants() {
        mockAssignments.removeAll()
    }
    
    /// Evaluates an experiment variant for the current user session and reports exposure to Datadog RUM.
    /// - Parameters:
    ///   - experimentKey: Unique identifier for the experiment in Datadog.
    ///   - defaultVariant: Default control variant (e.g. "control", "off", "version_a").
    /// - Returns: Assigned experiment variant string (e.g. "control", "variant_b").
    @discardableResult
    public func evaluateExperiment(experimentKey: String, defaultVariant: String = "control") -> String {
        let assignedVariant: String
        if let mock = mockAssignments[experimentKey] {
            assignedVariant = mock
        } else {
            assignedVariant = FeatureFlagManager.shared.stringValue(forKey: experimentKey, defaultValue: defaultVariant)
        }
        
        let assignment = ExperimentAssignment(
            experimentKey: experimentKey,
            variant: assignedVariant,
            timestamp: Date()
        )
        activeAssignments[experimentKey] = assignment
        
        // Report experiment exposure to Datadog RUM
        if DatadogTelemetryService.shared.isInitialized {
            RUMMonitor.shared().addFeatureFlagEvaluation(name: experimentKey, value: assignedVariant)
        }
        
        print("[ExperimentManager] Experiment '\(experimentKey)' evaluated variant: '\(assignedVariant)'")
        return assignedVariant
    }
    
    /// Track a goal conversion or metric event tied to an active experiment in RUM.
    /// - Parameters:
    ///   - experimentKey: Key of the experiment being measured.
    ///   - metricName: Goal or conversion metric name (e.g. "route_completed", "bluetooth_connected").
    ///   - value: Optional quantitative metric value (e.g. latency in ms, item count).
    ///   - extraAttributes: Additional contextual attributes.
    public func trackConversion(
        experimentKey: String,
        metricName: String,
        value: Double? = nil,
        extraAttributes: [String: Encodable] = [:]
    ) {
        let assignedVariant = activeAssignments[experimentKey]?.variant ?? "unknown"
        
        var attributes: [String: Encodable] = extraAttributes
        attributes["experiment.key"] = experimentKey
        attributes["experiment.variant"] = assignedVariant
        attributes["experiment.metric"] = metricName
        if let value = value {
            attributes["experiment.metric_value"] = value
        }
        
        DatadogTelemetryService.shared.trackAction(
            type: .tap,
            name: "experiment_conversion_\(metricName)",
            attributes: attributes
        )
        
        print("[ExperimentManager] Conversion tracked for '\(experimentKey)' (\(assignedVariant)): \(metricName)")
    }
    
    /// Returns current assignment info for an active experiment.
    public func currentAssignment(for experimentKey: String) -> ExperimentAssignment? {
        return activeAssignments[experimentKey]
    }
}
