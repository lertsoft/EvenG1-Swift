import Foundation

public enum G1MicrophoneState: Sendable, Equatable {
    case idle
    case starting
    case streaming
    case stopping
    case failed(String)

    public var displayName: String {
        switch self {
        case .idle:
            return "Idle"
        case .starting:
            return "Starting"
        case .streaming:
            return "Streaming"
        case .stopping:
            return "Stopping"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }
}

public struct G1MicrophonePacket: Sendable {
    public let timestamp: Date
    public let side: GlassesSide
    public let sequence: UInt8?
    public let payload: Data

    public init(timestamp: Date, side: GlassesSide, sequence: UInt8?, payload: Data) {
        self.timestamp = timestamp
        self.side = side
        self.sequence = sequence
        self.payload = payload
    }
}

public struct G1MicrophoneStats: Sendable, Equatable {
    public let startedAt: Date?
    public let packetCount: Int
    public let byteCount: Int
    public let lastSequence: UInt8?

    public init(startedAt: Date?, packetCount: Int, byteCount: Int, lastSequence: UInt8?) {
        self.startedAt = startedAt
        self.packetCount = packetCount
        self.byteCount = byteCount
        self.lastSequence = lastSequence
    }
}
