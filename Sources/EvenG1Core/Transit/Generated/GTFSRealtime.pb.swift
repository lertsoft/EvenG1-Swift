import Foundation

/// Minimal GTFS-Realtime message subset used by the MTA next-train pipeline.
/// This mirrors fields from the official GTFS-Realtime protobuf definitions.
public struct TransitRealtime_FeedMessage: Sendable {
    public var entity: [TransitRealtime_FeedEntity]

    public init(entity: [TransitRealtime_FeedEntity] = []) {
        self.entity = entity
    }

    public static func decode(from data: Data) throws -> TransitRealtime_FeedMessage {
        try TransitRealtimeBinaryDecoder.decodeFeedMessage(from: data)
    }
}

public struct TransitRealtime_FeedEntity: Sendable {
    public var id: String
    public var tripUpdate: TransitRealtime_TripUpdate?

    public init(id: String = "", tripUpdate: TransitRealtime_TripUpdate? = nil) {
        self.id = id
        self.tripUpdate = tripUpdate
    }
}

public struct TransitRealtime_TripUpdate: Sendable {
    public var trip: TransitRealtime_TripDescriptor
    public var stopTimeUpdate: [TransitRealtime_StopTimeUpdate]

    public init(
        trip: TransitRealtime_TripDescriptor = TransitRealtime_TripDescriptor(),
        stopTimeUpdate: [TransitRealtime_StopTimeUpdate] = []
    ) {
        self.trip = trip
        self.stopTimeUpdate = stopTimeUpdate
    }
}

public struct TransitRealtime_TripDescriptor: Sendable {
    public var tripID: String
    public var routeID: String

    public init(tripID: String = "", routeID: String = "") {
        self.tripID = tripID
        self.routeID = routeID
    }
}

public struct TransitRealtime_StopTimeUpdate: Sendable {
    public var stopID: String
    public var arrival: TransitRealtime_StopTimeEvent?
    public var departure: TransitRealtime_StopTimeEvent?

    public init(
        stopID: String = "",
        arrival: TransitRealtime_StopTimeEvent? = nil,
        departure: TransitRealtime_StopTimeEvent? = nil
    ) {
        self.stopID = stopID
        self.arrival = arrival
        self.departure = departure
    }
}

public struct TransitRealtime_StopTimeEvent: Sendable {
    public var time: Int64?

    public init(time: Int64? = nil) {
        self.time = time
    }
}

private enum TransitRealtimeBinaryDecoder {
    enum DecodeError: Error {
        case malformedData
        case unsupportedWireType(UInt8)
    }

    static func decodeFeedMessage(from data: Data) throws -> TransitRealtime_FeedMessage {
        var reader = ProtobufBinaryReader(data: data)
        var message = TransitRealtime_FeedMessage()

        while let tag = try reader.readTag() {
            switch (tag.fieldNumber, tag.wireType) {
            case (2, 2):
                let entityData = try reader.readLengthDelimitedData()
                let entity = try decodeFeedEntity(from: entityData)
                message.entity.append(entity)
            default:
                try reader.skipField(wireType: tag.wireType)
            }
        }

        return message
    }

    private static func decodeFeedEntity(from data: Data) throws -> TransitRealtime_FeedEntity {
        var reader = ProtobufBinaryReader(data: data)
        var entity = TransitRealtime_FeedEntity()

        while let tag = try reader.readTag() {
            switch (tag.fieldNumber, tag.wireType) {
            case (1, 2):
                entity.id = try reader.readLengthDelimitedString()
            case (3, 2):
                let tripData = try reader.readLengthDelimitedData()
                entity.tripUpdate = try decodeTripUpdate(from: tripData)
            default:
                try reader.skipField(wireType: tag.wireType)
            }
        }

        return entity
    }

    private static func decodeTripUpdate(from data: Data) throws -> TransitRealtime_TripUpdate {
        var reader = ProtobufBinaryReader(data: data)
        var update = TransitRealtime_TripUpdate()

        while let tag = try reader.readTag() {
            switch (tag.fieldNumber, tag.wireType) {
            case (1, 2):
                let tripData = try reader.readLengthDelimitedData()
                update.trip = try decodeTripDescriptor(from: tripData)
            case (2, 2):
                let stopTimeData = try reader.readLengthDelimitedData()
                update.stopTimeUpdate.append(try decodeStopTimeUpdate(from: stopTimeData))
            default:
                try reader.skipField(wireType: tag.wireType)
            }
        }

        return update
    }

