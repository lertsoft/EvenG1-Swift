import Foundation
import XCTest
@testable import EvenG1Core

final class G1NotificationPacketBuilderTests: XCTestCase {
    func testWhitelistUsesVendorJSONShapeAndBoundedPackets() throws {
        let apps = (0..<20).map {
            G1NotificationApp(
                identifier: "com.example.app\($0)",
                displayName: "Example Application \($0)"
            )
        }
        let whitelist = G1NotificationWhitelist(
            apps: apps,
            calendarEnabled: true,
            callsEnabled: true
        )

        let packets = try G1NotificationPacketBuilder().buildWhitelistPackets(for: whitelist)

        XCTAssertGreaterThan(packets.count, 1)
        XCTAssertTrue(packets.allSatisfy { $0.count <= 180 })
        for (index, packet) in packets.enumerated() {
            XCTAssertEqual(packet[0], G1Command.WHITELIST.rawValue)
            XCTAssertEqual(packet[1], UInt8(packets.count))
            XCTAssertEqual(packet[2], UInt8(index))
        }

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: joinedPayload(from: packets, headerByteCount: 3))
                as? [String: Any]
        )
        XCTAssertEqual(object["calendar_enable"] as? Bool, true)
        XCTAssertEqual(object["call_enable"] as? Bool, true)
        XCTAssertEqual(object["msg_enable"] as? Bool, false)
        XCTAssertEqual(object["ios_mail_enable"] as? Bool, false)

        let app = try XCTUnwrap(object["app"] as? [String: Any])
        XCTAssertEqual(app["enable"] as? Bool, true)
        let list = try XCTUnwrap(app["list"] as? [[String: String]])
        XCTAssertEqual(list.count, apps.count)
        XCTAssertEqual(list.first?["id"], "com.example.app0")
        XCTAssertEqual(list.first?["name"], "Example Application 0")
    }

    func testNotificationUsesTransportIDAndVendorEnvelope() throws {
        let notification = G1Notification(
            messageID: 42,
            appIdentifier: "com.example.swift",
            title: "Train update",
            subtitle: "Downtown",
            message: String(repeating: "Arriving soon 🚇 ", count: 20),
            timestampMilliseconds: 1_786_320_000_000,
            displayName: "EvenG1 Swift"
        )

        let packets = try G1NotificationPacketBuilder().buildNotificationPackets(
            for: notification,
            transportID: 0xA7
        )

        XCTAssertGreaterThan(packets.count, 1)
        XCTAssertTrue(packets.allSatisfy { $0.count <= 180 })
        for (index, packet) in packets.enumerated() {
            XCTAssertEqual(packet[0], G1Command.NOTIFICATION.rawValue)
            XCTAssertEqual(packet[1], 0xA7)
            XCTAssertEqual(packet[2], UInt8(packets.count))
            XCTAssertEqual(packet[3], UInt8(index))
        }

        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: joinedPayload(from: packets, headerByteCount: 4))
                as? [String: Any]
        )
        let payload = try XCTUnwrap(envelope["ncs_notification"] as? [String: Any])
        XCTAssertEqual(payload["msg_id"] as? Int64, 42)
        XCTAssertEqual(payload["app_identifier"] as? String, "com.example.swift")
        XCTAssertEqual(payload["title"] as? String, "Train update")
        XCTAssertEqual(payload["subtitle"] as? String, "Downtown")
        XCTAssertEqual(payload["message"] as? String, notification.message)
        XCTAssertEqual(payload["time_s"] as? Int64, 1_786_320_000_000)
        XCTAssertEqual(payload["display_name"] as? String, "EvenG1 Swift")
    }

    func testNotificationRejectsMoreThan255Packets() {
        let notification = G1Notification(
            messageID: 1,
            appIdentifier: "com.example.swift",
            title: "Oversized",
            message: String(repeating: "x", count: 45_000),
            timestampMilliseconds: 0,
            displayName: "EvenG1 Swift"
        )

        XCTAssertThrowsError(
            try G1NotificationPacketBuilder().buildNotificationPackets(
                for: notification,
                transportID: 0
            )
        ) { error in
            guard case G1NotificationPacketError.payloadTooLarge(let packetCount) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertGreaterThan(packetCount, G1NotificationPacketBuilder.maximumPacketCount)
        }
    }

    func testNotificationCommandRoutesAcknowledgements() {
        XCTAssertTrue(G1BluetoothManager.routesAck(for: G1Command.NOTIFICATION.rawValue))
    }

    private func joinedPayload(from packets: [Data], headerByteCount: Int) -> Data {
        packets.reduce(into: Data()) { payload, packet in
            payload.append(packet.dropFirst(headerByteCount))
        }
    }
}
