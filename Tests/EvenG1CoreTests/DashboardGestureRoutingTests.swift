import XCTest
@testable import EvenG1Core

final class DashboardGestureRoutingTests: XCTestCase {
    func testBothSwipeDirectionsUseDashboardWhenItOwnsPaging() {
        XCTAssertEqual(
            DashboardGestureRouting.destination(for: .swipeForward, dashboardOwnsSwipes: true),
            .dashboard
        )
        XCTAssertEqual(
            DashboardGestureRouting.destination(for: .swipeBackward, dashboardOwnsSwipes: true),
            .dashboard
        )
    }

    func testBothSwipeDirectionsUseTransitWhenDashboardDoesNotOwnPaging() {
        XCTAssertEqual(
            DashboardGestureRouting.destination(for: .swipeForward, dashboardOwnsSwipes: false),
            .transit
        )
        XCTAssertEqual(
            DashboardGestureRouting.destination(for: .swipeBackward, dashboardOwnsSwipes: false),
            .transit
        )
    }

    func testNonSwipeEventsContinueToTransit() {
        XCTAssertEqual(
            DashboardGestureRouting.destination(for: .headUp, dashboardOwnsSwipes: true),
            .transit
        )
    }
}
