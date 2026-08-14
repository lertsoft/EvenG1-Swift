import Foundation
import SwiftProtobuf

fileprivate struct _GeneratedWithProtocGenSwiftVersion: ProtobufAPIVersionCheck {
    struct _2: ProtobufAPIVersion_2 {}
    typealias Version = _2
}

fileprivate let _protobuf_package = "transit_realtime"

public struct GTFSProto_FeedMessage: Sendable {
    public var entity: [GTFSProto_FeedEntity] = []
    public var unknownFields = UnknownStorage()

    public init() {}
}

public struct GTFSProto_FeedEntity: Sendable {
    public var id: String? = nil
    public var isDeleted: Bool? = nil
    public var tripUpdate: GTFSProto_TripUpdate? = nil
    public var alert: GTFSProto_Alert? = nil
    public var unknownFields = UnknownStorage()

    public init() {}
}

public struct GTFSProto_TripUpdate: Sendable {
    public var trip: GTFSProto_TripDescriptor? = nil
    public var stopTimeUpdate: [GTFSProto_StopTimeUpdate] = []
    public var unknownFields = UnknownStorage()

    public init() {}
}

public struct GTFSProto_TripDescriptor: Sendable {
    public var tripID: String? = nil
    public var routeID: String? = nil
    public var unknownFields = UnknownStorage()

    public init() {}
}

public struct GTFSProto_StopTimeUpdate: Sendable {
    public var arrival: GTFSProto_StopTimeEvent? = nil
    public var departure: GTFSProto_StopTimeEvent? = nil
    public var stopID: String? = nil
    public var unknownFields = UnknownStorage()

    public init() {}
}

public struct GTFSProto_StopTimeEvent: Sendable {
    public var time: Int64? = nil
    public var unknownFields = UnknownStorage()

    public init() {}
}

public struct GTFSProto_Alert: Sendable {
    public enum Effect: SwiftProtobuf.Enum, Swift.CaseIterable, Sendable {
        public typealias RawValue = Int

        case noService
        case reducedService
        case significantDelays
        case detour
        case additionalService
        case modifiedService
        case otherEffect
        case unknownEffect
        case stopMoved
        case noEffect
        case accessibilityIssue
        case UNRECOGNIZED(Int)

        public init() {
            self = .unknownEffect
        }

        public init?(rawValue: Int) {
            switch rawValue {
            case 1: self = .noService
            case 2: self = .reducedService
            case 3: self = .significantDelays
            case 4: self = .detour
            case 5: self = .additionalService
            case 6: self = .modifiedService
            case 7: self = .otherEffect
            case 8: self = .unknownEffect
            case 9: self = .stopMoved
            case 10: self = .noEffect
            case 11: self = .accessibilityIssue
            default: self = .UNRECOGNIZED(rawValue)
            }
        }

        public var rawValue: Int {
            switch self {
            case .noService: return 1
            case .reducedService: return 2
            case .significantDelays: return 3
            case .detour: return 4
            case .additionalService: return 5
            case .modifiedService: return 6
            case .otherEffect: return 7
            case .unknownEffect: return 8
            case .stopMoved: return 9
            case .noEffect: return 10
            case .accessibilityIssue: return 11
            case .UNRECOGNIZED(let raw): return raw
            }
        }

        public static let allCases: [GTFSProto_Alert.Effect] = [
            .noService,
            .reducedService,
            .significantDelays,
            .detour,
            .additionalService,
            .modifiedService,
            .otherEffect,
            .unknownEffect,
            .stopMoved,
            .noEffect,
            .accessibilityIssue,
        ]
    }

    public var activePeriod: [GTFSProto_TimeRange] = []
    public var informedEntity: [GTFSProto_EntitySelector] = []
    public var effect: GTFSProto_Alert.Effect? = nil
    public var headerText: GTFSProto_TranslatedString? = nil
    public var descriptionText: GTFSProto_TranslatedString? = nil
    public var unknownFields = UnknownStorage()

    public init() {}
}

public struct GTFSProto_TimeRange: Sendable {
    public var start: UInt64? = nil
    public var end: UInt64? = nil
    public var unknownFields = UnknownStorage()

    public init() {}
}

public struct GTFSProto_EntitySelector: Sendable {
    public var routeID: String? = nil
    public var trip: GTFSProto_TripDescriptor? = nil
    public var stopID: String? = nil
    public var unknownFields = UnknownStorage()

    public init() {}
}

public struct GTFSProto_TranslatedString: Sendable {
    public var translation: [GTFSProto_TranslatedString_Translation] = []
    public var unknownFields = UnknownStorage()

    public init() {}
}

public struct GTFSProto_TranslatedString_Translation: Sendable {
    public var text: String? = nil
    public var language: String? = nil
    public var unknownFields = UnknownStorage()

    public init() {}
}

