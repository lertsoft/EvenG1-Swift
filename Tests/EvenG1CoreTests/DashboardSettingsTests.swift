import XCTest
@testable import EvenG1Core

final class DashboardSettingsTests: XCTestCase {
    func testDefaultsAreSafeAndOptIn() {
        let settings = DashboardSettings.default
        XCTAssertFalse(settings.isEnabled)
        XCTAssertFalse(settings.calendarEnabled)
        XCTAssertFalse(settings.remindersEnabled)
        XCTAssertFalse(settings.weatherEnabled)
        XCTAssertFalse(settings.transitEnabled)
        XCTAssertEqual(settings.layout, .full)
        XCTAssertEqual(settings.selectedWidgets, [.quickNote])
        XCTAssertEqual(settings.widgetDisplayMode, .paged)
        XCTAssertEqual(settings.autoRotateSeconds, 8)
        XCTAssertEqual(settings.selectedWidget, .quickNote)
        XCTAssertEqual(settings.timeFormat, .twentyFourHour)
        XCTAssertEqual(settings.temperatureUnit, .celsius)
    }

    func testCodableRoundTrip() throws {
        var settings = DashboardSettings.default
        settings.isEnabled = true
        settings.layout = .dual
        settings.selectedWidgets = [.news, .transit, .quickNote]
        settings.widgetDisplayMode = .autoRotate
        settings.autoRotateSeconds = 12
        settings.timeFormat = .twelveHour
        settings.temperatureUnit = .fahrenheit
        settings.calendarEnabled = true
        settings.transitEnabled = true
        settings.quickNote = "Pick up oat milk"
        settings.stockSymbols = ["AAPL", "MSFT"]
        settings.newsFeedURL = "https://example.com/rss"
        settings.transitHorizonMinutes = 20

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(DashboardSettings.self, from: data)

        XCTAssertEqual(decoded, settings)
    }

    func testDecodingToleratesMissingNewerFields() throws {
        let legacy = """
        {"isEnabled":true,"layout":"minimal","selectedWidget":"map"}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(DashboardSettings.self, from: legacy)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded.layout, .minimal)
        XCTAssertEqual(decoded.selectedWidgets, [.map])
        XCTAssertEqual(decoded.selectedWidget, .map)
        XCTAssertEqual(decoded.widgetDisplayMode, .paged)
        XCTAssertEqual(decoded.timeFormat, DashboardSettings.default.timeFormat)
        XCTAssertFalse(decoded.weatherEnabled)
        XCTAssertEqual(decoded.quickNote, "")
    }

    func testDecodingSelectedWidgetsArray() throws {
        let payload = """
        {"selectedWidgets":["transit","news"]}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(DashboardSettings.self, from: payload)
        XCTAssertEqual(decoded.selectedWidgets, [.transit, .news])
    }

    func testWidgetOfflineAvailability() {
        XCTAssertTrue(DashboardWidgetKind.quickNote.isAvailableOffline)
        XCTAssertFalse(DashboardWidgetKind.stocks.isAvailableOffline)
        XCTAssertFalse(DashboardWidgetKind.news.isAvailableOffline)
        XCTAssertFalse(DashboardWidgetKind.map.isAvailableOffline)
        XCTAssertFalse(DashboardWidgetKind.transit.isAvailableOffline)
    }

    func testSnapshotCurrentWidgetUsesPageIndex() {
        let snapshot = DashboardSnapshot(
            widgets: [.quickNote("A"), .news(source: "Src", headline: "Headline")],
            displayMode: .paged,
            pageIndex: 1
        )
        if case .news(let source, let headline) = snapshot.widget {
            XCTAssertEqual(source, "Src")
            XCTAssertEqual(headline, "Headline")
        } else {
            XCTFail("Expected news widget on page 1")
        }
    }
}
