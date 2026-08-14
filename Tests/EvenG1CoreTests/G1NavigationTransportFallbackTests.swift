import XCTest
@testable import EvenG1Core

final class G1NavigationTransportFallbackTests: XCTestCase {
    func testDowngradesToTextAfterConsecutiveNativeFailures() async {
        var transport = G1NavigationTransport(failureThreshold: 2)
        var fallbackCount = 0

        let first = await transport.performNativePreferred(
            nativeSend: { false },
            fallbackSend: { fallbackCount += 1 }
        )

        XCTAssertEqual(first.deliveryMode, .textFallback)
        XCTAssertFalse(first.downgradedToText)
        XCTAssertEqual(transport.transportMode, .nativePackets)
        XCTAssertEqual(transport.consecutiveNativeFailures, 1)

        let second = await transport.performNativePreferred(
            nativeSend: { false },
            fallbackSend: { fallbackCount += 1 }
        )

        XCTAssertEqual(second.deliveryMode, .textFallback)
        XCTAssertTrue(second.downgradedToText)
        XCTAssertEqual(transport.transportMode, .textFallback)
        XCTAssertEqual(transport.consecutiveNativeFailures, 2)
        XCTAssertEqual(fallbackCount, 2)
    }

    func testSuccessResetsFailureCounter() async {
        var transport = G1NavigationTransport(failureThreshold: 3)

        _ = await transport.performNativePreferred(nativeSend: { false }, fallbackSend: { })
        XCTAssertEqual(transport.consecutiveNativeFailures, 1)

        let success = await transport.performNativePreferred(nativeSend: { true }, fallbackSend: { XCTFail("fallback should not be used") })
        XCTAssertEqual(success.deliveryMode, .nativePackets)
        XCTAssertTrue(success.nativeAcked)
        XCTAssertEqual(transport.consecutiveNativeFailures, 0)
        XCTAssertEqual(transport.transportMode, .nativePackets)
    }

    func testTextModeSkipsNativeSend() async {
        var transport = G1NavigationTransport(failureThreshold: 2, transportMode: .textFallback)
        var nativeCallCount = 0
        var fallbackCount = 0

        let result = await transport.performNativePreferred(
            nativeSend: {
                nativeCallCount += 1
                return true
            },
            fallbackSend: { fallbackCount += 1 }
        )

        XCTAssertEqual(result.deliveryMode, .textFallback)
        XCTAssertFalse(result.nativeAcked)
        XCTAssertEqual(nativeCallCount, 0)
        XCTAssertEqual(fallbackCount, 1)
    }
}
