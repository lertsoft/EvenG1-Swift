import Foundation

/// Model representing an active experiment and assigned variant.
public struct ExperimentAssignment: Sendable {
    public let experimentKey: String
    public let variant: String
    public let timestamp: Date
}

/// Service managing A/B experiment assignment on top of feature flags, reporting
/// exposures and conversions to Datadog RUM.
public final class ExperimentManager: @unchecked Sendable {
    public static let shared = ExperimentManager()

    private let lock = NSLock()
    private var activeAssignments: [String: ExperimentAssignment] = [:]
    private var mockAssignments: [String: String] = [:]

    private init() {}

    /// Set a mock experiment assignment for testing or local debugging.
    public func setMockVariant(experimentKey: String, variant: String) {
        lock.withLock { mockAssignments[experimentKey] = variant }
    }

    /// Clear registered mock experiment variants.
    public func clearMockVariants() {
        lock.withLock { mockAssignments.removeAll() }
    }

    /// Evaluates an experiment variant for the current user session and reports exposure to Datadog RUM.
    /// - Parameters:
    ///   - experimentKey: Unique identifier for the experiment in Datadog.
    ///   - defaultVariant: Default control variant (e.g. "control", "off", "version_a").
    /// - Returns: Assigned experiment variant string (e.g. "control", "variant_b").
    @discardableResult
    public func evaluateExperiment(experimentKey: String, defaultVariant: String = "control") -> String {
        // Resolved rather than evaluated through `FeatureFlagManager`, which would
        // report the exposure a second time under the same flag name.
        let assignedVariant = lock.withLock { mockAssignments[experimentKey] }
            ?? FeatureFlagManager.shared.resolve(key: experimentKey, defaultValue: defaultVariant)

        let assignment = ExperimentAssignment(
            experimentKey: experimentKey,
            variant: assignedVariant,
            timestamp: Date()
        )
        lock.withLock { activeAssignments[experimentKey] = assignment }

        DatadogTelemetryService.shared.trackFeatureFlagEvaluation(name: experimentKey, value: assignedVariant)

        DatadogTelemetryService.shared.log(
            .debug,
            "Experiment evaluated",
            attributes: [
                "component": "experiments",
                "experiment.key": experimentKey,
                "experiment.variant": assignedVariant
            ]
        )
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
        let assignedVariant = lock.withLock { activeAssignments[experimentKey]?.variant } ?? "unknown"

        var attributes: [String: Encodable] = extraAttributes
        attributes["experiment.key"] = experimentKey
        attributes["experiment.variant"] = assignedVariant
        attributes["experiment.metric"] = metricName
        if let value = value {
            attributes["experiment.metric_value"] = value
        }

        DatadogTelemetryService.shared.trackAction(
            type: .custom,
            name: "experiment_conversion_\(metricName)",
            attributes: attributes
        )

        DatadogTelemetryService.shared.log(
            .debug,
            "Experiment conversion tracked",
            attributes: attributes.merging(["component": "experiments"]) { current, _ in current }
        )
    }

    /// Returns current assignment info for an active experiment.
    public func currentAssignment(for experimentKey: String) -> ExperimentAssignment? {
        lock.withLock { activeAssignments[experimentKey] }
    }
}
