import XCTest

final class EvenG1SwiftUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()
    }

    @MainActor
    func testConnectTabShowsDisconnectedStateAndScanControls() throws {
        XCTAssertTrue(app.navigationBars["Even G1"].waitForExistence(timeout: 5))

        let noGlassesState = app.otherElements["connection.noGlasses"]
        XCTAssertTrue(noGlassesState.waitForExistence(timeout: 5))

        let scanButton = app.buttons["connection.scanButton"]
        let reconnectButton = app.buttons["connection.reconnectButton"]

        XCTAssertTrue(scanButton.exists)
        XCTAssertTrue(reconnectButton.exists)
        XCTAssertTrue(scanButton.isEnabled)
        XCTAssertTrue(reconnectButton.isEnabled)
    }

    @MainActor
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

        let mtaRefreshButton = app.buttons["mta.refreshButton"]
        let mtaStatusLabel = app.staticTexts["mta.statusLabel"]

        XCTAssertTrue(mtaRefreshButton.exists)
        XCTAssertTrue(mtaStatusLabel.exists)
    }

    @MainActor
    func testDisplayTabShowsMTAAutoRefreshToggleAndDefaultStatus() throws {
        tapTab(named: "Display")

        let mtaStatusLabel = app.staticTexts["mta.statusLabel"]
        let mtaAutoRefreshToggle = app.switches["mta.autoRefreshToggle"]

        XCTAssertTrue(mtaStatusLabel.waitForExistence(timeout: 5))
        XCTAssertTrue(mtaAutoRefreshToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(mtaStatusLabel.label, "No train lookup yet")
    }

    @MainActor
    func testLogsTabCanSwitchToEventsEmptyState() throws {
        tapTab(named: "Logs")

        XCTAssertTrue(app.navigationBars["Debug"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Debug"].buttons["Clear"].exists)

        let eventsSegment = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Events")).firstMatch
        XCTAssertTrue(eventsSegment.waitForExistence(timeout: 5))
        eventsSegment.tap()

        XCTAssertTrue(app.otherElements["events.emptyState"].waitForExistence(timeout: 5))
    }

    private func tapTab(named name: String) {
        let tabButton = app.tabBars.buttons[name]
        XCTAssertTrue(tabButton.waitForExistence(timeout: 5))
        tabButton.tap()
    }
}
