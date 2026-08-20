import XCTest
@testable import EvenG1Core

@MainActor
final class G1DiagnosticsStoreTests: XCTestCase {
    func testAppendAndClearDiagnostics() {
        let store = G1DiagnosticsStore()
        let log = G1BluetoothManager.LogEntry(timestamp: Date(), message: "test", level: .info)

        store.appendLog(log)
        XCTAssertEqual(store.logs.count, 1)

        store.appendEvent(.doubleTap)
        XCTAssertEqual(store.events.count, 1)

        store.clearAll()
        XCTAssertTrue(store.logs.isEmpty)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(store.recentFrames.isEmpty)
    }

    func testDiagnosticsHistoriesRemainBounded() {
        let store = G1DiagnosticsStore()

        for index in 0..<250 {
            store.appendLog(
                G1BluetoothManager.LogEntry(
                    timestamp: Date(),
                    message: "log-\(index)",
                    level: .info
                )
            )
        }
        for _ in 0..<75 {
            store.appendEvent(.doubleTap)
        }

        XCTAssertEqual(store.logs.count, 200)
        XCTAssertEqual(store.logs.first?.message, "log-50")
        XCTAssertEqual(store.events.count, 50)
    }
}

@MainActor
final class G1GlassesEventNotifierTests: XCTestCase {
    func testRevisionIncrementsWithoutPublishingDiagnosticsBuffers() {
        let notifier = G1GlassesEventNotifier()
        XCTAssertEqual(notifier.revision, 0)

        notifier.notify(.doubleTap)
        XCTAssertEqual(notifier.revision, 1)
        if case .doubleTap? = notifier.latestEvent {
            // expected
        } else {
            XCTFail("Expected doubleTap event")
        }
    }
}

final class TelemetryIdentityTests: XCTestCase {
    func testAnonymousInstallIDIsStableWithinProcess() {
        let first = TelemetryIdentity.anonymousInstallID()
        let second = TelemetryIdentity.anonymousInstallID()
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
    }

    func testBuildInfoIncludesVersionAndBuild() {
        let attributes = TelemetryBuildInfo.rumViewAttributes
        XCTAssertNotNil(attributes["app.version"])
        XCTAssertNotNil(attributes["app.build"])
    }
}
