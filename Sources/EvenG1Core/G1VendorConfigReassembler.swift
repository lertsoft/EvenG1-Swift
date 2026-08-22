import Foundation

/// Reassembles chunked `0xF6` JSON configuration frames from the glasses.
///
/// Observed wire format: `F6 06 <chunkIndex> <json bytes...>` where chunk index
/// increments from 0 until the JSON object is complete.
public final class G1VendorConfigReassembler: @unchecked Sendable {
    private var buffer = Data()
    private var nextChunkIndex: UInt8 = 0

    public init() {}

    /// Returns the decoded UTF-8 JSON string when a complete message is assembled.
    public func ingest(payload: Data) -> String? {
        guard payload.count >= 2, payload[0] == 0x06 else {
            reset()
            return nil
        }

        let chunkIndex = payload[1]
        let chunk = Data(payload.dropFirst(2))

        if chunkIndex == 0 {
            buffer = chunk
            nextChunkIndex = 1
        } else if chunkIndex == nextChunkIndex {
            buffer.append(chunk)
            nextChunkIndex &+= 1
        } else {
            reset()
            buffer = chunk
            nextChunkIndex = 1
        }

        guard let json = String(data: buffer, encoding: .utf8),
              json.hasPrefix("{"),
              json.hasSuffix("}") else {
            return nil
        }

        reset()
        return json
    }

    private func reset() {
        buffer.removeAll(keepingCapacity: true)
        nextChunkIndex = 0
    }
}
