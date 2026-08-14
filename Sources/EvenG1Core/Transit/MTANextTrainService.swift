import Foundation
import CoreLocation

public struct MTANextTrainResult: Sendable, Hashable, Identifiable {
    public var id: String {
        "\(stationID)-\(routeID)-\(direction)-\(arrivalTime.timeIntervalSince1970)"
    }
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

public struct MTASelectedStation: Sendable, Hashable {
    public let stationID: String
    public let stationName: String
    public let latitude: Double
    public let longitude: Double
    public let distanceMeters: Double

    public init(stationID: String,
                stationName: String,
                latitude: Double,
                longitude: Double,
                distanceMeters: Double) {
        self.stationID = stationID
        self.stationName = stationName
        self.latitude = latitude
        self.longitude = longitude
        self.distanceMeters = distanceMeters
    }
}

public struct MTAServiceAlert: Sendable {
    public let id: String
    public let effect: String
    public let header: String
    public let description: String?
    public let routeIDs: [String]
    public let stopIDs: [String]
    public let activeStart: Date?
    public let activeEnd: Date?

    public init(
        id: String,
        effect: String,
        header: String,
        description: String?,
        routeIDs: [String],
        stopIDs: [String],
        activeStart: Date?,
        activeEnd: Date?
    ) {
        self.id = id
        self.effect = effect
        self.header = header
        self.description = description
        self.routeIDs = routeIDs
        self.stopIDs = stopIDs
        self.activeStart = activeStart
        self.activeEnd = activeEnd
    }
}

public struct MTATransitQuery: Sendable {
    public let horizonMinutes: Int
    public let preferredStationID: String?
    public let preferredStationName: String?
    public let allowFallbackFromPreferredStation: Bool

    public init(horizonMinutes: Int = 30,
                preferredStationID: String? = nil,
                preferredStationName: String? = nil,
                allowFallbackFromPreferredStation: Bool = true) {
        self.horizonMinutes = max(1, horizonMinutes)
        self.preferredStationID = preferredStationID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preferredStationName = preferredStationName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.allowFallbackFromPreferredStation = allowFallbackFromPreferredStation
    }
}

public struct MTATransitSnapshot: Sendable {
    public let upcomingTrains: [MTANextTrainResult]
    public let alerts: [MTAServiceAlert]
    public let alertsFetchFailed: Bool
    public let selectedStation: MTASelectedStation?
    public let usedFallbackFromPreferredStation: Bool

