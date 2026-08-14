import XCTest
@testable import EvenG1Core

final class G1DashboardCommandTests: XCTestCase {
    func testHeadUpModePayloadUsesExpectedByte() {
        XCTAssertEqual(G1BluetoothManager.headUpModePayload(for: .off), [0x00])
        XCTAssertEqual(G1BluetoothManager.headUpModePayload(for: .dashboard), [0x01])
        XCTAssertEqual(G1BluetoothManager.headUpModePayload(for: .notes), [0x02])
        XCTAssertEqual(G1BluetoothManager.headUpModePayload(for: .notify), [0x03])
    }

    func testDashboardVisibilityPayloadUsesExpectedFlag() {
        XCTAssertEqual(G1BluetoothManager.dashboardVisibilityPayload(visible: true), [0x01])
        XCTAssertEqual(G1BluetoothManager.dashboardVisibilityPayload(visible: false), [0x00])
    }

    func testDisplayPositionPacketMatchesVendorLayoutAndClampsValues() {
        let settings = G1DisplayPositionSettings(enabled: true, height: 20, distance: -2)
        XCTAssertEqual(settings.height, 8)
        XCTAssertEqual(settings.distance, 0)

        let packet = G1DisplaySettingsPacketBuilder.positionPacket(settings: settings, sequence: 0x2A)
        XCTAssertEqual(packet, Data([0x26, 0x08, 0x00, 0x2A, 0x02, 0x01, 0x08, 0x01]))
    }

    func testAckRoutingIncludesDashboardAndHeadUpCommands() {
        XCTAssertTrue(G1BluetoothManager.routesAck(for: G1CompatibilityCommand.dashboardVisibility))
        XCTAssertTrue(G1BluetoothManager.routesAck(for: G1CompatibilityCommand.headUpMode))
        XCTAssertTrue(G1BluetoothManager.routesAck(for: G1CompatibilityCommand.headUpModeAlt))
        XCTAssertTrue(G1BluetoothManager.routesAck(for: G1Command.DISPLAY_SETTINGS.rawValue))
    }

    func testFallbackVisibilityRequiresStateChange() {
        let config = G1TiltDashboardConfig(enabled: true, headUpMode: .dashboard, appEventFallback: true)
        let now = Date(timeIntervalSince1970: 1_000)

        let decision = G1BluetoothManager.fallbackDashboardVisibility(
            config: config,
            event: .headUp,
            isDashboardVisible: true,
            lastActionAt: nil,
            now: now
        )

        XCTAssertNil(decision)
    }

    func testFallbackVisibilityHonorsDebounce() {
        let config = G1TiltDashboardConfig(enabled: true, headUpMode: .dashboard, appEventFallback: true)
        let now = Date(timeIntervalSince1970: 1_000)
        let tooRecent = now.addingTimeInterval(-0.1)

        let decision = G1BluetoothManager.fallbackDashboardVisibility(
            config: config,
            event: .headDown,
            isDashboardVisible: true,
            lastActionAt: tooRecent,
            now: now
        )

        XCTAssertNil(decision)
    }

    func testFallbackVisibilityProducesShowAndHideDecisions() {
        let config = G1TiltDashboardConfig(enabled: true, headUpMode: .dashboard, appEventFallback: true)
        let now = Date(timeIntervalSince1970: 1_000)
        let old = now.addingTimeInterval(-1.0)

        let showDecision = G1BluetoothManager.fallbackDashboardVisibility(
            config: config,
            event: .headUp,
            isDashboardVisible: false,
            lastActionAt: old,
            now: now
        )
        XCTAssertEqual(showDecision, true)

        let hideDecision = G1BluetoothManager.fallbackDashboardVisibility(
            config: config,
            event: .headDown,
            isDashboardVisible: true,
            lastActionAt: old,
            now: now
        )
        XCTAssertEqual(hideDecision, false)
    }

    func testParserMapsAlternateHeadCodesToHeadEvents() {
        let parser = G1FrameParser()

        let upFrame = parser.parseFrame(
            data: Data([G1Command.DEVICE_EVENT.rawValue, G1DeviceEvent.HEAD_UP_ALT.rawValue]),
            side: .left
        )
        let downFrame = parser.parseFrame(
            data: Data([G1Command.DEVICE_EVENT.rawValue, G1DeviceEvent.HEAD_DOWN_ALT.rawValue]),
            side: .right
        )

        guard case .headUp? = parser.parseEvent(from: upFrame) else {
            return XCTFail("Expected alt head-up code to map to .headUp")
        }
        guard case .headDown? = parser.parseEvent(from: downFrame) else {
            return XCTFail("Expected alt head-down code to map to .headDown")
        }
    }
}