    private static func decodeTripDescriptor(from data: Data) throws -> TransitRealtime_TripDescriptor {
        var reader = ProtobufBinaryReader(data: data)
        var descriptor = TransitRealtime_TripDescriptor()

        while let tag = try reader.readTag() {
            switch (tag.fieldNumber, tag.wireType) {
            case (1, 2):
                descriptor.tripID = try reader.readLengthDelimitedString()
            case (5, 2):
                descriptor.routeID = try reader.readLengthDelimitedString()
            default:
                try reader.skipField(wireType: tag.wireType)
            }
        }

        return descriptor
    }

    private static func decodeStopTimeUpdate(from data: Data) throws -> TransitRealtime_StopTimeUpdate {
        var reader = ProtobufBinaryReader(data: data)
        var stopTimeUpdate = TransitRealtime_StopTimeUpdate()

        while let tag = try reader.readTag() {
            switch (tag.fieldNumber, tag.wireType) {
            case (2, 2):
                let arrivalData = try reader.readLengthDelimitedData()
                stopTimeUpdate.arrival = try decodeStopTimeEvent(from: arrivalData)
            case (3, 2):
                let departureData = try reader.readLengthDelimitedData()
                stopTimeUpdate.departure = try decodeStopTimeEvent(from: departureData)
            case (4, 2):
                stopTimeUpdate.stopID = try reader.readLengthDelimitedString()
            default:
                try reader.skipField(wireType: tag.wireType)
            }
        }

        return stopTimeUpdate
    }

    private static func decodeStopTimeEvent(from data: Data) throws -> TransitRealtime_StopTimeEvent {
        var reader = ProtobufBinaryReader(data: data)
        var event = TransitRealtime_StopTimeEvent()

        while let tag = try reader.readTag() {
            switch (tag.fieldNumber, tag.wireType) {
            case (2, 0):
                event.time = Int64(bitPattern: try reader.readVarint())
            default:
                try reader.skipField(wireType: tag.wireType)
            }
        }

        return event
    }

    private struct Tag {
        let fieldNumber: Int
        let wireType: UInt8
    }

    private struct ProtobufBinaryReader {
        private let data: Data
        private var index: Int

        init(data: Data) {
            self.data = data
            self.index = 0
        }

        var isAtEnd: Bool {
            index >= data.count
        }

        mutating func readTag() throws -> Tag? {
            if isAtEnd {
                return nil
            }

            let key = try readVarint()
            let fieldNumber = Int(key >> 3)
            let wireType = UInt8(key & 0x07)
            return Tag(fieldNumber: fieldNumber, wireType: wireType)
        }

        mutating func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0

            while true {
                guard index < data.count else {
                    throw DecodeError.malformedData
                }

                let byte = data[index]
                index += 1

                result |= UInt64(byte & 0x7F) << shift

                if byte & 0x80 == 0 {
                    return result
                }

                shift += 7
                if shift > 63 {
                    throw DecodeError.malformedData
                }
            }
        }

        mutating func readLengthDelimitedData() throws -> Data {
            let length = try Int(readVarint())
            guard length >= 0, index + length <= data.count else {
                throw DecodeError.malformedData
            }

            let value = data.subdata(in: index..<(index + length))
            index += length
            return value
        }

        mutating func readLengthDelimitedString() throws -> String {
            let bytes = try readLengthDelimitedData()
            guard let value = String(data: bytes, encoding: .utf8) else {
                throw DecodeError.malformedData
            }
            return value
        }

        mutating func skipField(wireType: UInt8) throws {
            switch wireType {
            case 0:
                _ = try readVarint()
            case 1:
                try skip(byteCount: 8)
            case 2:
                let length = try Int(readVarint())
                try skip(byteCount: length)
            case 5:
                try skip(byteCount: 4)
            default:
                throw DecodeError.unsupportedWireType(wireType)
            }
        }

        private mutating func skip(byteCount: Int) throws {
            guard byteCount >= 0, index + byteCount <= data.count else {
                throw DecodeError.malformedData
            }
            index += byteCount
        }
    }
}