    public init(upcomingTrains: [MTANextTrainResult],
                alerts: [MTAServiceAlert],
                alertsFetchFailed: Bool,
                selectedStation: MTASelectedStation? = nil,
                usedFallbackFromPreferredStation: Bool = false) {
        self.upcomingTrains = upcomingTrains
        self.alerts = alerts
        self.alertsFetchFailed = alertsFetchFailed
        self.selectedStation = selectedStation
        self.usedFallbackFromPreferredStation = usedFallbackFromPreferredStation
    }
}

public enum MTANextTrainError: Error, Sendable, Equatable {
    case stationDataUnavailable
    case noUpcomingArrival
    case networkFailure(String)
}

public actor MTANextTrainService {
    private let apiKeyProvider: @Sendable () -> String?
    private let stationRepository: any MTAStationProviding
    private let realtimeFeedClient: any MTARealtimeFeedProviding
    private let preferredLanguages: [String]

    public init(apiKeyProvider: @escaping @Sendable () -> String? = { nil },
                session: URLSession = .shared,
                preferredLanguages: [String] = Locale.preferredLanguages) {
        self.apiKeyProvider = apiKeyProvider
        self.stationRepository = MTAStationRepository(session: session)
        self.realtimeFeedClient = MTARealtimeFeedClient(session: session)
        self.preferredLanguages = preferredLanguages
    }

    init(
        apiKeyProvider: @escaping @Sendable () -> String?,
        stationRepository: any MTAStationProviding,
        realtimeFeedClient: any MTARealtimeFeedProviding,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.stationRepository = stationRepository
        self.realtimeFeedClient = realtimeFeedClient
        self.preferredLanguages = preferredLanguages
    }

    public func fetchUpcomingTrains(near coordinate: CLLocationCoordinate2D,
                                    now: Date = Date(),
                                    query: MTATransitQuery = MTATransitQuery()) async throws -> [MTANextTrainResult] {
        let snapshot = try await fetchTransitSnapshot(near: coordinate, now: now, query: query)
        return snapshot.upcomingTrains
    }

    public func fetchTransitSnapshot(near coordinate: CLLocationCoordinate2D,
                                     now: Date = Date(),
                                     query: MTATransitQuery = MTATransitQuery()) async throws -> MTATransitSnapshot {
        // Current public subway and alerts feeds are anonymous. Preserve an
        // optional key only for legacy deployments and compatible proxies.
        let apiKey = normalizedAPIKey() ?? ""

        // These sources are independent. Start them together so the refresh
        // latency is bounded by the slowest request instead of their sum.
        async let stationsRequest = stationRepository.loadStations(now: now)
        async let realtimeFeedsRequest = realtimeFeedClient.fetchSubwayRealtimeFeeds(apiKey: apiKey)
        async let alertsFeedRequest: TransitRealtime_FeedMessage? = try? await realtimeFeedClient
            .fetchSubwayServiceAlertsFeed(apiKey: apiKey)

        let stations: [MTAStation]
        do {
            stations = try await stationsRequest
        } catch {
            throw MTANextTrainError.stationDataUnavailable
        }

        guard !stations.isEmpty else {
            throw MTANextTrainError.stationDataUnavailable
        }

        let feeds: [TransitRealtime_FeedMessage]
        do {
            feeds = try await realtimeFeedsRequest
        } catch {
            throw MTANextTrainError.networkFailure(error.localizedDescription)
        }

        let arrivals = extractUpcomingArrivals(from: feeds, now: now, horizonMinutes: query.horizonMinutes)
        guard !arrivals.isEmpty else {
            throw MTANextTrainError.noUpcomingArrival
        }

        let selected = try selectUpcomingTrains(
            near: coordinate,
            stations: stations,
            arrivals: arrivals,
            now: now,
            query: query
        )

        let alertsFeed = await alertsFeedRequest
        let alertsFetchFailed = alertsFeed == nil
        let alerts: [MTAServiceAlert]
        if let alertsFeed {
            alerts = extractRelevantAlerts(
                from: alertsFeed,
                selectedRouteIDs: selected.routeIDs,
                selectedStationPrefix: selected.stationPrefix,
                now: now
            )
        } else {
            alerts = []
        }

        return MTATransitSnapshot(
            upcomingTrains: selected.results,
            alerts: alerts,
            alertsFetchFailed: alertsFetchFailed,
            selectedStation: selected.selectedStation,
            usedFallbackFromPreferredStation: selected.usedFallbackFromPreferredStation
        )
    }

    private func normalizedAPIKey() -> String? {
        guard let raw = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        let disallowedValues = [
            "__SET_MTA_API_KEY__",
            "$(MTA_API_KEY)",
            "MTA_API_KEY",
            "YOUR_MTA_API_KEY"
        ]
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

    private struct NextTrainSelection: Sendable {
        let results: [MTANextTrainResult]
        let routeIDs: Set<String>
        let stationPrefix: String
        let selectedStation: MTASelectedStation
        let usedFallbackFromPreferredStation: Bool
    }

    private struct ParsedAlert: Sendable {
        let id: String
        let effect: String
        let header: String
        let description: String?
        let routeIDs: Set<String>
        let stopIDs: Set<String>
        let activeStart: Date?
        let activeEnd: Date?
    }

    private struct RankedAlert: Sendable {
        let alert: ParsedAlert
        let score: Int
    }

    private func extractUpcomingArrivals(from feeds: [TransitRealtime_FeedMessage],
                                         now: Date,
                                         horizonMinutes: Int) -> [StopArrival] {
        let horizon = now.addingTimeInterval(TimeInterval(max(1, horizonMinutes) * 60))
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

    private func selectUpcomingTrains(
        near coordinate: CLLocationCoordinate2D,
        stations: [MTAStation],
        arrivals: [StopArrival],
        now: Date,
        query: MTATransitQuery
    ) throws -> NextTrainSelection {
        let userLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let arrivalsByStation = Dictionary(grouping: arrivals) {
            normalizedStationPrefix($0.stopID)
        }.mapValues {
            $0.sorted { $0.arrivalTime < $1.arrivalTime }
        }
        let sortedStations = stations
            .map { station in
                let stationLocation = CLLocation(latitude: station.latitude, longitude: station.longitude)
                let distance = userLocation.distance(from: stationLocation)
                return (station: station, distanceMeters: distance)
            }
            .sorted { $0.distanceMeters < $1.distanceMeters }

        let hasPreferredQuery = (query.preferredStationID?.isEmpty == false) || (query.preferredStationName?.isEmpty == false)

        if hasPreferredQuery {
            let preferredCandidates = sortedStations.filter { stationMatchesQuery($0.station, query: query) }
            if let preferredSelection = buildSelection(
                from: preferredCandidates,
                arrivalsByStation: arrivalsByStation,
                now: now,
                usedFallbackFromPreferredStation: false
            ) {
                return preferredSelection
            }

            guard query.allowFallbackFromPreferredStation else {
                throw MTANextTrainError.noUpcomingArrival
            }

            let fallbackCandidates = sortedStations.filter { !stationMatchesQuery($0.station, query: query) }
            if let fallbackSelection = buildSelection(
                from: fallbackCandidates,
                arrivalsByStation: arrivalsByStation,
                now: now,
                usedFallbackFromPreferredStation: true
            ) {
                return fallbackSelection
            }

            throw MTANextTrainError.noUpcomingArrival
        }

        guard let selection = buildSelection(
            from: sortedStations,
            arrivalsByStation: arrivalsByStation,
            now: now,
            usedFallbackFromPreferredStation: false
        ) else {
            throw MTANextTrainError.noUpcomingArrival
        }

        return selection
    }

    private func buildSelection(from candidates: [(station: MTAStation, distanceMeters: Double)],
                                arrivalsByStation: [String: [StopArrival]],
                                now: Date,
                                usedFallbackFromPreferredStation: Bool) -> NextTrainSelection? {
        for station in candidates {
            let stationPrefix = normalizedStationPrefix(station.station.gtfsStopID)
            guard let stationArrivals = arrivalsByStation[stationPrefix], !stationArrivals.isEmpty else {
                continue
            }

            var results: [MTANextTrainResult] = []
            var routeIDs = Set<String>()

            for match in stationArrivals {
                let interval = match.arrivalTime.timeIntervalSince(now)
                let minutes = max(0, Int(ceil(interval / 60.0)))
                let direction = directionLabel(for: match.stopID)

                results.append(
                    MTANextTrainResult(
                        stationID: station.station.gtfsStopID,
                        stationName: station.station.stopName,
                        distanceMeters: station.distanceMeters,
                        routeID: match.routeID,
                        direction: direction,
                        arrivalTime: match.arrivalTime,
                        minutesAway: minutes
                    )
                )
                routeIDs.insert(match.routeID)
            }

            guard !results.isEmpty else {
                continue
            }

            return NextTrainSelection(
                results: results,
                routeIDs: routeIDs,
                stationPrefix: stationPrefix,
                selectedStation: MTASelectedStation(
                    stationID: station.station.gtfsStopID,
                    stationName: station.station.stopName,
                    latitude: station.station.latitude,
                    longitude: station.station.longitude,
                    distanceMeters: station.distanceMeters
                ),
                usedFallbackFromPreferredStation: usedFallbackFromPreferredStation
            )
        }

        return nil
    }

    private func stationMatchesQuery(_ station: MTAStation, query: MTATransitQuery) -> Bool {
        if let preferredStationID = query.preferredStationID, !preferredStationID.isEmpty {
            let stationPrefix = normalizedStationPrefix(station.gtfsStopID)
            if stationPrefix == normalizedStationPrefix(preferredStationID) {
                return true
            }
        }

        if let preferredStationName = query.preferredStationName, !preferredStationName.isEmpty {
            if normalizedName(station.stopName) == normalizedName(preferredStationName) {
                return true
            }
        }

        return false
    }

    private func extractRelevantAlerts(
        from feed: TransitRealtime_FeedMessage,
        selectedRouteIDs: Set<String>,
        selectedStationPrefix: String,
        now: Date
    ) -> [MTAServiceAlert] {
        let parsedAlerts = parseActiveAlerts(from: feed, now: now)
        let ranked = parsedAlerts.compactMap { alert -> RankedAlert? in
            let score = relevanceScore(
                for: alert,
                selectedRouteIDs: selectedRouteIDs,
                selectedStationPrefix: selectedStationPrefix
            )
            guard score > 0 else {
                return nil
            }
            return RankedAlert(alert: alert, score: score)
        }

        let sorted = ranked.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }

            let lhsStart = lhs.alert.activeStart ?? .distantPast
            let rhsStart = rhs.alert.activeStart ?? .distantPast
            if lhsStart != rhsStart {
                return lhsStart > rhsStart
            }

            return lhs.alert.id < rhs.alert.id
        }

        return sorted.map {
            MTAServiceAlert(
                id: $0.alert.id,
                effect: $0.alert.effect,
                header: $0.alert.header,
                description: $0.alert.description,
                routeIDs: Array($0.alert.routeIDs).sorted(),
                stopIDs: Array($0.alert.stopIDs).sorted(),
                activeStart: $0.alert.activeStart,
                activeEnd: $0.alert.activeEnd
            )
        }
    }

    private func parseActiveAlerts(from feed: TransitRealtime_FeedMessage, now: Date) -> [ParsedAlert] {
        var parsed: [ParsedAlert] = []

        for entity in feed.entity {
            guard let alert = entity.alert, isAlertActive(alert, now: now) else {
                continue
            }

            var routeIDs = Set<String>()
            var stopIDs = Set<String>()

            for selector in alert.informedEntity {
                if let routeID = normalizedNonEmpty(selector.routeID) {
                    routeIDs.insert(routeID)
                }

                if let tripRouteID = selector.trip.flatMap({ normalizedNonEmpty($0.routeID) }) {
                    routeIDs.insert(tripRouteID)
                }

                if let stopID = normalizedNonEmpty(selector.stopID) {
                    stopIDs.insert(normalizedStationPrefix(stopID))
                }
            }

            let header = firstNonEmptyAlertText(alert.headerText)
            let description = firstNonEmptyAlertText(alert.descriptionText)
            let effectText = alert.effect.displayText
            let resolvedHeader = header ?? description ?? effectText
            let resolvedDescription = description.flatMap { text in
                text == resolvedHeader ? nil : text
            }

            let currentPeriod = currentlyActivePeriod(in: alert.activePeriod, now: now)

            parsed.append(
                ParsedAlert(
                    id: entity.id.isEmpty ? UUID().uuidString : entity.id,
                    effect: effectText,
                    header: resolvedHeader,
                    description: resolvedDescription,
                    routeIDs: routeIDs,
                    stopIDs: stopIDs,
                    activeStart: currentPeriod?.start.map {
                        Date(timeIntervalSince1970: TimeInterval($0))
                    },
                    activeEnd: currentPeriod?.end.map {
                        Date(timeIntervalSince1970: TimeInterval($0))
                    }
                )
            )
        }

        return parsed
    }

    private func isAlertActive(_ alert: TransitRealtime_Alert, now: Date) -> Bool {
        alert.activePeriod.isEmpty || currentlyActivePeriod(in: alert.activePeriod, now: now) != nil
    }

    private func currentlyActivePeriod(in periods: [TransitRealtime_TimeRange],
                                       now: Date) -> TransitRealtime_TimeRange? {
        let nowEpoch = Int64(now.timeIntervalSince1970)
        return periods
            .filter { range in
                let start = range.start ?? .min
                let end = range.end ?? .max
                return nowEpoch >= start && nowEpoch < end
            }
            .max { lhs, rhs in
                (lhs.start ?? .min) < (rhs.start ?? .min)
            }
    }

    private func relevanceScore(
        for alert: ParsedAlert,
        selectedRouteIDs: Set<String>,
        selectedStationPrefix: String
    ) -> Int {
        if !alert.routeIDs.isDisjoint(with: selectedRouteIDs) {
            return 3
        }

        if alert.stopIDs.contains(selectedStationPrefix) {
            return 2
        }

        if alert.routeIDs.isEmpty && alert.stopIDs.isEmpty {
            return 1
        }

        return 0
    }

    private func firstNonEmptyAlertText(_ text: TransitRealtime_TranslatedString?) -> String? {
        guard let text else {
            return nil
        }

        let translations = text.translation.compactMap { translation -> (text: String, language: String)? in
            let value = translation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return (value, translation.language.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let languageOrder = preferredLanguages + ["en"]
        for preferredLanguage in languageOrder {
            if let match = translations.first(where: {
                language($0.language, matches: preferredLanguage)
            }) {
                return match.text
            }
        }

        if let unspecified = translations.first(where: { $0.language.isEmpty }) {
            return unspecified.text
        }

        return translations.first?.text
    }

    private func language(_ candidate: String, matches preferred: String) -> Bool {
        let candidate = candidate.lowercased()
        let preferred = preferred.lowercased()
        guard !candidate.isEmpty, !preferred.isEmpty else { return false }
        if candidate == preferred { return true }
        return candidate.split(separator: "-").first == preferred.split(separator: "-").first
    }

    private func normalizedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

    private func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
