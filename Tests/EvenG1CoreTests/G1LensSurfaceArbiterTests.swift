import XCTest
@testable import EvenG1Core

final class G1LensSurfaceArbiterTests: XCTestCase {
    private func owner(navigation: G1NavigationSessionState = .inactive,
                       mirrorEligible: Bool = false,
                       transitActive: Bool = false) -> G1LensSurfaceOwner {
        G1LensSurfaceArbiter.headGestureOwner(
            navigationSessionState: navigation,
            isNotificationMirrorEligible: mirrorEligible,
            isTransitWidgetActive: transitActive
        )
    }

    func testNavigationOutranksEverythingWhileActive() {
        for state in [G1NavigationSessionState.active, .rerouting, .arrived] {
            XCTAssertEqual(
                owner(navigation: state, mirrorEligible: true, transitActive: true),
                .navigation,
                "Navigation should own head gestures in \(state)"
            )
        }
    }

    func testMirrorOutranksTransitWhenItHasSomethingToShow() {
        XCTAssertEqual(owner(mirrorEligible: true, transitActive: true), .notificationMirror)
    }

    func testIdleMirrorLeavesTransitAlone() {
        // Transit's head-down clears the lens, so an idle mirror must not take the
        // gesture away from it.
        XCTAssertEqual(owner(mirrorEligible: false, transitActive: true), .transit)
    }

    func testDashboardFallbackWhenNothingElseWantsTheGesture() {
        XCTAssertEqual(owner(), .dashboardFallback)
    }

    func testOnlyHeadGesturesAreContended() {
        XCTAssertTrue(G1LensSurfaceArbiter.isContendedGesture(.headUp))
        XCTAssertTrue(G1LensSurfaceArbiter.isContendedGesture(.headDown))
        XCTAssertFalse(G1LensSurfaceArbiter.isContendedGesture(.singleTap))
        XCTAssertFalse(G1LensSurfaceArbiter.isContendedGesture(.doubleTap))
        XCTAssertFalse(G1LensSurfaceArbiter.isContendedGesture(.swipeForward))
    }
}
