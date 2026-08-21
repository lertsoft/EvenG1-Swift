import XCTest
@testable import EvenG1Core

final class DashboardSettingsTests: XCTestCase {
    func testDefaultsAreSafeAndOptIn() {
        let settings = DashboardSettings.default
        XCTAssertFalse(settings.isEnabled)
        XCTAssertFalse(settings.calendarEnabled)
        XCTAssertFalse(settings.remindersEnabled)
        XCTAssertFalse(settings.weatherEnabled)
        XCTAssertEqual(settings.layout, .full)
        XCTAssertEqual(settings.selectedWidget, .quickNote)
        XCTAssertEqual(settings.timeFormat, .twentyFourHour)
        XCTAssertEqual(settings.temperatureUnit, .celsius)
    }

    func testCodableRoundTrip() throws {
        var settings = DashboardSettings.default
        settings.isEnabled = true
        settings.layout = .dual
        settings.selectedWidget = .news
        settings.timeFormat = .twelveHour
        settings.temperatureUnit = .fahrenheit
        settings.calendarEnabled = true
        settings.quickNote = "Pick up oat milk"
        settings.stockSymbols = ["AAPL", "MSFT"]
        settings.newsFeedURL = "https://example.com/rss"

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(DashboardSettings.self, from: data)

        XCTAssertEqual(decoded, settings)
    }

    func testDecodingToleratesMissingNewerFields() throws {
        // A payload written before newer fields existed must still decode using
        // defaults rather than throwing.
        let legacy = """
        {"isEnabled":true,"layout":"minimal","selectedWidget":"map"}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(DashboardSettings.self, from: legacy)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded.layout, .minimal)
        XCTAssertEqual(decoded.selectedWidget, .map)
        // Missing fields fall back to defaults.
        XCTAssertEqual(decoded.timeFormat, DashboardSettings.default.timeFormat)
        XCTAssertFalse(decoded.weatherEnabled)
        XCTAssertEqual(decoded.quickNote, "")
    }

    func testWidgetOfflineAvailability() {
        XCTAssertTrue(DashboardWidgetKind.quickNote.isAvailableOffline)
        XCTAssertFalse(DashboardWidgetKind.stocks.isAvailableOffline)
        XCTAssertFalse(DashboardWidgetKind.news.isAvailableOffline)
        XCTAssertFalse(DashboardWidgetKind.map.isAvailableOffline)
    }
}
