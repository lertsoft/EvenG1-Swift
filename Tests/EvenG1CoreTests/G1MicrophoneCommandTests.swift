import XCTest
@testable import EvenG1Core

final class G1MicrophoneCommandTests: XCTestCase {
    func testMicrophoneStartCandidatesUsePrimaryThenFallback() {
        let candidates = G1BluetoothManager.microphoneCommandCandidates(enable: true)
        XCTAssertEqual(candidates, [
            Data([G1CompatibilityCommand.microphonePrimary, 0x01]),
            Data([G1CompatibilityCommand.microphoneFallback, 0x01])
        ])
    }

    func testMicrophoneStopCandidatesUsePrimaryThenFallback() {
        let candidates = G1BluetoothManager.microphoneCommandCandidates(enable: false)
        XCTAssertEqual(candidates, [
            Data([G1CompatibilityCommand.microphonePrimary, 0x00]),
            Data([G1CompatibilityCommand.microphoneFallback, 0x00])
        ])
    }

    func testAckRoutingIncludesMicrophonePrimaryAndFallback() {
        XCTAssertTrue(G1BluetoothManager.routesAck(for: G1CompatibilityCommand.microphonePrimary))
        XCTAssertTrue(G1BluetoothManager.routesAck(for: G1CompatibilityCommand.microphoneFallback))
    }

    func testMicrophoneControlOrderIsRightThenLeftByDefault() {
        XCTAssertEqual(
            G1BluetoothManager.microphoneControlOrder(preferredSide: .right, activeSide: nil),
            [.right, .left]
        )
    }

    func testMicrophoneControlOrderPrefersActiveSideFirst() {
        XCTAssertEqual(
            G1BluetoothManager.microphoneControlOrder(preferredSide: .right, activeSide: .left),
            [.left, .right]
        )
    }
}