extension GTFSProto_FeedMessage: Message, _MessageImplementationBase {
    public static let protoMessageName = _protobuf_package + ".FeedMessage"

    public mutating func decodeMessage<D: Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 2: try { try decoder.decodeRepeatedMessageField(value: &self.entity) }()
            default: break
            }
        }
    }

    public func traverse<V: Visitor>(visitor: inout V) throws {
        if !self.entity.isEmpty {
            try visitor.visitRepeatedMessageField(value: self.entity, fieldNumber: 2)
        }
        try self.unknownFields.traverse(visitor: &visitor)
    }
}

extension GTFSProto_FeedEntity: Message, _MessageImplementationBase {
    public static let protoMessageName = _protobuf_package + ".FeedEntity"

    public mutating func decodeMessage<D: Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try { try decoder.decodeSingularStringField(value: &self.id) }()
            case 2: try { try decoder.decodeSingularBoolField(value: &self.isDeleted) }()
            case 3: try { try decoder.decodeSingularMessageField(value: &self.tripUpdate) }()
            case 5: try { try decoder.decodeSingularMessageField(value: &self.alert) }()
            default: break
            }
        }
    }

    public func traverse<V: Visitor>(visitor: inout V) throws {
        try { if let value = self.id {
            try visitor.visitSingularStringField(value: value, fieldNumber: 1)
        } }()
        try { if let value = self.isDeleted {
            try visitor.visitSingularBoolField(value: value, fieldNumber: 2)
        } }()
        try { if let value = self.tripUpdate {
            try visitor.visitSingularMessageField(value: value, fieldNumber: 3)
        } }()
        try { if let value = self.alert {
            try visitor.visitSingularMessageField(value: value, fieldNumber: 5)
        } }()
        try self.unknownFields.traverse(visitor: &visitor)
    }
}

extension GTFSProto_TripUpdate: Message, _MessageImplementationBase {
    public static let protoMessageName = _protobuf_package + ".TripUpdate"

    public mutating func decodeMessage<D: Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try { try decoder.decodeSingularMessageField(value: &self.trip) }()
            case 2: try { try decoder.decodeRepeatedMessageField(value: &self.stopTimeUpdate) }()
            default: break
            }
        }
    }

    public func traverse<V: Visitor>(visitor: inout V) throws {
        try { if let value = self.trip {
            try visitor.visitSingularMessageField(value: value, fieldNumber: 1)
        } }()
        if !self.stopTimeUpdate.isEmpty {
            try visitor.visitRepeatedMessageField(value: self.stopTimeUpdate, fieldNumber: 2)
        }
        try self.unknownFields.traverse(visitor: &visitor)
    }
}

extension GTFSProto_TripDescriptor: Message, _MessageImplementationBase {
    public static let protoMessageName = _protobuf_package + ".TripDescriptor"

    public mutating func decodeMessage<D: Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try { try decoder.decodeSingularStringField(value: &self.tripID) }()
            case 5: try { try decoder.decodeSingularStringField(value: &self.routeID) }()
            default: break
            }
        }
    }

    public func traverse<V: Visitor>(visitor: inout V) throws {
        try { if let value = self.tripID {
            try visitor.visitSingularStringField(value: value, fieldNumber: 1)
        } }()
        try { if let value = self.routeID {
            try visitor.visitSingularStringField(value: value, fieldNumber: 5)
        } }()
        try self.unknownFields.traverse(visitor: &visitor)
    }
}

extension GTFSProto_StopTimeUpdate: Message, _MessageImplementationBase {
    public static let protoMessageName = _protobuf_package + ".TripUpdate.StopTimeUpdate"

    public mutating func decodeMessage<D: Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 2: try { try decoder.decodeSingularMessageField(value: &self.arrival) }()
            case 3: try { try decoder.decodeSingularMessageField(value: &self.departure) }()
            case 4: try { try decoder.decodeSingularStringField(value: &self.stopID) }()
            default: break
            }
        }
    }

    public func traverse<V: Visitor>(visitor: inout V) throws {
        try { if let value = self.arrival {
            try visitor.visitSingularMessageField(value: value, fieldNumber: 2)
        } }()
        try { if let value = self.departure {
            try visitor.visitSingularMessageField(value: value, fieldNumber: 3)
        } }()
        try { if let value = self.stopID {
            try visitor.visitSingularStringField(value: value, fieldNumber: 4)
        } }()
        try self.unknownFields.traverse(visitor: &visitor)
    }
}

extension GTFSProto_StopTimeEvent: Message, _MessageImplementationBase {
    public static let protoMessageName = _protobuf_package + ".TripUpdate.StopTimeEvent"

