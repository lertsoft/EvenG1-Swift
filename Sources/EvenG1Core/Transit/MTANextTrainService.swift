import Foundation
import CoreLocation

public struct MTANextTrainResult: Sendable {
    public let stationID: String
    public let stationName: String
    public let distanceMeters: Double
    public let routeID: String
    public let direction: String
    public let arrivalTime: Date
    public let minutesAway: Int

    public init(
        stationID: String,
        stationName: String,
        distanceMeters: Double,
        routeID: String,
        direction: String,
        arrivalTime: Date,
        minutesAway: Int
    ) {
        self.stationID = stationID
        self.stationName = stationName
        self.distanceMeters = distanceMeters
        self.routeID = routeID
        self.direction = direction
        self.arrivalTime = arrivalTime
        self.minutesAway = minutesAway
    }
}

public enum MTANextTrainError: Error, Sendable, Equatable {
    case missingAPIKey
    case stationDataUnavailable
    case noUpcomingArrival
    case networkFailure(String)
}

public actor MTANextTrainService {
    private let apiKeyProvider: @Sendable () -> String?
    private let stationRepository: any MTAStationProviding
    private let realtimeFeedClient: any MTARealtimeFeedProviding

    public init(apiKeyProvider: @escaping @Sendable () -> String?, session: URLSession = .shared) {
        self.apiKeyProvider = apiKeyProvider
        self.stationRepository = MTAStationRepository(session: session)
        self.realtimeFeedClient = MTARealtimeFeedClient(session: session)
    }

    init(
        apiKeyProvider: @escaping @Sendable () -> String?,
        stationRepository: any MTAStationProviding,
        realtimeFeedClient: any MTARealtimeFeedProviding
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.stationRepository = stationRepository
        self.realtimeFeedClient = realtimeFeedClient
    }

    public func fetchNextTrain(near coordinate: CLLocationCoordinate2D, now: Date = Date()) async throws -> MTANextTrainResult {
        guard let apiKey = normalizedAPIKey(), !apiKey.isEmpty else {
            throw MTANextTrainError.missingAPIKey
        }

        let stations: [MTAStation]
        do {
            stations = try await stationRepository.loadStations(now: now)
        } catch {
            throw MTANextTrainError.stationDataUnavailable
        }

        guard !stations.isEmpty else {
            throw MTANextTrainError.stationDataUnavailable
        }

        let feeds: [TransitRealtime_FeedMessage]
        do {
            feeds = try await realtimeFeedClient.fetchAllFeeds(apiKey: apiKey)
        } catch {
            throw MTANextTrainError.networkFailure(error.localizedDescription)
        }

        let arrivals = extractUpcomingArrivals(from: feeds, now: now)
        guard !arrivals.isEmpty else {
            throw MTANextTrainError.noUpcomingArrival
        }

        let sortedStations = stations
            .map { station in
                let stationLocation = CLLocation(latitude: station.latitude, longitude: station.longitude)
                let userLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                let distance = userLocation.distance(from: stationLocation)
                return (station: station, distanceMeters: distance)
            }
            .sorted { $0.distanceMeters < $1.distanceMeters }

        for station in sortedStations {
            let stationPrefix = normalizedStationPrefix(station.station.gtfsStopID)
            let match = arrivals
                .filter { normalizedStationPrefix($0.stopID).hasPrefix(stationPrefix) }
                .min { $0.arrivalTime < $1.arrivalTime }

            if let match {
                let interval = match.arrivalTime.timeIntervalSince(now)
                let minutes = max(0, Int(ceil(interval / 60.0)))
                return MTANextTrainResult(
                    stationID: station.station.gtfsStopID,
                    stationName: station.station.stopName,
                    distanceMeters: station.distanceMeters,
                    routeID: match.routeID,
                    direction: directionLabel(for: match.stopID),
                    arrivalTime: match.arrivalTime,
                    minutesAway: minutes
                )
            }
        }

        throw MTANextTrainError.noUpcomingArrival
    }

    private func normalizedAPIKey() -> String? {
        guard let raw = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        let disallowedValues = ["__SET_MTA_API_KEY__", "$(MTA_API_KEY)", "MTA_API_KEY"]
        if disallowedValues.contains(raw) {
            return nil
        }

        return raw
    }

    private struct StopArrival: Sendable {
        let stopID: String
        let routeID: String
        let arrivalTime: Date
    }

    private func extractUpcomingArrivals(from feeds: [TransitRealtime_FeedMessage], now: Date) -> [StopArrival] {
        let horizon = now.addingTimeInterval(2 * 60 * 60)
        var arrivals: [StopArrival] = []

        for feed in feeds {
            for entity in feed.entity {
                guard let tripUpdate = entity.tripUpdate else {
                    continue
                }

                let routeID = tripUpdate.trip.routeID.isEmpty ? "?" : tripUpdate.trip.routeID

                for stopTime in tripUpdate.stopTimeUpdate {
                    guard !stopTime.stopID.isEmpty else {
                        continue
                    }

                    let epoch = stopTime.arrival?.time ?? stopTime.departure?.time
                    guard let epoch else {
                        continue
                    }

                    let arrivalTime = Date(timeIntervalSince1970: TimeInterval(epoch))
                    guard arrivalTime >= now, arrivalTime <= horizon else {
                        continue
                    }

                    arrivals.append(
                        StopArrival(stopID: stopTime.stopID, routeID: routeID, arrivalTime: arrivalTime)
                    )
                }
            }
        }

        return arrivals
    }

    private func normalizedStationPrefix(_ stopID: String) -> String {
        let trimmed = stopID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let suffix = trimmed.last else {
            return trimmed
        }

        if suffix == "N" || suffix == "S" {
            return String(trimmed.dropLast())
        }

        return trimmed
    }

    private func directionLabel(for stopID: String) -> String {
        guard let suffix = stopID.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return "Unknown"
        }

        switch suffix {
        case "N": return "Northbound"
        case "S": return "Southbound"
        case "E": return "Eastbound"
        case "W": return "Westbound"
        default: return "Unknown"
        }
    }
}
