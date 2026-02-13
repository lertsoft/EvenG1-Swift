import Foundation
import XCTest
@testable import EvenG1Core

final class G1MicrophonePacketParsingTests: XCTestCase {
    func testParseMicrophonePayloadExtractsSequenceAndAudio() {
        let payload = Data([0x2A, 0x10, 0x11, 0x12])
        let parsed = G1BluetoothManager.parseMicrophonePayload(payload)

        XCTAssertEqual(parsed.sequence, 0x2A)
        XCTAssertEqual(parsed.audioPayload, Data([0x10, 0x11, 0x12]))
    }

    func testParseMicrophonePayloadKeepsRawAudioWhenLengthAlreadyLooksLikeLC3() {
        let payload = Data(repeating: 0x55, count: 200)
        let parsed = G1BluetoothManager.parseMicrophonePayload(payload)

        XCTAssertNil(parsed.sequence)
        XCTAssertEqual(parsed.audioPayload, payload)
    }

    func testParseMicrophonePayloadUsesSequenceWhenStrippedLengthLooksLikeLC3() {
        var payload = Data([0x2A])
        payload.append(Data(repeating: 0x77, count: 200))
        let parsed = G1BluetoothManager.parseMicrophonePayload(payload)

        XCTAssertEqual(parsed.sequence, 0x2A)
        XCTAssertEqual(parsed.audioPayload.count, 200)
    }

    func testParseMicrophonePayloadHandlesEmptyData() {
        let parsed = G1BluetoothManager.parseMicrophonePayload(Data())

        XCTAssertNil(parsed.sequence)
        XCTAssertTrue(parsed.audioPayload.isEmpty)
    }

    func testApplyingMicrophonePacketIncrementsStats() {
        let baseStats = G1MicrophoneStats(
            startedAt: Date(timeIntervalSince1970: 100),
            packetCount: 4,
            byteCount: 16,
            lastSequence: 0x20
        )
        let packet = G1MicrophonePacket(
            timestamp: Date(timeIntervalSince1970: 110),
            side: .right,
            sequence: 0x21,
            payload: Data([0x01, 0x02, 0x03, 0x04])
        )

        let updated = G1BluetoothManager.applyingMicrophonePacket(
            packet,
            to: baseStats,
            fallbackStartDate: packet.timestamp
        )

        XCTAssertEqual(updated.startedAt, baseStats.startedAt)
        XCTAssertEqual(updated.packetCount, 5)
        XCTAssertEqual(updated.byteCount, 20)
        XCTAssertEqual(updated.lastSequence, 0x21)
    }

    func testApplyingMicrophonePacketPreservesLastSequenceWhenPacketHasNoSequence() {
        let baseStats = G1MicrophoneStats(
            startedAt: nil,
            packetCount: 0,
            byteCount: 0,
            lastSequence: 0x30
        )
        let packet = G1MicrophonePacket(
            timestamp: Date(timeIntervalSince1970: 50),
            side: .left,
            sequence: nil,
            payload: Data([0xAA, 0xBB])
        )

        let updated = G1BluetoothManager.applyingMicrophonePacket(
            packet,
            to: baseStats,
            fallbackStartDate: packet.timestamp
        )

        XCTAssertEqual(updated.startedAt, packet.timestamp)
        XCTAssertEqual(updated.packetCount, 1)
        XCTAssertEqual(updated.byteCount, 2)
        XCTAssertEqual(updated.lastSequence, 0x30)
    }
}
