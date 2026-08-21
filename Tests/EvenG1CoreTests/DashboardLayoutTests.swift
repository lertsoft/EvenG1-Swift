import XCTest
import CoreGraphics
@testable import EvenG1Core

final class DashboardLayoutTests: XCTestCase {
    private var canvas: CGRect {
        CGRect(x: 0, y: 0, width: DashboardLayout.width, height: DashboardLayout.height)
    }

    func testAllZonesStayInsideCanvas() {
        for mode in DashboardLayoutMode.allCases {
            let zones = DashboardLayout.zones(for: mode)
            assertContained(zones.status, mode: mode, name: "status")
            if let calendar = zones.calendar { assertContained(calendar, mode: mode, name: "calendar") }
            if let widget = zones.widget { assertContained(widget, mode: mode, name: "widget") }
            if let indicator = zones.pageIndicator { assertContained(indicator, mode: mode, name: "pageIndicator") }
        }
    }

    func testMinimalUsesOnlyStatus() {
        let zones = DashboardLayout.zones(for: .minimal)
        XCTAssertNil(zones.calendar)
        XCTAssertNil(zones.widget)
        XCTAssertNil(zones.dividerX)
        XCTAssertGreaterThan(zones.status.width, DashboardLayout.statusColumnWidth)
    }

    func testDualHasStatusAndWidgetButNoCalendar() {
        let zones = DashboardLayout.zones(for: .dual)
        XCTAssertNil(zones.calendar)
        XCTAssertNotNil(zones.widget)
        XCTAssertNotNil(zones.dividerX)
        assertNoHorizontalOverlap(zones.status, zones.widget!)
    }

    func testFullHasEveryZoneAndNoStatusWidgetOverlap() {
        let zones = DashboardLayout.zones(for: .full)
        XCTAssertNotNil(zones.calendar)
        XCTAssertNotNil(zones.widget)
        XCTAssertNotNil(zones.pageIndicator)
        assertNoHorizontalOverlap(zones.status, zones.widget!)
        // Calendar sits below the status block, not overlapping it.
        XCTAssertGreaterThanOrEqual(zones.calendar!.minY, zones.status.maxY - 0.5)
    }

    private func assertContained(_ rect: CGRect, mode: DashboardLayoutMode, name: String) {
        XCTAssertTrue(canvas.contains(rect), "\(mode).\(name) \(rect) escapes canvas \(canvas)")
        XCTAssertGreaterThan(rect.width, 0, "\(mode).\(name) has non-positive width")
        XCTAssertGreaterThan(rect.height, 0, "\(mode).\(name) has non-positive height")
    }

    private func assertNoHorizontalOverlap(_ left: CGRect, _ right: CGRect) {
        XCTAssertLessThanOrEqual(left.maxX, right.minX, "zones overlap horizontally: \(left) vs \(right)")
    }
}