    public mutating func decodeMessage<D: Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 2: try { try decoder.decodeSingularInt64Field(value: &self.time) }()
            default: break
            }
        }
    }

    public func traverse<V: Visitor>(visitor: inout V) throws {
        try { if let value = self.time {
            try visitor.visitSingularInt64Field(value: value, fieldNumber: 2)
        } }()
        try self.unknownFields.traverse(visitor: &visitor)
    }
}

extension GTFSProto_Alert: Message, _MessageImplementationBase {
    public static let protoMessageName = _protobuf_package + ".Alert"

    public mutating func decodeMessage<D: Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try { try decoder.decodeRepeatedMessageField(value: &self.activePeriod) }()
            case 5: try { try decoder.decodeRepeatedMessageField(value: &self.informedEntity) }()
            case 7: try { try decoder.decodeSingularEnumField(value: &self.effect) }()
            case 10: try { try decoder.decodeSingularMessageField(value: &self.headerText) }()
            case 11: try { try decoder.decodeSingularMessageField(value: &self.descriptionText) }()
            default: break
            }
        }
    }

    public func traverse<V: Visitor>(visitor: inout V) throws {
        if !self.activePeriod.isEmpty {
            try visitor.visitRepeatedMessageField(value: self.activePeriod, fieldNumber: 1)
        }
        if !self.informedEntity.isEmpty {
            try visitor.visitRepeatedMessageField(value: self.informedEntity, fieldNumber: 5)
        }
        try { if let value = self.effect {
            try visitor.visitSingularEnumField(value: value, fieldNumber: 7)
        } }()
        try { if let value = self.headerText {
            try visitor.visitSingularMessageField(value: value, fieldNumber: 10)
        } }()
        try { if let value = self.descriptionText {
            try visitor.visitSingularMessageField(value: value, fieldNumber: 11)
        } }()
        try self.unknownFields.traverse(visitor: &visitor)
    }
}

extension GTFSProto_TimeRange: Message, _MessageImplementationBase {
    public static let protoMessageName = _protobuf_package + ".TimeRange"

    public mutating func decodeMessage<D: Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try { try decoder.decodeSingularUInt64Field(value: &self.start) }()
            case 2: try { try decoder.decodeSingularUInt64Field(value: &self.end) }()
            default: break
            }
        }
    }

    public func traverse<V: Visitor>(visitor: inout V) throws {
        try { if let value = self.start {
            try visitor.visitSingularUInt64Field(value: value, fieldNumber: 1)
        } }()
        try { if let value = self.end {
            try visitor.visitSingularUInt64Field(value: value, fieldNumber: 2)
        } }()
        try self.unknownFields.traverse(visitor: &visitor)
    }
}

extension GTFSProto_EntitySelector: Message, _MessageImplementationBase {
    public static let protoMessageName = _protobuf_package + ".EntitySelector"

    public mutating func decodeMessage<D: Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 2: try { try decoder.decodeSingularStringField(value: &self.routeID) }()
            case 4: try { try decoder.decodeSingularMessageField(value: &self.trip) }()
            case 5: try { try decoder.decodeSingularStringField(value: &self.stopID) }()
            default: break
            }
        }
    }

    public func traverse<V: Visitor>(visitor: inout V) throws {
        try { if let value = self.routeID {
            try visitor.visitSingularStringField(value: value, fieldNumber: 2)
        } }()
        try { if let value = self.trip {
            try visitor.visitSingularMessageField(value: value, fieldNumber: 4)
        } }()
        try { if let value = self.stopID {
            try visitor.visitSingularStringField(value: value, fieldNumber: 5)
        } }()
        try self.unknownFields.traverse(visitor: &visitor)
    }
}

extension GTFSProto_TranslatedString: Message, _MessageImplementationBase {
    public static let protoMessageName = _protobuf_package + ".TranslatedString"

    public mutating func decodeMessage<D: Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try { try decoder.decodeRepeatedMessageField(value: &self.translation) }()
            default: break
            }
        }
    }

    public func traverse<V: Visitor>(visitor: inout V) throws {
        if !self.translation.isEmpty {
            try visitor.visitRepeatedMessageField(value: self.translation, fieldNumber: 1)
        }
        try self.unknownFields.traverse(visitor: &visitor)
    }
}

extension GTFSProto_TranslatedString_Translation: Message, _MessageImplementationBase {
    public static let protoMessageName = _protobuf_package + ".TranslatedString.Translation"

    public mutating func decodeMessage<D: Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try { try decoder.decodeSingularStringField(value: &self.text) }()
            case 2: try { try decoder.decodeSingularStringField(value: &self.language) }()
            default: break
            }
        }
    }

    public func traverse<V: Visitor>(visitor: inout V) throws {
        try { if let value = self.text {
            try visitor.visitSingularStringField(value: value, fieldNumber: 1)
        } }()
        try { if let value = self.language {
            try visitor.visitSingularStringField(value: value, fieldNumber: 2)
        } }()
        try self.unknownFields.traverse(visitor: &visitor)
    }
}
