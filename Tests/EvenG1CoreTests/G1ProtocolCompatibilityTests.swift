import XCTest
@testable import EvenG1Core

final class G1ProtocolCompatibilityTests: XCTestCase {
    func testSingleTapFromDirectDeviceEvent() {
        let parser = G1FrameParser()
        parser.protocolMode = .auto

        let frame = parser.parseFrame(
            data: Data([G1Command.DEVICE_EVENT.rawValue, G1DeviceEvent.SINGLE_TAP.rawValue]),
            side: .left
        )
        let event = parser.parseEvent(from: frame)

        guard case .singleTap? = event else {
            return XCTFail("Expected single tap from direct 0xF5 event, got \(String(describing: event))")
        }
    }

    func testSingleTapFromStatusWrappedDeviceEvent() {
        let parser = G1FrameParser()
        parser.protocolMode = .auto

        let frame = parser.parseFrame(
            data: Data([
                G1Command.STATUS.rawValue,
                G1Command.DEVICE_EVENT.rawValue,
                G1DeviceEvent.SINGLE_TAP.rawValue
            ]),
            side: .right
        )
        let event = parser.parseEvent(from: frame)

        guard case .singleTap? = event else {
            return XCTFail("Expected single tap from wrapped 0x22 status event, got \(String(describing: event))")
        }
    }

    func testTripleTapAlternateCodeInAutoMode() {
        let parser = G1FrameParser()
        parser.protocolMode = .auto

        let frame = parser.parseFrame(
            data: Data([G1Command.DEVICE_EVENT.rawValue, G1DeviceEvent.TRIPLE_TAP_ALT.rawValue]),
            side: .left
        )
        let event = parser.parseEvent(from: frame)

        guard case .tripleTap? = event else {
            return XCTFail("Expected triple tap alias 0x05 in auto mode, got \(String(describing: event))")
        }
    }

    func testUnknownEventIncludesPayloadMetadata() {
        let parser = G1FrameParser()
        parser.protocolMode = .auto

        let frame = parser.parseFrame(
            data: Data([G1Command.STATUS.rawValue, 0x99, 0xAA]),
            side: .left
        )
        let event = parser.parseEvent(from: frame)

        guard case let .unknown(command, firstPayloadByte, payload)? = event else {
            return XCTFail("Expected unknown event with payload metadata, got \(String(describing: event))")
        }

        XCTAssertEqual(command, G1Command.STATUS.rawValue)
        XCTAssertEqual(firstPayloadByte, 0x99)
        XCTAssertEqual(payload, Data([0x99, 0xAA]))
    }

    func testAckSendOrderLeftThenRight() {
        XCTAssertEqual(G1BluetoothManager.ackSendOrder(for: nil), [.left, .right])
        XCTAssertEqual(G1BluetoothManager.ackSendOrder(for: .left), [.left])
        XCTAssertEqual(G1BluetoothManager.ackSendOrder(for: .right), [.right])
    }

    func testHeartbeatPreferenceByProtocolMode() {
        XCTAssertTrue(G1BluetoothManager.prefersExtendedHeartbeat(for: .auto))
        XCTAssertTrue(G1BluetoothManager.prefersExtendedHeartbeat(for: .official))
        XCTAssertFalse(G1BluetoothManager.prefersExtendedHeartbeat(for: .legacy))
    }

    func testTextModeDefaultsToAwaitAck() {
        XCTAssertTrue(G1TextDisplayMode.text.defaultAwaitAck)
    }
}
