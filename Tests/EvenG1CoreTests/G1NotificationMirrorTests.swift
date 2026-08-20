import XCTest
@testable import EvenG1Core

final class G1NotificationMirrorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func notification(_ id: String, offset: TimeInterval = 0) -> G1MirroredNotification {
        G1MirroredNotification(
            id: id,
            title: "Title \(id)",
            body: "Body \(id)",
            receivedAt: start.addingTimeInterval(offset)
        )
    }

    // MARK: - Arrival

    func testArrivalShowsIconOnly() {
        var mirror = G1NotificationMirror()
        let display = mirror.apply(.arrived(notification("a")), now: start)

        XCTAssertEqual(display, .icon(pendingCount: 1))
        XCTAssertEqual(mirror.state, .iconVisible)
        XCTAssertTrue(mirror.ownsDisplay)
        XCTAssertNil(mirror.current)
    }

    func testSecondArrivalUpdatesIconCount() {
        var mirror = G1NotificationMirror()
        _ = mirror.apply(.arrived(notification("a")), now: start)

        XCTAssertEqual(mirror.apply(.arrived(notification("b")), now: start), .icon(pendingCount: 2))
    }

    func testDuplicateIdentifierIsIgnored() {
        var mirror = G1NotificationMirror()
        _ = mirror.apply(.arrived(notification("a")), now: start)

        XCTAssertNil(mirror.apply(.arrived(notification("a")), now: start))
        XCTAssertEqual(mirror.pendingCount, 1)
    }

    func testQueueIsBoundedAndDropsOldest() {
        var mirror = G1NotificationMirror(maximumPending: 2)
        _ = mirror.apply(.arrived(notification("a")), now: start)
        _ = mirror.apply(.arrived(notification("b")), now: start)
        _ = mirror.apply(.arrived(notification("c")), now: start)

        XCTAssertEqual(mirror.pending.map(\.id), ["b", "c"])
    }

    // MARK: - Tilt to read

    func testHeadUpAcknowledgesNewestAndShowsText() {
        var mirror = G1NotificationMirror()
        _ = mirror.apply(.arrived(notification("old")), now: start)
        _ = mirror.apply(.arrived(notification("new", offset: 1)), now: start)

        let display = mirror.apply(.headUp, now: start)

        // Newest first: the message the wearer just received is the one revealed.
        XCTAssertEqual(display, .text(notification("new", offset: 1)))
        XCTAssertEqual(mirror.state, .reading(notification("new", offset: 1)))
        // Acknowledged at reveal time, so it is no longer pending.
        XCTAssertEqual(mirror.pending.map(\.id), ["old"])
    }

    func testHeadUpWithEmptyQueueIsIgnored() {
        var mirror = G1NotificationMirror()

        XCTAssertNil(mirror.apply(.headUp, now: start))
        XCTAssertEqual(mirror.state, .idle)
    }

    func testDuplicateHeadUpFromSecondArmIsIgnored() {
        var mirror = G1NotificationMirror()
        _ = mirror.apply(.arrived(notification("a")), now: start)
        _ = mirror.apply(.arrived(notification("b")), now: start)
        _ = mirror.apply(.headUp, now: start)

        // Both arms report the gesture ~200 ms apart; the second must not burn
        // through the next notification.
        let duplicate = mirror.apply(.headUp, now: start.addingTimeInterval(0.2))

        XCTAssertNil(duplicate)
        XCTAssertEqual(mirror.pending.map(\.id), ["a"])
    }

    // MARK: - Dismissal

    func testFirmwareAutoHeadDownDuringHoldIsIgnored() {
        var mirror = G1NotificationMirror()
        _ = mirror.apply(.arrived(notification("a")), now: start)
        _ = mirror.apply(.headUp, now: start)

        // The firmware emits its own head-down 500-700 ms after every head-up.
        XCTAssertNil(mirror.apply(.headDown, now: start.addingTimeInterval(0.6)))
        XCTAssertEqual(mirror.state, .reading(notification("a")))
    }

    func testHeadDownAfterHoldClearsWhenQueueIsEmpty() {
        var mirror = G1NotificationMirror()
        _ = mirror.apply(.arrived(notification("a")), now: start)
        _ = mirror.apply(.headUp, now: start)

        let display = mirror.apply(.headDown, now: start.addingTimeInterval(2))

        XCTAssertEqual(display, .clear)
        XCTAssertEqual(mirror.state, .idle)
        XCTAssertFalse(mirror.ownsDisplay)
    }

    func testHeadDownAfterHoldShowsIconForRemainingNotification() {
        var mirror = G1NotificationMirror()
        _ = mirror.apply(.arrived(notification("a")), now: start)
        _ = mirror.apply(.arrived(notification("b")), now: start)
        _ = mirror.apply(.headUp, now: start)

        let display = mirror.apply(.headDown, now: start.addingTimeInterval(2))

        XCTAssertEqual(display, .icon(pendingCount: 1))
        XCTAssertEqual(mirror.state, .iconVisible)
    }

    func testReadTimeoutDismissesCurrent() {
        var mirror = G1NotificationMirror()
        _ = mirror.apply(.arrived(notification("a")), now: start)
        _ = mirror.apply(.headUp, now: start)

        XCTAssertEqual(mirror.apply(.readTimeout(id: "a"), now: start.addingTimeInterval(12)), .clear)
        XCTAssertEqual(mirror.state, .idle)
    }

    func testStaleReadTimeoutDoesNotDismissDifferentNotification() {
        var mirror = G1NotificationMirror()
        _ = mirror.apply(.arrived(notification("a")), now: start)
        _ = mirror.apply(.arrived(notification("b")), now: start)
        _ = mirror.apply(.headUp, now: start)

        // A timer left over from an earlier message must not close this one.
        XCTAssertNil(mirror.apply(.readTimeout(id: "a"), now: start.addingTimeInterval(12)))
        XCTAssertEqual(mirror.state, .reading(notification("b")))
    }

    func testArrivalDuringReadingDoesNotInterrupt() {
        var mirror = G1NotificationMirror()
        _ = mirror.apply(.arrived(notification("a")), now: start)
        _ = mirror.apply(.headUp, now: start)

        XCTAssertNil(mirror.apply(.arrived(notification("b")), now: start.addingTimeInterval(1)))
        XCTAssertEqual(mirror.state, .reading(notification("a")))
        XCTAssertEqual(mirror.pending.map(\.id), ["b"])
    }

    // MARK: - Suspension

    func testSuspendEmitsNoDisplayCommandAndPreservesQueue() {
        var mirror = G1NotificationMirror()
        _ = mirror.apply(.arrived(notification("a")), now: start)

        XCTAssertNil(mirror.apply(.suspend, now: start))
        XCTAssertEqual(mirror.state, .suspended)
        XCTAssertFalse(mirror.ownsDisplay)
        XCTAssertTrue(mirror.hasContent)
    }

    func testArrivalWhileSuspendedQueuesWithoutDrawing() {
        var mirror = G1NotificationMirror()
        _ = mirror.apply(.suspend, now: start)

        XCTAssertNil(mirror.apply(.arrived(notification("a")), now: start))
        XCTAssertEqual(mirror.pendingCount, 1)
        XCTAssertEqual(mirror.state, .suspended)
    }

    func testResumeReassertsIconWhenPending() {
        var mirror = G1NotificationMirror()
        _ = mirror.apply(.arrived(notification("a")), now: start)
        _ = mirror.apply(.suspend, now: start)

        XCTAssertEqual(mirror.apply(.resume, now: start), .icon(pendingCount: 1))
        XCTAssertEqual(mirror.state, .iconVisible)
    }

    func testResumeReassertsTextWhenInterruptedMidRead() {
        var mirror = G1NotificationMirror()
        _ = mirror.apply(.arrived(notification("a")), now: start)
        _ = mirror.apply(.headUp, now: start)
        _ = mirror.apply(.suspend, now: start)

        XCTAssertEqual(mirror.apply(.resume, now: start), .text(notification("a")))
        XCTAssertEqual(mirror.state, .reading(notification("a")))
    }

    func testResumeWithNothingPendingEmitsNothing() {
        var mirror = G1NotificationMirror()
        _ = mirror.apply(.suspend, now: start)

        XCTAssertNil(mirror.apply(.resume, now: start))
        XCTAssertEqual(mirror.state, .idle)
    }

    func testHeadUpWhileSuspendedIsIgnored() {
        var mirror = G1NotificationMirror()
        _ = mirror.apply(.arrived(notification("a")), now: start)
        _ = mirror.apply(.suspend, now: start)

        XCTAssertNil(mirror.apply(.headUp, now: start))
        XCTAssertEqual(mirror.state, .suspended)
    }

    // MARK: - Reset

    func testResetClearsLensWhenMirrorOwnsIt() {
        var mirror = G1NotificationMirror()
        _ = mirror.apply(.arrived(notification("a")), now: start)

        XCTAssertEqual(mirror.apply(.reset, now: start), .clear)
        XCTAssertEqual(mirror.state, .idle)
        XCTAssertFalse(mirror.hasContent)
    }

    func testResetWhileSuspendedDoesNotTouchLens() {
        var mirror = G1NotificationMirror()
        _ = mirror.apply(.arrived(notification("a")), now: start)
        _ = mirror.apply(.suspend, now: start)

        // Navigation owns the surface here, so resetting must not clear it.
        XCTAssertNil(mirror.apply(.reset, now: start))
        XCTAssertFalse(mirror.hasContent)
    }

    func testResetWhenIdleEmitsNothing() {
        var mirror = G1NotificationMirror()

        XCTAssertNil(mirror.apply(.reset, now: start))
    }

    // MARK: - Text composition

    func testLensTextJoinsTitleAndBody() {
        XCTAssertEqual(notification("a").lensText, "Title a\nBody a")
    }

    func testLensTextOmitsEmptyTitle() {
        let bodyOnly = G1MirroredNotification(id: "a", title: "  ", body: "Body", receivedAt: start)

        XCTAssertEqual(bodyOnly.lensText, "Body")
    }
}
