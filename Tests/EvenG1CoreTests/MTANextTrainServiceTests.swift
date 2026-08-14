import CoreLocation
import Foundation
import XCTest
@testable import EvenG1Core

final class MTANextTrainServiceTests: XCTestCase {
    func testNearestStationWinsWhenItHasService() async throws {
        let now = Date(timeIntervalSince1970: 1_735_689_600)

        let stationProvider = StaticStationProvider(stations: [
            MTAStation(gtfsStopID: "A12", stopName: "Near Station", latitude: 40.7501, longitude: -73.9901),
            MTAStation(gtfsStopID: "B34", stopName: "Far Station", latitude: 40.7000, longitude: -73.9000)
        ])

        let feedProvider = StaticFeedProvider(realtimeFeeds: [
            makeFeed(routeID: "A", stopID: "A12N", arrivalEpoch: Int64(now.addingTimeInterval(600).timeIntervalSince1970)),
            makeFeed(routeID: "B", stopID: "B34S", arrivalEpoch: Int64(now.addingTimeInterval(120).timeIntervalSince1970))
        ])

        let service = MTANextTrainService(
            apiKeyProvider: { "test-key" },
            stationRepository: stationProvider,
            realtimeFeedClient: feedProvider
        )

        let results = try await service.fetchUpcomingTrains(
            near: CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.9900),
            now: now
        )

