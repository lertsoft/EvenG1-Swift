import XCTest
@testable import EvenG1Core

final class G1NavigationGestureMappingTests: XCTestCase {
    func testGestureMappingsWhenNavigationIsActive() {
        XCTAssertEqual(G1NavigationGestureMapper.action(for: .doubleTap, isNavigationActive: true), .repeatCurrentInstruction)
        XCTAssertEqual(G1NavigationGestureMapper.action(for: .singleTap, isNavigationActive: true), .announceStatus)
        XCTAssertEqual(G1NavigationGestureMapper.action(for: .swipeForward, isNavigationActive: true), .previewNextStep)
        XCTAssertEqual(G1NavigationGestureMapper.action(for: .swipeBackward, isNavigationActive: true), .previewPreviousStep)
        XCTAssertEqual(G1NavigationGestureMapper.action(for: .tripleTap, isNavigationActive: true), .recenterToLiveStep)
        XCTAssertEqual(G1NavigationGestureMapper.action(for: .pressAndHold, isNavigationActive: true), .endNavigation)
        XCTAssertEqual(G1NavigationGestureMapper.action(for: .pressAndRelease, isNavigationActive: true), .toggleMute)
        XCTAssertEqual(G1NavigationGestureMapper.action(for: .headUp, isNavigationActive: true), .showOverlay)
        XCTAssertEqual(G1NavigationGestureMapper.action(for: .headDown, isNavigationActive: true), .hideOverlay)
    }

    func testGestureMappingsReturnNilWhenNavigationInactive() {
        XCTAssertNil(G1NavigationGestureMapper.action(for: .doubleTap, isNavigationActive: false))
        XCTAssertNil(G1NavigationGestureMapper.action(for: .headUp, isNavigationActive: false))
    }

    func testUnmappedEventReturnsNil() {
        XCTAssertNil(G1NavigationGestureMapper.action(for: .caseOpen, isNavigationActive: true))
    }
}
