import Foundation
import XCTest
import CLibLC3
@testable import EvenG1Core

final class G1LC3DecoderTests: XCTestCase {
    func testDecoderBuffersPartialFrames() throws {
        let decoder = try G1LC3Decoder()

        XCTAssertEqual(try decoder.decode(Data(repeating: 0, count: 10)), [])
        XCTAssertEqual(
            try decoder.decode(Data(repeating: 0, count: 10)).count,
            G1LC3Decoder.samplesPerFrame
        )
    }

    func testDecoderProcessesAggregatedFrames() throws {
        let decoder = try G1LC3Decoder()
        let encodedFrames = Data(
            repeating: 0,
            count: G1LC3Decoder.encodedFrameByteCount * 3
        )

        XCTAssertEqual(
            try decoder.decode(encodedFrames).count,
            G1LC3Decoder.samplesPerFrame * 3
        )
    }

    func testDiscardPartialFramePreventsCrossStreamContamination() throws {
        let decoder = try G1LC3Decoder()
        XCTAssertTrue(try decoder.decode(Data(repeating: 0, count: 10)).isEmpty)

        decoder.discardPartialFrame()

        XCTAssertTrue(try decoder.decode(Data(repeating: 0, count: 10)).isEmpty)
    }

    func testDecoderProducesAudioFromValidUpstreamEncodedFrame() throws {
        let encodedFrame = try makeEncodedFrame()
        let decoder = try G1LC3Decoder()

        let samples = try decoder.decode(encodedFrame)

        XCTAssertEqual(samples.count, G1LC3Decoder.samplesPerFrame)
        XCTAssertTrue(samples.contains { abs(Int($0)) > 100 })
    }

    private func makeEncodedFrame() throws -> Data {
        let storageByteCount = Int(lc3_encoder_size(
            Int32(G1LC3Decoder.frameDurationMicroseconds),
            Int32(G1LC3Decoder.sampleRate)
        ))
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: storageByteCount,
            alignment: MemoryLayout<UnsafeRawPointer>.alignment
        )
        defer { storage.deallocate() }

        let encoder = try XCTUnwrap(lc3_setup_encoder(
            Int32(G1LC3Decoder.frameDurationMicroseconds),
            Int32(G1LC3Decoder.sampleRate),
            0,
            storage
        ))
        lc3_encoder_disable_ltpf(encoder)

        var pcm = (0..<G1LC3Decoder.samplesPerFrame).map { index in
            Int16(sin(Double(index) * 2 * .pi / 20) * 12_000)
        }
        var encoded = [UInt8](
            repeating: 0,
            count: G1LC3Decoder.encodedFrameByteCount
        )

        let status = pcm.withUnsafeMutableBytes { pcmBuffer in
            encoded.withUnsafeMutableBytes { encodedBuffer in
                lc3_encode(
                    encoder,
                    LC3_PCM_FORMAT_S16,
                    pcmBuffer.baseAddress,
                    1,
                    Int32(G1LC3Decoder.encodedFrameByteCount),
                    encodedBuffer.baseAddress
                )
            }
        }
        XCTAssertEqual(status, 0)
        return Data(encoded)
    }
}
