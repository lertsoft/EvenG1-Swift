import Foundation
import SwiftProtobuf

/// Domain-facing GTFS-Realtime subset used by the MTA transit pipeline.
/// Decoding is backed by SwiftProtobuf message types in GTFSProto.pb.swift.
public struct TransitRealtime_FeedMessage: Sendable {
    public var entity: [TransitRealtime_FeedEntity]

    public init(entity: [TransitRealtime_FeedEntity] = []) {
        self.entity = entity
    }

    public static func decode(from data: Data) throws -> TransitRealtime_FeedMessage {
        let proto = try GTFSProto_FeedMessage(serializedBytes: data)
        let entities = proto.entity.map(TransitRealtime_FeedEntity.init(proto:))
        return TransitRealtime_FeedMessage(entity: entities)
    }
}

public struct TransitRealtime_FeedEntity: Sendable {
    public var id: String
    public var tripUpdate: TransitRealtime_TripUpdate?
    public var alert: TransitRealtime_Alert?

    public init(
        id: String = "",
        tripUpdate: TransitRealtime_TripUpdate? = nil,
        alert: TransitRealtime_Alert? = nil
    ) {
        self.id = id
        self.tripUpdate = tripUpdate
        self.alert = alert
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

public enum TransitRealtime_AlertEffect: String, Sendable {
    case noService = "NO_SERVICE"
    case reducedService = "REDUCED_SERVICE"
    case significantDelays = "SIGNIFICANT_DELAYS"
    case detour = "DETOUR"
    case additionalService = "ADDITIONAL_SERVICE"
    case modifiedService = "MODIFIED_SERVICE"
    case otherEffect = "OTHER_EFFECT"
    case unknownEffect = "UNKNOWN_EFFECT"
    case stopMoved = "STOP_MOVED"
    case noEffect = "NO_EFFECT"
    case accessibilityIssue = "ACCESSIBILITY_ISSUE"
    case unrecognized = "UNRECOGNIZED"

    public var displayText: String {
        switch self {
        case .noService: return "No Service"
        case .reducedService: return "Reduced Service"
        case .significantDelays: return "Significant Delays"
        case .detour: return "Detour"
        case .additionalService: return "Additional Service"
        case .modifiedService: return "Modified Service"
        case .otherEffect: return "Other Effect"
        case .unknownEffect: return "Unknown Effect"
        case .stopMoved: return "Stop Moved"
        case .noEffect: return "No Effect"
        case .accessibilityIssue: return "Accessibility Issue"
        case .unrecognized: return "Service Alert"
        }
    }
}

public struct TransitRealtime_Alert: Sendable {
    public var activePeriod: [TransitRealtime_TimeRange]
    public var informedEntity: [TransitRealtime_EntitySelector]
    public var effect: TransitRealtime_AlertEffect
    public var headerText: TransitRealtime_TranslatedString?
    public var descriptionText: TransitRealtime_TranslatedString?

    public init(
        activePeriod: [TransitRealtime_TimeRange] = [],
        informedEntity: [TransitRealtime_EntitySelector] = [],
        effect: TransitRealtime_AlertEffect = .unknownEffect,
        headerText: TransitRealtime_TranslatedString? = nil,
        descriptionText: TransitRealtime_TranslatedString? = nil
    ) {
        self.activePeriod = activePeriod
        self.informedEntity = informedEntity
        self.effect = effect
        self.headerText = headerText
        self.descriptionText = descriptionText
    }
}

public struct TransitRealtime_TimeRange: Sendable {
    public var start: Int64?
    public var end: Int64?

    public init(start: Int64? = nil, end: Int64? = nil) {
        self.start = start
        self.end = end
    }
}

public struct TransitRealtime_EntitySelector: Sendable {
    public var routeID: String
    public var stopID: String
    public var trip: TransitRealtime_TripDescriptor?

    public init(routeID: String = "", stopID: String = "", trip: TransitRealtime_TripDescriptor? = nil) {
        self.routeID = routeID
        self.stopID = stopID
        self.trip = trip
    }
}

public struct TransitRealtime_TranslatedString: Sendable {
    public var translation: [TransitRealtime_Translation]

    public init(translation: [TransitRealtime_Translation] = []) {
        self.translation = translation
    }

    public var firstText: String? {
        translation.first(where: { !$0.text.isEmpty })?.text
    }
}

public struct TransitRealtime_Translation: Sendable {
    public var text: String
    public var language: String

    public init(text: String = "", language: String = "") {
        self.text = text
        self.language = language
    }
}

private extension TransitRealtime_FeedEntity {
    init(proto: GTFSProto_FeedEntity) {
        self.init(
            id: proto.id ?? "",
            tripUpdate: proto.tripUpdate.map(TransitRealtime_TripUpdate.init(proto:)),
            alert: proto.alert.map(TransitRealtime_Alert.init(proto:))
        )
    }
}

private extension TransitRealtime_TripUpdate {
    init(proto: GTFSProto_TripUpdate) {
        self.init(
            trip: proto.trip.map(TransitRealtime_TripDescriptor.init(proto:)) ?? TransitRealtime_TripDescriptor(),
            stopTimeUpdate: proto.stopTimeUpdate.map(TransitRealtime_StopTimeUpdate.init(proto:))
        )
    }
}

private extension TransitRealtime_TripDescriptor {
    init(proto: GTFSProto_TripDescriptor) {
        self.init(tripID: proto.tripID ?? "", routeID: proto.routeID ?? "")
    }
}

private extension TransitRealtime_StopTimeUpdate {
    init(proto: GTFSProto_StopTimeUpdate) {
        self.init(
            stopID: proto.stopID ?? "",
            arrival: proto.arrival.map(TransitRealtime_StopTimeEvent.init(proto:)),
            departure: proto.departure.map(TransitRealtime_StopTimeEvent.init(proto:))
        )
    }
}

private extension TransitRealtime_StopTimeEvent {
    init(proto: GTFSProto_StopTimeEvent) {
        self.init(time: proto.time)
    }
}

private extension TransitRealtime_Alert {
    init(proto: GTFSProto_Alert) {
        self.init(
            activePeriod: proto.activePeriod.map(TransitRealtime_TimeRange.init(proto:)),
            informedEntity: proto.informedEntity.map(TransitRealtime_EntitySelector.init(proto:)),
            effect: TransitRealtime_AlertEffect(proto: proto.effect),
            headerText: proto.headerText.flatMap(TransitRealtime_TranslatedString.init(proto:)),
            descriptionText: proto.descriptionText.flatMap(TransitRealtime_TranslatedString.init(proto:))
        )
    }
}

private extension TransitRealtime_AlertEffect {
    init(proto: GTFSProto_Alert.Effect?) {
        guard let proto else {
            self = .unknownEffect
            return
        }

        switch proto {
        case .noService: self = .noService
        case .reducedService: self = .reducedService
        case .significantDelays: self = .significantDelays
        case .detour: self = .detour
        case .additionalService: self = .additionalService
        case .modifiedService: self = .modifiedService
        case .otherEffect: self = .otherEffect
        case .unknownEffect: self = .unknownEffect
        case .stopMoved: self = .stopMoved
        case .noEffect: self = .noEffect
        case .accessibilityIssue: self = .accessibilityIssue
        case .UNRECOGNIZED: self = .unrecognized
        }
    }
}

private extension TransitRealtime_TimeRange {
    init(proto: GTFSProto_TimeRange) {
        self.init(start: proto.start.flatMap(Int64.init(exactly:)), end: proto.end.flatMap(Int64.init(exactly:)))
    }
}

private extension TransitRealtime_EntitySelector {
    init(proto: GTFSProto_EntitySelector) {
        self.init(
            routeID: proto.routeID ?? "",
            stopID: proto.stopID ?? "",
            trip: proto.trip.map(TransitRealtime_TripDescriptor.init(proto:))
        )
    }
}

private extension TransitRealtime_TranslatedString {
    init?(proto: GTFSProto_TranslatedString) {
        let translations = proto.translation.map(TransitRealtime_Translation.init(proto:))
        guard !translations.isEmpty else {
            return nil
        }

        self.init(translation: translations)
    }
}

private extension TransitRealtime_Translation {
    init(proto: GTFSProto_TranslatedString_Translation) {
        self.init(text: proto.text ?? "", language: proto.language ?? "")
    }
}
