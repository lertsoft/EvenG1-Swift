import CLibLC3
import Foundation

/// Stateful decoder for the LC3 stream produced by the G1 microphone.
///
/// Even's reference implementation uses 10 ms, 16 kHz, mono LC3 frames with
/// 20 encoded bytes per frame. Each decoded frame contains 160 signed 16-bit
/// PCM samples. A decoder instance must be used serially because LC3 retains
/// overlap and packet-loss-concealment state between frames.
public final class G1LC3Decoder: @unchecked Sendable {
    public static let encodedFrameByteCount = 20
    public static let samplesPerFrame = 160
    public static let sampleRate = 16_000
    public static let frameDurationMicroseconds = 10_000

    public enum DecoderError: LocalizedError, Equatable {
        case allocationFailed
        case setupFailed
        case decodeFailed

        public var errorDescription: String? {
            switch self {
            case .allocationFailed:
                return "Unable to allocate LC3 decoder storage"
            case .setupFailed:
                return "Unable to configure the LC3 decoder"
            case .decodeFailed:
                return "The LC3 frame could not be decoded"
            }
        }
    }

    private let storage: UnsafeMutableRawPointer
    private let decoder: lc3_decoder_t
    private let lock = NSLock()
    private var pendingBytes = Data()

    public init() throws {
        let byteCount = Int(lc3_decoder_size(
            Int32(Self.frameDurationMicroseconds),
            Int32(Self.sampleRate)
        ))
        guard byteCount > 0 else {
            throw DecoderError.allocationFailed
        }

        storage = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<UnsafeRawPointer>.alignment
        )

        guard let configuredDecoder = lc3_setup_decoder(
            Int32(Self.frameDurationMicroseconds),
            Int32(Self.sampleRate),
            0,
            storage
        ) else {
            storage.deallocate()
            throw DecoderError.setupFailed
        }
        decoder = configuredDecoder
    }

    deinit {
        storage.deallocate()
    }

    /// Decodes all complete frames, retaining a partial final frame for the
    /// next call. An empty result therefore means that more bytes are needed.
    public func decode(_ data: Data) throws -> [Int16] {
        lock.lock()
        defer { lock.unlock() }

        guard !data.isEmpty else { return [] }
        pendingBytes.append(data)

        let completeFrameCount = pendingBytes.count / Self.encodedFrameByteCount
        guard completeFrameCount > 0 else { return [] }

        let consumedByteCount = completeFrameCount * Self.encodedFrameByteCount
        let encodedFrames = pendingBytes.prefix(consumedByteCount)
        pendingBytes.removeFirst(consumedByteCount)

        var decodedSamples = [Int16]()
        decodedSamples.reserveCapacity(completeFrameCount * Self.samplesPerFrame)

        var offset = encodedFrames.startIndex
        for _ in 0..<completeFrameCount {
            let end = encodedFrames.index(offset, offsetBy: Self.encodedFrameByteCount)
            let frame = encodedFrames[offset..<end]
            var samples = [Int16](repeating: 0, count: Self.samplesPerFrame)

            let status = frame.withUnsafeBytes { encodedBuffer in
                samples.withUnsafeMutableBytes { pcmBuffer in
                    lc3_decode(
                        decoder,
                        encodedBuffer.baseAddress,
                        Int32(Self.encodedFrameByteCount),
                        LC3_PCM_FORMAT_S16,
                        pcmBuffer.baseAddress,
                        1
                    )
                }
            }

            guard status >= 0 else {
                throw DecoderError.decodeFailed
            }
            decodedSamples.append(contentsOf: samples)
            offset = end
        }

        return decodedSamples
    }

    public func discardPartialFrame() {
        lock.lock()
        defer { lock.unlock() }
        pendingBytes.removeAll(keepingCapacity: true)
    }
}
