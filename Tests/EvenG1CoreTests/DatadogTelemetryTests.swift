import XCTest
@testable import EvenG1Core

final class DatadogTelemetryTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        FeatureFlagManager.shared.clearMockFlags()
        ExperimentManager.shared.clearMockVariants()
    }
    
    func testDatadogConfigValidity() {
        let emptyConfig = DatadogConfig(clientToken: "", applicationID: "")
        XCTAssertFalse(emptyConfig.isValid)
        
        let validConfig = DatadogConfig(
            clientToken: "pub_token_12345",
            applicationID: "app_id_67890",
            environment: "staging"
        )
        XCTAssertTrue(validConfig.isValid)
        XCTAssertEqual(validConfig.environment, "staging")
    }

    func testUnexpandedBuildSettingIsNotTreatedAsACredential() {
        let placeholderConfig = DatadogConfig(
            clientToken: "$(DATADOG_CLIENT_TOKEN)",
            applicationID: "$(DATADOG_APPLICATION_ID)"
        )

        XCTAssertFalse(placeholderConfig.isValid)
    }

    func testSiteAcceptsIdentifiersAndOrgDomains() {
        XCTAssertEqual(DatadogConfig.Site(identifier: "us5"), .us5)
        XCTAssertEqual(DatadogConfig.Site(identifier: "us5.datadoghq.com"), .us5)
        XCTAssertEqual(DatadogConfig.Site(identifier: "  EU1  "), .eu1)
        XCTAssertEqual(DatadogConfig.Site(identifier: "datadoghq.eu"), .eu1)
        XCTAssertEqual(DatadogConfig.Site(identifier: "ddog-gov.com"), .us1Fed)
        XCTAssertNil(DatadogConfig.Site(identifier: "us9"))
    }

    func testDefaultSiteIsUS1WhenUnconfigured() {
        XCTAssertEqual(DatadogConfig(clientToken: "token", applicationID: "application").site, .us1)
    }

    func testDiagnosticsAreEnabledByDefault() {
        let config = DatadogConfig(clientToken: "token", applicationID: "application")

        XCTAssertTrue(config.trackWatchdogTerminations)
        XCTAssertTrue(config.trackAnonymousUser)
        XCTAssertTrue(config.trackMemoryWarnings)
        XCTAssertTrue(config.featureFlagsEnabled)
        XCTAssertEqual(config.longTaskThreshold, 0.25)
        XCTAssertEqual(config.appHangThreshold, 2.0)
        XCTAssertEqual(config.vitalsUpdateFrequency, .frequent)
        XCTAssertEqual(config.logsRemoteThreshold, .debug)
    }

    func testTrackTimingDoesNotCrashInMockMode() {
        let service = DatadogTelemetryService.shared
        service.initialize(config: DatadogConfig(clientToken: "", applicationID: ""))
        service.trackTiming(name: "test_timing")
    }
    
    func testDatadogTelemetryServiceInitializationWithMissingTokenDoesNotCrash() {
        let service = DatadogTelemetryService.shared
        service.initialize(config: DatadogConfig(clientToken: "", applicationID: ""))
        XCTAssertFalse(service.isInitialized)
    }
    
    func testFeatureFlagManagerMockEvaluation() {
        FeatureFlagManager.shared.setMockFlag(key: "new_dashboard_enabled", value: true)
        FeatureFlagManager.shared.setMockFlag(key: "audio_sample_rate", value: 16000)
        FeatureFlagManager.shared.setMockFlag(key: "experiment_layout", value: "grid")
        
        XCTAssertTrue(FeatureFlagManager.shared.boolValue(forKey: "new_dashboard_enabled", defaultValue: false))
        XCTAssertEqual(FeatureFlagManager.shared.intValue(forKey: "audio_sample_rate", defaultValue: 8000), 16000)
        XCTAssertEqual(FeatureFlagManager.shared.stringValue(forKey: "experiment_layout", defaultValue: "list"), "grid")
        XCTAssertFalse(FeatureFlagManager.shared.boolValue(forKey: "non_existent_flag", defaultValue: false))
    }

    func testFeatureFlagManagerReturnsDefaultWithoutMockOrRemoteClient() {
        FeatureFlagManager.shared.clearMockFlags()

        XCTAssertFalse(FeatureFlagManager.shared.boolValue(forKey: "missing.bool.flag", defaultValue: false))
        XCTAssertEqual(
            FeatureFlagManager.shared.stringValue(forKey: "missing.string.flag", defaultValue: "fallback"),
            "fallback"
        )
        XCTAssertEqual(FeatureFlagManager.shared.intValue(forKey: "missing.int.flag", defaultValue: 42), 42)
        XCTAssertEqual(FeatureFlagManager.shared.doubleValue(forKey: "missing.double.flag", defaultValue: 1.5), 1.5)
    }

    /// Mirrors the remote-readiness flow: a clean launch evaluates to the default
    /// before assignments load, then re-evaluates to the resolved value once they
    /// arrive (here simulated by registering the value the client would supply).
    func testFeatureFlagManagerReevaluatesWhenValueBecomesAvailable() {
        FeatureFlagManager.shared.clearMockFlags()

        // Before assignments arrive: default is returned.
        XCTAssertTrue(
            FeatureFlagManager.shared.boolValue(
                forKey: EvenG1FeatureFlagKey.headsUpTabEnabled,
                defaultValue: true
            )
        )

        // Assignments arrive (remote client would now serve this value).
        FeatureFlagManager.shared.setMockFlag(key: EvenG1FeatureFlagKey.headsUpTabEnabled, value: false)

        // Re-evaluation reflects the resolved value.
        XCTAssertFalse(
            FeatureFlagManager.shared.boolValue(
                forKey: EvenG1FeatureFlagKey.headsUpTabEnabled,
                defaultValue: true
            )
        )
    }

    func testFeatureFlagsReadyNotificationNameIsStable() {
        XCTAssertEqual(
            Notification.Name.evenG1FeatureFlagsDidBecomeReady.rawValue,
            "com.eveng1.featureFlags.didBecomeReady"
        )
    }
    
    func testExperimentManagerAssignmentAndConversion() {
        ExperimentManager.shared.setMockVariant(experimentKey: "mta_board_exp", variant: "variant_b")
        
        let variant = ExperimentManager.shared.evaluateExperiment(experimentKey: "mta_board_exp", defaultVariant: "control")
        XCTAssertEqual(variant, "variant_b")
        
        let current = ExperimentManager.shared.currentAssignment(for: "mta_board_exp")
        XCTAssertNotNil(current)
        XCTAssertEqual(current?.variant, "variant_b")
        
        // Track conversion without throwing
        ExperimentManager.shared.trackConversion(
            experimentKey: "mta_board_exp",
            metricName: "station_selected",
            value: 1.0,
            extraAttributes: ["station_id": "127"]
        )
    }
}
