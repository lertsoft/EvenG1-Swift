import XCTest

@MainActor
final class EvenG1SwiftUITests: XCTestCase {
    private lazy var app: XCUIApplication = {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()
        return app
    }()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testConnectTabShowsDisconnectedStateAndScanControls() throws {
        XCTAssertTrue(app.navigationBars["Even G1"].waitForExistence(timeout: 5))

        let noGlassesState = element(identifier: "connection.noGlasses")
        XCTAssertTrue(noGlassesState.waitForExistence(timeout: 5))

        let scanButton = app.buttons["connection.scanButton"]
        let reconnectButton = app.buttons["connection.reconnectButton"]

        XCTAssertTrue(scanButton.exists)
        XCTAssertTrue(reconnectButton.exists)
        XCTAssertTrue(scanButton.isEnabled)
        XCTAssertTrue(reconnectButton.isEnabled)
    }

    func testDisplayTabRequiresConnectionAndDisablesPrimaryActions() throws {
        tapTab(named: "Display")

        XCTAssertTrue(app.navigationBars["Display"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["display.connectRequiredLabel"].waitForExistence(timeout: 5))

        let sendButton = app.buttons["display.sendButton"]
        let clearButton = app.buttons["display.clearButton"]

        XCTAssertTrue(sendButton.exists)
        XCTAssertTrue(clearButton.exists)
        XCTAssertFalse(sendButton.isEnabled)
        XCTAssertFalse(clearButton.isEnabled)

        let mtaRefreshButton = element(identifier: "mta.refreshButton")
        let mtaStatusLabel = element(identifier: "mta.statusLabel")

        scrollToElement(mtaStatusLabel, maximumSwipes: 10)
        XCTAssertTrue(mtaStatusLabel.waitForExistence(timeout: 5))
        scrollToElement(mtaRefreshButton, maximumSwipes: 10)
        XCTAssertTrue(mtaRefreshButton.exists)
    }

    func testDisplayTabShowsMTAAutoRefreshToggleAndDefaultStatus() throws {
        tapTab(named: "Display")

        let mtaStatusLabel = element(identifier: "mta.statusLabel")
        let mtaAutoRefreshToggle = element(identifier: "mta.autoRefreshToggle")

        scrollToElement(mtaStatusLabel, maximumSwipes: 10)
        XCTAssertTrue(mtaStatusLabel.waitForExistence(timeout: 5))
        XCTAssertEqual(mtaStatusLabel.label, "No train lookup yet")
        scrollToElement(mtaAutoRefreshToggle, maximumSwipes: 10)
        XCTAssertTrue(mtaAutoRefreshToggle.waitForExistence(timeout: 5))
    }

    func testLogsTabCanSwitchToEventsEmptyState() throws {
        tapTab(named: "Logs")

        XCTAssertTrue(app.navigationBars["Debug"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Debug"].buttons["Clear"].exists)

        let eventsSegment = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Events")).firstMatch
        XCTAssertTrue(eventsSegment.waitForExistence(timeout: 5))
        eventsSegment.tap()

        XCTAssertTrue(element(identifier: "events.emptyState").waitForExistence(timeout: 5))
    }

    func testDisplayPositionControlsArePresentAndRequireConnection() throws {
        tapTab(named: "Display")

        let applyButton = element(identifier: "display.positionApply")
        scrollToElement(applyButton, maximumSwipes: 16)

        XCTAssertTrue(applyButton.waitForExistence(timeout: 5))
        XCTAssertFalse(applyButton.isEnabled)
        XCTAssertTrue(element(identifier: "display.positionEnabled").exists)
        XCTAssertTrue(element(identifier: "display.positionHeight").exists)
        XCTAssertTrue(element(identifier: "display.positionDistance").exists)
    }

    func testNotificationTransportControlsArePresentAndRequireConnection() throws {
        tapTab(named: "Display")

        let sendButton = element(identifier: "display.notificationSendButton")
        scrollToElement(sendButton, maximumSwipes: 10)

        XCTAssertTrue(sendButton.waitForExistence(timeout: 5))
        XCTAssertFalse(sendButton.isEnabled)
        XCTAssertTrue(element(identifier: "display.notificationTitleField").exists)
        XCTAssertTrue(element(identifier: "display.notificationMessageField").exists)
        XCTAssertEqual(element(identifier: "display.notificationStatus").label, "Not sent")
    }

    func testNavigationDiagnosticsExposesTraceEvidenceWorkflow() throws {
        tapTab(named: "Navigate")

        let diagnosticsButton = app.buttons["navigationDiagnosticsButton"]
        XCTAssertTrue(diagnosticsButton.waitForExistence(timeout: 5))
        diagnosticsButton.tap()

        XCTAssertTrue(app.navigationBars["Navigation Diagnostics"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Trace entries"].exists)

        let exportButton = app.buttons["exportNavigationTraceButton"]
        XCTAssertTrue(exportButton.exists)
        XCTAssertFalse(exportButton.isEnabled)
        XCTAssertTrue(app.staticTexts["Start navigation to collect native and fallback transport evidence."].exists)
    }

    private func tapTab(named name: String) {
        let tabButton = app.tabBars.buttons[name]
        XCTAssertTrue(tabButton.waitForExistence(timeout: 5))
        tabButton.tap()
    }

    private func element(identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func scrollToElement(_ element: XCUIElement, maximumSwipes: Int = 6) {
        var remainingSwipes = maximumSwipes
        while (!element.exists || !element.isHittable), remainingSwipes > 0 {
            app.swipeUp()
            remainingSwipes -= 1
        }
    }
}
