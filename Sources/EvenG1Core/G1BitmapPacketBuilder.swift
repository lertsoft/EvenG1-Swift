import Foundation

public enum G1BitmapPacketError: Error, Equatable {
    case invalidChunkPayloadSize
    case tooManyChunks
}

public struct G1BitmapPacketEnvelope: Sendable, Equatable {
    public let dataPackets: [Data]
    public let endPacket: Data
    public let crcPacket: Data

    public init(dataPackets: [Data], endPacket: Data, crcPacket: Data) {
        self.dataPackets = dataPackets
        self.endPacket = endPacket
        self.crcPacket = crcPacket
    }
}

public struct G1BitmapPacketBuilder: Sendable {
    public let chunkPayloadSize: Int
    public let firstChunkAddress: [UInt8]

    public init(chunkPayloadSize: Int = 194, firstChunkAddress: [UInt8] = [0x00, 0x1C, 0x00, 0x00]) {
        self.chunkPayloadSize = chunkPayloadSize
        self.firstChunkAddress = firstChunkAddress
    }

    public func buildPackets(for frame: G1BitmapFrame) throws -> G1BitmapPacketEnvelope {
        guard chunkPayloadSize > 0 else {
            throw G1BitmapPacketError.invalidChunkPayloadSize
        }

        let bmpData = frame.bmpData
        let chunks = try splitIntoChunks(bmpData)

        let endPacket = Data([G1Command.BMP_END.rawValue, 0x0D, 0x0E])
        var crcInput = Data(firstChunkAddress)
        crcInput.append(bmpData)
        let crc = crcInput.crc32
        let crcPacket = Data([
            G1Command.CRC_CHECK.rawValue,
            UInt8((crc >> 24) & 0xFF),
            UInt8((crc >> 16) & 0xFF),
            UInt8((crc >> 8) & 0xFF),
            UInt8(crc & 0xFF)
        ])

        return G1BitmapPacketEnvelope(
            dataPackets: chunks,
            endPacket: endPacket,
            crcPacket: crcPacket
        )
    }

    private func splitIntoChunks(_ payload: Data) throws -> [Data] {
        let chunkCount = max(1, (payload.count + chunkPayloadSize - 1) / chunkPayloadSize)
        guard chunkCount <= Int(UInt8.max) + 1 else {
            throw G1BitmapPacketError.tooManyChunks
        }

        var chunks: [Data] = []
        chunks.reserveCapacity(chunkCount)
        var offset = 0
        var index = 0

        while offset < payload.count {
            var packet = Data([
                G1Command.BMP_DATA.rawValue,
                UInt8(index)
            ])

            if index == 0 {
                packet.append(contentsOf: firstChunkAddress)
            }

            let chunkSize = min(chunkPayloadSize, payload.count - offset)
            packet.append(contentsOf: payload[offset..<(offset + chunkSize)])

            chunks.append(packet)
            offset += chunkSize
            index += 1
        }

        if chunks.isEmpty {
            chunks.append(Data([
                G1Command.BMP_DATA.rawValue,
                0x00
            ] + firstChunkAddress))
        }

        return chunks
    }
}