        XCTAssertEqual(results.first?.stationID, "A12")
        XCTAssertEqual(results.first?.routeID, "A")
        XCTAssertEqual(results.first?.minutesAway, 10)
    }

    func testSelectsEarliestArrivalAtNearestStation() async throws {
        let now = Date(timeIntervalSince1970: 1_735_689_600)

        let stationProvider = StaticStationProvider(stations: [
            MTAStation(gtfsStopID: "R14", stopName: "Union Sq", latitude: 40.7359, longitude: -73.9911)
        ])

        let feedProvider = StaticFeedProvider(realtimeFeeds: [
            makeFeed(routeID: "N", stopID: "R14N", arrivalEpoch: Int64(now.addingTimeInterval(480).timeIntervalSince1970)),
            makeFeed(routeID: "Q", stopID: "R14N", arrivalEpoch: Int64(now.addingTimeInterval(180).timeIntervalSince1970))
        ])

        let service = MTANextTrainService(
            apiKeyProvider: { "test-key" },
            stationRepository: stationProvider,
            realtimeFeedClient: feedProvider
        )

        let results = try await service.fetchUpcomingTrains(
            near: CLLocationCoordinate2D(latitude: 40.7360, longitude: -73.9910),
            now: now
        )

        XCTAssertEqual(results.first?.routeID, "Q")
        XCTAssertEqual(results.first?.minutesAway, 3)
    }

    func testFallsBackToNextNearestStationWhenNearestHasNoService() async throws {
        let now = Date(timeIntervalSince1970: 1_735_689_600)

        let stationProvider = StaticStationProvider(stations: [
            MTAStation(gtfsStopID: "A12", stopName: "Nearest", latitude: 40.7501, longitude: -73.9901),
            MTAStation(gtfsStopID: "B34", stopName: "Second", latitude: 40.7510, longitude: -73.9910)
        ])

        let feedProvider = StaticFeedProvider(realtimeFeeds: [
            makeFeed(routeID: "D", stopID: "B34N", arrivalEpoch: Int64(now.addingTimeInterval(420).timeIntervalSince1970))
        ])

        let service = MTANextTrainService(
            apiKeyProvider: { "test-key" },
            stationRepository: stationProvider,
            realtimeFeedClient: feedProvider
        )

        let results = try await service.fetchUpcomingTrains(
            near: CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.9900),
            now: now
        )

        XCTAssertEqual(results.first?.stationID, "B34")
        XCTAssertEqual(results.first?.routeID, "D")
        XCTAssertEqual(results.first?.minutesAway, 7)
    }

    func testFetchesWithoutAPIKey() async throws {
        let now = Date(timeIntervalSince1970: 1_735_689_600)
        let stationProvider = StaticStationProvider(stations: [
            MTAStation(gtfsStopID: "A12", stopName: "No-Key Station", latitude: 40.7501, longitude: -73.9901)
        ])
        let feedProvider = StaticFeedProvider(realtimeFeeds: [
            makeFeed(
                routeID: "A",
                stopID: "A12N",
                arrivalEpoch: Int64(now.addingTimeInterval(300).timeIntervalSince1970)
            )
        ])

        let service = MTANextTrainService(
            apiKeyProvider: { nil },
            stationRepository: stationProvider,
            realtimeFeedClient: feedProvider
        )

        let results = try await service.fetchUpcomingTrains(
            near: CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.9900),
            now: now
        )

        XCTAssertEqual(results.first?.routeID, "A")
        XCTAssertEqual(results.first?.minutesAway, 5)
    }

    func testLegacyPlaceholdersAreIgnoredRatherThanSentAsAPIKeys() async throws {
        let now = Date(timeIntervalSince1970: 1_735_689_600)
        let placeholders = [
            "__SET_MTA_API_KEY__",
            "$(MTA_API_KEY)",
            "MTA_API_KEY",
            "YOUR_MTA_API_KEY"
        ]

        for placeholder in placeholders {
            let stationProvider = StaticStationProvider(stations: [
                MTAStation(gtfsStopID: "A12", stopName: "Placeholder Station", latitude: 40.7501, longitude: -73.9901)
            ])
            let feedProvider = RecordingFeedProvider(realtimeFeeds: [
                makeFeed(
                    routeID: "A",
                    stopID: "A12N",
                    arrivalEpoch: Int64(now.addingTimeInterval(300).timeIntervalSince1970)
                )
            ])
            let service = MTANextTrainService(
                apiKeyProvider: { placeholder },
                stationRepository: stationProvider,
                realtimeFeedClient: feedProvider
            )

            let results = try await service.fetchUpcomingTrains(
                near: CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.9900),
                now: now
            )
            XCTAssertEqual(results.first?.routeID, "A", "placeholder: \(placeholder)")
            let recordedAPIKeys = await feedProvider.recordedAPIKeys()
            XCTAssertEqual(recordedAPIKeys, ["", ""])
        }
    }

    func testFetchTransitSnapshotRanksRouteThenStationThenGlobalAlerts() async throws {
        let now = Date(timeIntervalSince1970: 1_735_689_600)

        let stationProvider = StaticStationProvider(stations: [
            MTAStation(gtfsStopID: "R14", stopName: "Union Sq", latitude: 40.7359, longitude: -73.9911)
        ])

        let realtimeFeedProvider = StaticFeedProvider(
            realtimeFeeds: [
                makeFeed(routeID: "Q", stopID: "R14N", arrivalEpoch: Int64(now.addingTimeInterval(180).timeIntervalSince1970))
            ],
            alertsFeed: TransitRealtime_FeedMessage(entity: [
                makeAlertEntity(
                    id: "route-alert-newer",
                    effect: .significantDelays,
                    routeIDs: ["Q"],
                    stopIDs: [],
                    header: "Q delays",
                    startEpoch: Int64(now.addingTimeInterval(-60).timeIntervalSince1970),
                    endEpoch: Int64(now.addingTimeInterval(600).timeIntervalSince1970)
                ),
                makeAlertEntity(
                    id: "route-alert-older",
                    effect: .significantDelays,
                    routeIDs: ["Q"],
                    stopIDs: [],
                    header: "Q delays older",
                    startEpoch: Int64(now.addingTimeInterval(-120).timeIntervalSince1970),
                    endEpoch: Int64(now.addingTimeInterval(600).timeIntervalSince1970)
                ),
                makeAlertEntity(
                    id: "station-alert",
                    effect: .detour,
                    routeIDs: [],
                    stopIDs: ["R14N"],
                    header: "R14 station issue",
                    startEpoch: Int64(now.addingTimeInterval(-30).timeIntervalSince1970),
                    endEpoch: Int64(now.addingTimeInterval(300).timeIntervalSince1970)
                ),
                makeAlertEntity(
                    id: "global-alert",
                    effect: .otherEffect,
                    routeIDs: [],
                    stopIDs: [],
                    header: "System-wide notice",
                    startEpoch: Int64(now.addingTimeInterval(-20).timeIntervalSince1970),
                    endEpoch: Int64(now.addingTimeInterval(300).timeIntervalSince1970)
                )
            ])
        )

        let service = MTANextTrainService(
            apiKeyProvider: { "test-key" },
            stationRepository: stationProvider,
            realtimeFeedClient: realtimeFeedProvider
        )

        let snapshot = try await service.fetchTransitSnapshot(
            near: CLLocationCoordinate2D(latitude: 40.7360, longitude: -73.9910),
            now: now
        )

        XCTAssertEqual(snapshot.upcomingTrains.first?.routeID, "Q")
        XCTAssertEqual(snapshot.alertsFetchFailed, false)
        XCTAssertEqual(snapshot.alerts.map(\.id), [
            "route-alert-newer",
            "route-alert-older",
            "station-alert",
            "global-alert"
        ])
    }

    func testFetchTransitSnapshotIgnoresExpiredAlerts() async throws {
        let now = Date(timeIntervalSince1970: 1_735_689_600)

        let stationProvider = StaticStationProvider(stations: [
            MTAStation(gtfsStopID: "R14", stopName: "Union Sq", latitude: 40.7359, longitude: -73.9911)
        ])

        let feedProvider = StaticFeedProvider(
            realtimeFeeds: [
                makeFeed(routeID: "Q", stopID: "R14N", arrivalEpoch: Int64(now.addingTimeInterval(180).timeIntervalSince1970))
            ],
            alertsFeed: TransitRealtime_FeedMessage(entity: [
                makeAlertEntity(
                    id: "expired-alert",
                    effect: .significantDelays,
                    routeIDs: ["Q"],
                    stopIDs: [],
                    header: "Expired",
                    startEpoch: Int64(now.addingTimeInterval(-600).timeIntervalSince1970),
                    endEpoch: Int64(now.addingTimeInterval(-300).timeIntervalSince1970)
                )
            ])
        )

        let service = MTANextTrainService(
            apiKeyProvider: { "test-key" },
            stationRepository: stationProvider,
            realtimeFeedClient: feedProvider
        )

        let snapshot = try await service.fetchTransitSnapshot(
            near: CLLocationCoordinate2D(latitude: 40.7360, longitude: -73.9910),
            now: now
        )

        XCTAssertTrue(snapshot.alerts.isEmpty)
        XCTAssertEqual(snapshot.alertsFetchFailed, false)
    }

    func testFetchTransitSnapshotReturnsTrainWhenAlertsFeedFails() async throws {
        let now = Date(timeIntervalSince1970: 1_735_689_600)

        let stationProvider = StaticStationProvider(stations: [
            MTAStation(gtfsStopID: "R14", stopName: "Union Sq", latitude: 40.7359, longitude: -73.9911)
        ])

        let feedProvider = StaticFeedProvider(
            realtimeFeeds: [
                makeFeed(routeID: "Q", stopID: "R14N", arrivalEpoch: Int64(now.addingTimeInterval(180).timeIntervalSince1970))
            ],
            alertsFeed: TransitRealtime_FeedMessage(),
            alertsError: URLError(.cannotConnectToHost)
        )

        let service = MTANextTrainService(
            apiKeyProvider: { "test-key" },
            stationRepository: stationProvider,
            realtimeFeedClient: feedProvider
        )

        let snapshot = try await service.fetchTransitSnapshot(
            near: CLLocationCoordinate2D(latitude: 40.7360, longitude: -73.9910),
            now: now
        )

        XCTAssertEqual(snapshot.upcomingTrains.first?.routeID, "Q")
        XCTAssertTrue(snapshot.alerts.isEmpty)
        XCTAssertEqual(snapshot.alertsFetchFailed, true)
    }

    func testAlertUsesConfiguredLanguageAndCurrentActivePeriod() async throws {
        let now = Date(timeIntervalSince1970: 1_735_689_600)
        let stationProvider = StaticStationProvider(stations: [
            MTAStation(gtfsStopID: "R14", stopName: "Union Sq", latitude: 40.7359, longitude: -73.9911)
        ])

        let expiredPeriod = TransitRealtime_TimeRange(
            start: Int64(now.addingTimeInterval(-1_200).timeIntervalSince1970),
            end: Int64(now.addingTimeInterval(-900).timeIntervalSince1970)
        )
        let currentPeriod = TransitRealtime_TimeRange(
            start: Int64(now.addingTimeInterval(-60).timeIntervalSince1970),
            end: Int64(now.addingTimeInterval(600).timeIntervalSince1970)
        )
        let localizedHeader = TransitRealtime_TranslatedString(translation: [
            TransitRealtime_Translation(text: "Demoras", language: "es"),
            TransitRealtime_Translation(text: "Delays", language: "en")
        ])
        let alert = TransitRealtime_Alert(
            activePeriod: [expiredPeriod, currentPeriod],
            informedEntity: [TransitRealtime_EntitySelector(routeID: "Q", stopID: "", trip: nil)],
            effect: .significantDelays,
            headerText: localizedHeader,
            descriptionText: nil
        )
        let feedProvider = StaticFeedProvider(
            realtimeFeeds: [
                makeFeed(routeID: "Q", stopID: "R14N", arrivalEpoch: Int64(now.addingTimeInterval(180).timeIntervalSince1970))
            ],
            alertsFeed: TransitRealtime_FeedMessage(entity: [
                TransitRealtime_FeedEntity(id: "localized-alert", tripUpdate: nil, alert: alert)
            ])
        )
        let service = MTANextTrainService(
            apiKeyProvider: { "test-key" },
            stationRepository: stationProvider,
            realtimeFeedClient: feedProvider,
            preferredLanguages: ["en-US"]
        )

        let snapshot = try await service.fetchTransitSnapshot(
            near: CLLocationCoordinate2D(latitude: 40.7360, longitude: -73.9910),
            now: now
        )

        XCTAssertEqual(snapshot.alerts.first?.header, "Delays")
        XCTAssertEqual(
            snapshot.alerts.first?.activeStart,
            currentPeriod.start.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
        XCTAssertEqual(
            snapshot.alerts.first?.activeEnd,
            currentPeriod.end.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    func testTransitQueryHorizonFiltersArrivalsBeyondThirtyMinutes() async throws {
        let now = Date(timeIntervalSince1970: 1_735_689_600)
        let stationProvider = StaticStationProvider(stations: [
            MTAStation(gtfsStopID: "A12", stopName: "Near Station", latitude: 40.7501, longitude: -73.9901)
        ])
        let feedProvider = StaticFeedProvider(realtimeFeeds: [
            makeFeed(routeID: "A", stopID: "A12N", arrivalEpoch: Int64(now.addingTimeInterval(10 * 60).timeIntervalSince1970)),
            makeFeed(routeID: "A", stopID: "A12S", arrivalEpoch: Int64(now.addingTimeInterval(31 * 60).timeIntervalSince1970))
        ])

        let service = MTANextTrainService(
            apiKeyProvider: { "test-key" },
            stationRepository: stationProvider,
            realtimeFeedClient: feedProvider
        )

        let snapshot = try await service.fetchTransitSnapshot(
            near: CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.9900),
            now: now,
            query: MTATransitQuery(horizonMinutes: 30)
        )

        XCTAssertEqual(snapshot.upcomingTrains.count, 1)
        XCTAssertEqual(snapshot.upcomingTrains.first?.minutesAway, 10)
    }

    func testTransitQueryPrefersRequestedStationWhenItHasArrivals() async throws {
        let now = Date(timeIntervalSince1970: 1_735_689_600)
        let stationProvider = StaticStationProvider(stations: [
            MTAStation(gtfsStopID: "A12", stopName: "Near", latitude: 40.7501, longitude: -73.9901),
            MTAStation(gtfsStopID: "B34", stopName: "Locked", latitude: 40.8000, longitude: -73.9500)
        ])
        let feedProvider = StaticFeedProvider(realtimeFeeds: [
            makeFeed(routeID: "A", stopID: "A12N", arrivalEpoch: Int64(now.addingTimeInterval(5 * 60).timeIntervalSince1970)),
            makeFeed(routeID: "D", stopID: "B34S", arrivalEpoch: Int64(now.addingTimeInterval(7 * 60).timeIntervalSince1970))
        ])

        let service = MTANextTrainService(
            apiKeyProvider: { "test-key" },
            stationRepository: stationProvider,
            realtimeFeedClient: feedProvider
        )

        let snapshot = try await service.fetchTransitSnapshot(
            near: CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.9900),
            now: now,
            query: MTATransitQuery(horizonMinutes: 30, preferredStationID: "B34")
        )

        XCTAssertEqual(snapshot.selectedStation?.stationID, "B34")
        XCTAssertFalse(snapshot.usedFallbackFromPreferredStation)
        XCTAssertEqual(snapshot.upcomingTrains.first?.routeID, "D")
    }

    func testTransitQueryFallsBackAndFlagsWhenPreferredStationHasNoArrivals() async throws {
        let now = Date(timeIntervalSince1970: 1_735_689_600)
        let stationProvider = StaticStationProvider(stations: [
            MTAStation(gtfsStopID: "A12", stopName: "Near", latitude: 40.7501, longitude: -73.9901),
            MTAStation(gtfsStopID: "B34", stopName: "Locked", latitude: 40.8000, longitude: -73.9500)
        ])
        let feedProvider = StaticFeedProvider(realtimeFeeds: [
            makeFeed(routeID: "A", stopID: "A12N", arrivalEpoch: Int64(now.addingTimeInterval(5 * 60).timeIntervalSince1970))
        ])

        let service = MTANextTrainService(
            apiKeyProvider: { "test-key" },
            stationRepository: stationProvider,
            realtimeFeedClient: feedProvider
        )

        let snapshot = try await service.fetchTransitSnapshot(
            near: CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.9900),
            now: now,
            query: MTATransitQuery(horizonMinutes: 30, preferredStationID: "B34", allowFallbackFromPreferredStation: true)
        )

        XCTAssertEqual(snapshot.selectedStation?.stationID, "A12")
        XCTAssertTrue(snapshot.usedFallbackFromPreferredStation)
    }

    func testTransitQueryThrowsWhenPreferredStationHasNoArrivalsAndFallbackDisabled() async throws {
        let now = Date(timeIntervalSince1970: 1_735_689_600)
        let stationProvider = StaticStationProvider(stations: [
            MTAStation(gtfsStopID: "A12", stopName: "Near", latitude: 40.7501, longitude: -73.9901),
            MTAStation(gtfsStopID: "B34", stopName: "Locked", latitude: 40.8000, longitude: -73.9500)
        ])
        let feedProvider = StaticFeedProvider(realtimeFeeds: [
            makeFeed(routeID: "A", stopID: "A12N", arrivalEpoch: Int64(now.addingTimeInterval(5 * 60).timeIntervalSince1970))
        ])

        let service = MTANextTrainService(
            apiKeyProvider: { "test-key" },
            stationRepository: stationProvider,
            realtimeFeedClient: feedProvider
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await service.fetchTransitSnapshot(
                near: CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.9900),
                now: now,
                query: MTATransitQuery(horizonMinutes: 30, preferredStationID: "B34", allowFallbackFromPreferredStation: false)
            )
        }
    }

    private func makeFeed(routeID: String, stopID: String, arrivalEpoch: Int64) -> TransitRealtime_FeedMessage {
        let stopTime = TransitRealtime_StopTimeUpdate(
            stopID: stopID,
            arrival: TransitRealtime_StopTimeEvent(time: arrivalEpoch),
            departure: nil
        )
        let trip = TransitRealtime_TripDescriptor(tripID: "trip-\(routeID)", routeID: routeID)
        let tripUpdate = TransitRealtime_TripUpdate(trip: trip, stopTimeUpdate: [stopTime])
        let entity = TransitRealtime_FeedEntity(id: UUID().uuidString, tripUpdate: tripUpdate)
        return TransitRealtime_FeedMessage(entity: [entity])
    }

    private func makeAlertEntity(
        id: String,
        effect: TransitRealtime_AlertEffect,
        routeIDs: [String],
        stopIDs: [String],
        header: String,
        startEpoch: Int64?,
        endEpoch: Int64?
    ) -> TransitRealtime_FeedEntity {
        let informedRouteEntities = routeIDs.map { routeID in
            TransitRealtime_EntitySelector(routeID: routeID, stopID: "", trip: nil)
        }
        let informedStopEntities = stopIDs.map { stopID in
            TransitRealtime_EntitySelector(routeID: "", stopID: stopID, trip: nil)
        }

        let timeRange = TransitRealtime_TimeRange(start: startEpoch, end: endEpoch)
        let headerText = TransitRealtime_TranslatedString(
            translation: [TransitRealtime_Translation(text: header, language: "en")]
        )
        let alert = TransitRealtime_Alert(
            activePeriod: startEpoch == nil && endEpoch == nil ? [] : [timeRange],
            informedEntity: informedRouteEntities + informedStopEntities,
            effect: effect,
            headerText: headerText,
            descriptionText: nil
        )

        return TransitRealtime_FeedEntity(id: id, tripUpdate: nil, alert: alert)
    }
}

