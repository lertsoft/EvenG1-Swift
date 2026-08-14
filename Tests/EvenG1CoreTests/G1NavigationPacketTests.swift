import XCTest
@testable import EvenG1Core

final class G1NavigationPacketTests: XCTestCase {
    func testModePacketEncodesPrimaryCommandAndMode() {
        let packet = G1NavigationPacketBuilder.modePacket(mode: .walking)
        XCTAssertEqual(packet, Data([G1CompatibilityCommand.navigationPrimary, G1NavigationSubcommand.setMode.rawValue, G1NavigationMode.walking.rawValue]))
    }

    func testStartAndEndPacketsUseExpectedSubcommands() {
        let start = G1NavigationPacketBuilder.startPacket(mode: .transit)
        let end = G1NavigationPacketBuilder.endPacket()

        XCTAssertEqual(start, Data([G1CompatibilityCommand.navigationPrimary, G1NavigationSubcommand.startSession.rawValue, G1NavigationMode.transit.rawValue]))
        XCTAssertEqual(end, Data([G1CompatibilityCommand.navigationPrimary, G1NavigationSubcommand.endSession.rawValue]))
    }

    func testProgressPacketEncodesDistanceAndDuration() throws {
        let progress = G1NavigationProgress(
            stepIndex: 3,
            totalSteps: 9,
            remainingDistanceMeters: 1200,
            remainingDurationSeconds: 480,
            etaEpochSeconds: nil
        )

        let packet = try G1NavigationPacketBuilder.progressPacket(progress)

        XCTAssertEqual(packet[0], G1CompatibilityCommand.navigationPrimary)
        XCTAssertEqual(packet[1], G1NavigationSubcommand.progress.rawValue)
        XCTAssertEqual(packet[2], 3)
        XCTAssertEqual(packet[3], 9)
        XCTAssertEqual(packet[4], 0x04)
        XCTAssertEqual(packet[5], 0xB0)
        XCTAssertEqual(packet[6], 0x01)
        XCTAssertEqual(packet[7], 0xE0)
    }

    func testInstructionPacketTruncatesLongUTF8Payload() throws {
        let long = String(repeating: "Turn right and continue straight ", count: 10)
        let instruction = G1NavigationInstruction(
            text: long,
            stepIndex: 0,
            totalSteps: 6,
            distanceToManeuverMeters: 40,
            remainingDistanceMeters: 1500,
            etaEpochSeconds: nil
        )

        let packet = try G1NavigationPacketBuilder.instructionPacket(instruction)

        XCTAssertEqual(packet[0], G1CompatibilityCommand.navigationPrimary)
        XCTAssertEqual(packet[1], G1NavigationSubcommand.instruction.rawValue)
        let textLength = Int(packet[10])
        XCTAssertLessThanOrEqual(textLength, G1NavigationPacketBuilder.maxInstructionBytes)
        XCTAssertEqual(packet.count, textLength + 11)
    }

    func testInstructionPacketThrowsWhenStepOutOfRange() {
        let invalid = G1NavigationInstruction(
            text: "Continue",
            stepIndex: 999,
            totalSteps: 1,
            distanceToManeuverMeters: 10,
            remainingDistanceMeters: 10,
            etaEpochSeconds: nil
        )

        XCTAssertThrowsError(try G1NavigationPacketBuilder.instructionPacket(invalid)) { error in
            XCTAssertEqual(error as? G1NavigationPacketError, .stepOutOfRange)
        }
    }
}
