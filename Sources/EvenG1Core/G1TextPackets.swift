import Foundation

public enum G1TextDisplayMode: Int, CaseIterable, Sendable {
    case text
    case ai

    public var displayName: String {
        switch self {
        case .text: return "Text"
        case .ai: return "AI"
        }
    }

    public var defaultAwaitAck: Bool {
        switch self {
        case .text: return true
        case .ai: return true
        }
    }

    public var usesPagingControls: Bool {
        switch self {
        case .text: return false
        case .ai: return true
        }
    }

    public func screenStatus(isLast: Bool) -> UInt8 {
        switch self {
        case .text:
            return isLast ? 0x71 : 0x70
        case .ai:
            return isLast ? 0x40 : 0x31
        }
    }
}

public struct G1TextSendRequest: Sendable {
    public var text: String
    public var mode: G1TextDisplayMode
    public var page: UInt8
    public var maxPage: UInt8
    public var charPosition: UInt16
    public var maxChunkSize: Int
    public var startSequence: UInt8
    public var awaitAck: Bool
    public var interPacketDelayMs: UInt64

    public init(
        text: String,
        mode: G1TextDisplayMode = .text,
        page: UInt8 = 1,
        maxPage: UInt8 = 1,
        charPosition: UInt16 = 0,
        maxChunkSize: Int = 180,
        startSequence: UInt8 = 0,
        awaitAck: Bool? = nil,
        interPacketDelayMs: UInt64 = 16
    ) {
        self.text = text
        self.mode = mode
        self.page = page
        self.maxPage = maxPage
        self.charPosition = charPosition
        self.maxChunkSize = maxChunkSize
        self.startSequence = startSequence
        self.awaitAck = awaitAck ?? mode.defaultAwaitAck
        self.interPacketDelayMs = interPacketDelayMs
    }
}

public struct G1TextPacket: Sendable {
    public let data: Data
    public let isLast: Bool
    public let sequence: UInt8
    public let packetIndex: UInt8
    public let totalPackets: UInt8
}

public struct G1TextPacketBuilder {
    public let textHelper: G1TextHelper

    public init(textHelper: G1TextHelper = G1TextHelper()) {
        self.textHelper = textHelper
    }

    public func buildPackets(for request: G1TextSendRequest) -> [G1TextPacket] {
        let lines = textHelper.wrapText(request.text)
        let displayText = lines.prefix(G1TextHelper.maxLines).joined(separator: "\n")

        guard let textData = displayText.data(using: .utf8), !textData.isEmpty else {
            return []
        }

        let headerSize = 9
        let maxChunkSize = max(request.maxChunkSize, headerSize + 1)
        let maxPayload = maxChunkSize - headerSize

        let textBytes = Array(textData)
        var packets: [[UInt8]] = []
        var offset = 0
        var sequence = request.startSequence

        while offset < textBytes.count {
            let remaining = textBytes.count - offset
            let payloadSize = min(remaining, maxPayload)
            let isLast = offset + payloadSize >= textBytes.count
            let packetIndex = UInt8(packets.count)

            let screenStatus = request.mode.screenStatus(isLast: isLast)
            let charPosHi = UInt8((request.charPosition >> 8) & 0xFF)
            let charPosLo = UInt8(request.charPosition & 0xFF)

            var packet: [UInt8] = [
                G1Command.SEND_TEXT.rawValue,
                sequence,
                0x00,
                packetIndex,
                screenStatus,
                charPosHi,
                charPosLo,
                request.page,
                request.maxPage
            ]

            packet.append(contentsOf: textBytes[offset..<(offset + payloadSize)])
            packets.append(packet)

            offset += payloadSize
            sequence = sequence &+ 1
        }

        let totalPackets = UInt8(min(packets.count, Int(UInt8.max)))
        var result: [G1TextPacket] = []
        result.reserveCapacity(packets.count)

        for (index, packet) in packets.enumerated() {
            var updated = packet
            updated[2] = totalPackets

            result.append(G1TextPacket(
                data: Data(updated),
                isLast: index == packets.count - 1,
                sequence: updated[1],
                packetIndex: updated[3],
                totalPackets: totalPackets
            ))
        }

        return result
    }
}