private func XCTAssertThrowsErrorAsync(_ expression: @escaping () async throws -> Void,
                                       _ message: @autoclosure () -> String = "",
                                       file: StaticString = #filePath,
                                       line: UInt = #line) async {
    do {
        try await expression()
        XCTFail(message(), file: file, line: line)
    } catch {
        // expected
    }
}

private struct StaticStationProvider: MTAStationProviding {
    let stations: [MTAStation]

    func loadStations(now: Date) async throws -> [MTAStation] {
        stations
    }
}

private struct StaticFeedProvider: MTARealtimeFeedProviding {
    let realtimeFeeds: [TransitRealtime_FeedMessage]
    let alertsFeed: TransitRealtime_FeedMessage
    let alertsError: Error?

    init(
        realtimeFeeds: [TransitRealtime_FeedMessage],
        alertsFeed: TransitRealtime_FeedMessage = TransitRealtime_FeedMessage(),
        alertsError: Error? = nil
    ) {
        self.realtimeFeeds = realtimeFeeds
        self.alertsFeed = alertsFeed
        self.alertsError = alertsError
    }

    func fetchSubwayRealtimeFeeds(apiKey: String) async throws -> [TransitRealtime_FeedMessage] {
        realtimeFeeds
    }

    func fetchSubwayServiceAlertsFeed(apiKey: String) async throws -> TransitRealtime_FeedMessage {
        if let alertsError {
            throw alertsError
        }
        return alertsFeed
    }

    func fetchAllFeeds(apiKey: String) async throws -> [TransitRealtime_FeedMessage] {
        realtimeFeeds
    }
}

private actor RecordingFeedProvider: MTARealtimeFeedProviding {
    private let realtimeFeeds: [TransitRealtime_FeedMessage]
    private var apiKeys: [String] = []

    init(realtimeFeeds: [TransitRealtime_FeedMessage]) {
        self.realtimeFeeds = realtimeFeeds
    }

    func fetchSubwayRealtimeFeeds(apiKey: String) async throws -> [TransitRealtime_FeedMessage] {
        apiKeys.append(apiKey)
        return realtimeFeeds
    }

    func fetchSubwayServiceAlertsFeed(apiKey: String) async throws -> TransitRealtime_FeedMessage {
        apiKeys.append(apiKey)
        return TransitRealtime_FeedMessage()
    }

    func fetchAllFeeds(apiKey: String) async throws -> [TransitRealtime_FeedMessage] {
        apiKeys.append(apiKey)
        return realtimeFeeds
    }

    func recordedAPIKeys() -> [String] {
        apiKeys.sorted()
    }
}
