import Foundation

/// Minimal NYCT subway extension subset.
/// Included to keep the transit stack aligned with the official NYCT extension schema.
public struct Nyct_StopTimeUpdate: Sendable {
    public var scheduledTrack: String
    public var actualTrack: String

    public init(scheduledTrack: String = "", actualTrack: String = "") {
        self.scheduledTrack = scheduledTrack
        self.actualTrack = actualTrack
    }
}

public struct Nyct_TripDescriptor: Sendable {
    public var trainID: String
    public var isAssigned: Bool

    public init(trainID: String = "", isAssigned: Bool = false) {
        self.trainID = trainID
        self.isAssigned = isAssigned
    }
}
