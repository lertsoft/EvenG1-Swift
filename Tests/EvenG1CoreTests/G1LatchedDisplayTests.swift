import XCTest
@testable import EvenG1Core

final class G1VendorConfigReassemblerTests: XCTestCase {
    func testReassemblesChunkedJSON() {
        let reassembler = G1VendorConfigReassembler()

        let chunk0 = Data([0x06, 0x00] + Array("{\"whitelist_add\": {\"application_identifier\": \"".utf8))
        XCTAssertNil(reassembler.ingest(payload: chunk0))

        let chunk1 = Data([0x06, 0x01] + Array("com.example.app\"}}".utf8))
        let json = reassembler.ingest(payload: chunk1)

        XCTAssertEqual(json, "{\"whitelist_add\": {\"application_identifier\": \"com.example.app\"}}")
    }
}

final class G1LatchedDisplayTests: XCTestCase {
    func testHeadUpModeCommandsDisabledByDefault() {
        XCTAssertFalse(G1BluetoothManager.headUpModeCommandsEnabled)
    }
}
