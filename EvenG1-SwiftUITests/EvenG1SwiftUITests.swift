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

    // MARK: - Information architecture

    func testTabBarExposesOnlyConsumerDestinations() throws {
        XCTAssertTrue(app.navigationBars["Even G1"].waitForExistence(timeout: 5))

        for name in ["Device", "Navigate", "Heads-Up"] {
            XCTAssertTrue(app.tabBars.buttons[name].exists, "Missing consumer tab: \(name)")
        }

        for name in ["Display", "Logs"] {
            XCTAssertFalse(app.tabBars.buttons[name].exists, "Debug tab still in tab bar: \(name)")
        }
    }

    // MARK: - Device tab

    func testDeviceTabShowsSingleConnectActionWhenDisconnected() throws {
        XCTAssertTrue(app.navigationBars["Even G1"].waitForExistence(timeout: 5))

        let connectButton = app.buttons["device.connectButton"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))
        XCTAssertTrue(connectButton.isEnabled)

        XCTAssertTrue(element(identifier: "device.connectHint").exists)
        XCTAssertFalse(app.buttons["device.disconnectButton"].exists)
        XCTAssertFalse(app.buttons["device.silentModeToggle"].exists)
    }

    func testGlassesConfigurationRequiresConnection() throws {
        element(identifier: "device.configurationLink").tap()

        XCTAssertTrue(app.navigationBars["Glasses Configuration"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["configuration.connectRequiredLabel"].waitForExistence(timeout: 5))

        let applyPosition = element(identifier: "configuration.positionApply")
        scrollToElement(applyPosition, maximumSwipes: 8)
        XCTAssertTrue(applyPosition.exists)
        XCTAssertFalse(applyPosition.isEnabled)
        XCTAssertTrue(element(identifier: "configuration.positionHeight").exists)
        XCTAssertTrue(element(identifier: "configuration.positionDistance").exists)
    }

    // MARK: - Developer mode

    func testDeveloperToolsAreHiddenUntilDeveloperModeIsEnabled() throws {
        XCTAssertTrue(app.navigationBars["Even G1"].waitForExistence(timeout: 5))
        XCTAssertFalse(element(identifier: "device.developerToolsLink").exists)

        element(identifier: "device.supportLink").tap()
        XCTAssertTrue(app.navigationBars["Support & Diagnostics"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["support.exportButton"].exists)

        let developerToggle = app.switches["support.developerModeToggle"]
        XCTAssertTrue(developerToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(developerToggle.value as? String, "0")
        setSwitch(developerToggle, on: true)
        XCTAssertEqual(developerToggle.value as? String, "1")

        navigateBack()

        let developerLink = element(identifier: "device.developerToolsLink")
        XCTAssertTrue(developerLink.waitForExistence(timeout: 5))
        developerLink.tap()

        XCTAssertTrue(app.navigationBars["Developer Tools"].waitForExistence(timeout: 5))

        element(identifier: "developer.logsLink").tap()
        XCTAssertTrue(app.navigationBars["Logs & Events"].waitForExistence(timeout: 5))

        let eventsSegment = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Events")).firstMatch
        XCTAssertTrue(eventsSegment.waitForExistence(timeout: 5))
        eventsSegment.tap()
        XCTAssertTrue(element(identifier: "events.emptyState").waitForExistence(timeout: 5))

    }

    func testNavigationDiagnosticsLivesBehindDeveloperTools() throws {
        XCTAssertTrue(app.navigationBars["Even G1"].waitForExistence(timeout: 5))
        tapTab(named: "Navigate")

        XCTAssertFalse(app.buttons["navigationDiagnosticsButton"].exists)
    }

    // MARK: - Navigate tab

    func testNavigateTabLocateButtonIsVisibleWhenIdle() throws {
        tapTab(named: "Navigate")

        let locateButton = app.buttons["navigation.locateUserButton"]
        XCTAssertTrue(locateButton.waitForExistence(timeout: 5))
    }

    func testNavigateTabHidesTripControlsWhenIdle() throws {
        tapTab(named: "Navigate")

        XCTAssertTrue(app.buttons["navigation.locateUserButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["navigation.addFavoriteButton"].exists)
        XCTAssertFalse(app.buttons["navigation.hudPreviewButton"].exists)
        XCTAssertFalse(element(identifier: "navigation.hudPreviewPanel").exists)
        XCTAssertFalse(app.buttons["navigation.endTripButton"].exists)
    }

    // MARK: - Heads-Up tab

    func testHeadsUpTabListsWidgetsAndWarnsWhenDisconnected() throws {
        tapTab(named: "Heads-Up")

        XCTAssertTrue(app.navigationBars["Heads-Up"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(identifier: "apps.disconnectedNotice").waitForExistence(timeout: 5))
        XCTAssertTrue(element(identifier: "apps.transitLink").exists)
        XCTAssertTrue(element(identifier: "apps.notificationsLink").exists)
        XCTAssertTrue(element(identifier: "apps.translateLink").exists)
        XCTAssertTrue(element(identifier: "apps.notesLink").exists)
    }

    func testTranslationRequiresConnectedGlasses() throws {
        guard #available(iOS 18.0, *) else { return }

        tapTab(named: "Heads-Up")
        element(identifier: "apps.translateLink").tap()

        XCTAssertTrue(app.navigationBars["Translate"].waitForExistence(timeout: 5))
        let toggle = element(identifier: "translation.toggleButton")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertFalse(toggle.isEnabled)
    }

    func testTransitWidgetShowsArrivalControls() throws {
        tapTab(named: "Heads-Up")
        element(identifier: "apps.transitLink").tap()

        let statusLabel = element(identifier: "mta.statusLabel")
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 5))

        let refreshButton = element(identifier: "mta.refreshButton")
        scrollToElement(refreshButton, maximumSwipes: 10)
        XCTAssertTrue(refreshButton.exists)

        let autoRefreshToggle = element(identifier: "mta.autoRefreshToggle")
        scrollToElement(autoRefreshToggle, maximumSwipes: 10)
        XCTAssertTrue(autoRefreshToggle.exists)
    }

    func testNotesWidgetRequiresConnectionToSend() throws {
        tapTab(named: "Heads-Up")
        element(identifier: "apps.notesLink").tap()

        XCTAssertTrue(app.navigationBars["Notes & Prompts"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["notes.connectRequiredLabel"].waitForExistence(timeout: 5))

        let sendButton = element(identifier: "notes.sendButton")
        let clearButton = element(identifier: "notes.clearButton")
        XCTAssertTrue(sendButton.exists)
        XCTAssertTrue(clearButton.exists)
        XCTAssertFalse(sendButton.isEnabled)
        XCTAssertFalse(clearButton.isEnabled)
    }

    func testNotificationsWidgetRequiresConnectionToSend() throws {
        tapTab(named: "Heads-Up")
        element(identifier: "apps.notificationsLink").tap()

        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["notifications.connectRequiredLabel"].waitForExistence(timeout: 5))

        let sendButton = element(identifier: "notifications.sendButton")
        scrollToElement(sendButton, maximumSwipes: 8)
        XCTAssertTrue(sendButton.exists)
        XCTAssertFalse(sendButton.isEnabled)
        XCTAssertTrue(element(identifier: "notifications.titleField").exists)
        XCTAssertTrue(element(identifier: "notifications.messageField").exists)
        XCTAssertEqual(element(identifier: "notifications.status").label, "Not sent")
    }

    func testNotificationMirrorIsOffUntilEnabled() throws {
        tapTab(named: "Heads-Up")
        element(identifier: "apps.notificationsLink").tap()

        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))

        let mirrorToggle = element(identifier: "notifications.mirrorToggle")
        scrollToElement(mirrorToggle, maximumSwipes: 8)
        XCTAssertTrue(mirrorToggle.exists)

        // Simulating is pointless while the mirror is off, so the control stays
        // disabled until the feature is on.
        let simulateButton = element(identifier: "notifications.simulateButton")
        scrollToElement(simulateButton, maximumSwipes: 8)
        XCTAssertTrue(simulateButton.exists)
        XCTAssertFalse(simulateButton.isEnabled)
    }

    func testNotificationMirrorEnablingRevealsSimulateAction() throws {
        tapTab(named: "Heads-Up")
        element(identifier: "apps.notificationsLink").tap()

        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))

        let mirrorToggle = element(identifier: "notifications.mirrorToggle")
        scrollToElement(mirrorToggle, maximumSwipes: 8)
        setSwitch(mirrorToggle, on: true)

        let simulateButton = element(identifier: "notifications.simulateButton")
        scrollToElement(simulateButton, maximumSwipes: 8)
        XCTAssertTrue(simulateButton.isEnabled)

        // Queue one notification. Without glasses attached the mirror still tracks
        // it, so the dismiss action appears and the status invites the tilt.
        simulateButton.tap()

        let dismissButton = element(identifier: "notifications.dismissButton")
        XCTAssertTrue(dismissButton.waitForExistence(timeout: 5))

        let status = element(identifier: "notifications.mirrorStatus")
        scrollBackToElement(status, maximumSwipes: 8)
        XCTAssertTrue(
            status.label.contains("Tilt your head up"),
            "Unexpected mirror status: \(status.label)"
        )
    }

    // MARK: - Helpers

    private func tapTab(named name: String) {
        let tabButton = app.tabBars.buttons[name]
        XCTAssertTrue(tabButton.waitForExistence(timeout: 5))
        tabButton.tap()
    }

    private func element(identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func navigateBack() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// A row-wide SwiftUI `Toggle` reports its own frame, so tapping the element
    /// centre can land on the label. Tap the nested switch control instead.
    private func setSwitch(_ element: XCUIElement, on: Bool) {
        guard (element.value as? String) != (on ? "1" : "0") else { return }

        let control = element.switches.firstMatch
        if control.exists {
            control.tap()
        } else {
            element.tap()
        }
    }

    private func scrollToElement(_ element: XCUIElement, maximumSwipes: Int = 6) {
        var remainingSwipes = maximumSwipes
        while (!element.exists || !element.isHittable), remainingSwipes > 0 {
            app.swipeUp()
            remainingSwipes -= 1
        }
    }

    /// Counterpart to `scrollToElement` for rows that sit above the current
    /// scroll position.
    private func scrollBackToElement(_ element: XCUIElement, maximumSwipes: Int = 6) {
        var remainingSwipes = maximumSwipes
        while (!element.exists || !element.isHittable), remainingSwipes > 0 {
            app.swipeDown()
            remainingSwipes -= 1
        }
    }
}
