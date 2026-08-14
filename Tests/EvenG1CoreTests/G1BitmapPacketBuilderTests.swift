import XCTest
@testable import EvenG1Core

final class G1BitmapPacketBuilderTests: XCTestCase {
    func testBuildPacketsEncodesChunkHeadersAndFooterPackets() throws {
        let payload = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let frame = try G1BitmapFrame(width: 16, height: 2, bitPackedRows: payload)
        let address: [UInt8] = [0x00, 0x1C, 0x00, 0x00]
        let builder = G1BitmapPacketBuilder(chunkPayloadSize: 10, firstChunkAddress: address)

        let envelope = try builder.buildPackets(for: frame)

        XCTAssertEqual(envelope.dataPackets.count, 8)
        XCTAssertEqual(
            envelope.dataPackets[0],
            Data([G1Command.BMP_DATA.rawValue, 0x00] + address) + frame.bmpData.prefix(10)
        )
        XCTAssertEqual(
            envelope.dataPackets[1],
            Data([G1Command.BMP_DATA.rawValue, 0x01]) + frame.bmpData[10..<20]
        )

        XCTAssertEqual(envelope.endPacket, Data([G1Command.BMP_END.rawValue, 0x0D, 0x0E]))
        XCTAssertEqual(envelope.crcPacket.first, G1Command.CRC_CHECK.rawValue)
        XCTAssertEqual(envelope.crcPacket.count, 5)
    }

    func testCRCIncludesStorageAddressAndBMPFile() throws {
        let payload = Data([0x10, 0x20, 0x30, 0x40])
        let frame = try G1BitmapFrame(width: 16, height: 2, bitPackedRows: payload)
        let builder = G1BitmapPacketBuilder(chunkPayloadSize: 20)

        let envelope = try builder.buildPackets(for: frame)
        let address = builder.firstChunkAddress
        let crc = (Data(address) + frame.bmpData).crc32
        let expected = Data([
            G1Command.CRC_CHECK.rawValue,
            UInt8((crc >> 24) & 0xFF),
            UInt8((crc >> 16) & 0xFF),
            UInt8((crc >> 8) & 0xFF),
            UInt8(crc & 0xFF)
        ])

        XCTAssertEqual(envelope.crcPacket, expected)
    }

    func testInvalidChunkPayloadSizeThrows() throws {
        let frame = try G1BitmapFrame(width: 8, height: 1, bitPackedRows: Data([0x00]))
        let builder = G1BitmapPacketBuilder(chunkPayloadSize: 0, firstChunkAddress: [0x00, 0x1C, 0x00, 0x00])

        XCTAssertThrowsError(try builder.buildPackets(for: frame)) { error in
            XCTAssertEqual(error as? G1BitmapPacketError, .invalidChunkPayloadSize)
        }
    }

    func testBMPEncodingMatchesVendorHeaderLayout() throws {
        let frame = try G1BitmapFrame(
            width: 16,
            height: 2,
            bitPackedRows: Data([0x00, 0xFF, 0xAA, 0x55])
        )

        let bmp = frame.bmpData

        XCTAssertEqual(bmp.count, 72)
        XCTAssertEqual(bmp.prefix(2), Data([0x42, 0x4D]))
        XCTAssertEqual(bmp[10..<14], Data([0x3E, 0x00, 0x00, 0x00]))
        XCTAssertEqual(bmp[18..<22], Data([0x10, 0x00, 0x00, 0x00]))
        XCTAssertEqual(bmp[22..<26], Data([0x02, 0x00, 0x00, 0x00]))
        XCTAssertEqual(bmp[54..<62], Data([0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00]))

        // Positive-height BMPs are bottom-up and use the inverted vendor palette.
        XCTAssertEqual(bmp[62..<66], Data([0x55, 0xAA, 0x00, 0x00]))
        XCTAssertEqual(bmp[66..<70], Data([0xFF, 0x00, 0x00, 0x00]))
        XCTAssertEqual(bmp[70..<72], Data([0x00, 0x00]))
    }
}
