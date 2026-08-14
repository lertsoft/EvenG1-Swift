import Foundation
import XCTest
@testable import EvenG1Core

final class G1NavigationTraceExporterTests: XCTestCase {
    func testExportIsChronologicalAndNewlineTerminated() throws {
        let earlier = makeEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            note: "start"
        )
        let later = makeEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            timestamp: Date(timeIntervalSince1970: 1_700_000_010),
            note: "progress"
        )

        let jsonLines = G1NavigationTraceExporter.jsonLines(newestFirst: [later, earlier])
        XCTAssertTrue(jsonLines.hasSuffix("\n"))

        let lines = jsonLines.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try lines.map { line in
            try decoder.decode(G1NavigationTraceEntry.self, from: Data(line.utf8))
        }
        XCTAssertEqual(decoded.map(\.id), [earlier.id, later.id])
        XCTAssertEqual(decoded.map(\.note), ["start", "progress"])
    }

    func testEmptyExportIsEmpty() {
        XCTAssertEqual(G1NavigationTraceExporter.jsonLines(newestFirst: []), "")
    }

    private func makeEntry(id: UUID,
                           timestamp: Date,
                           note: String) -> G1NavigationTraceEntry {
        G1NavigationTraceEntry(
            id: id,
            timestamp: timestamp,
            direction: .tx,
            command: 0x0A,
            payloadHex: "0A 01",
            mode: .walking,
            transportMode: .nativePackets,
            stepIndex: 0,
            totalSteps: 2,
            remainingDistanceMeters: 100,
            etaEpochSeconds: 1_700_000_100,
            note: note
        )
    }
}
