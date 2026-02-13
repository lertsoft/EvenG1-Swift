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

        let feedProvider = StaticFeedProvider(feeds: [
            makeFeed(routeID: "A", stopID: "A12N", arrivalEpoch: Int64(now.addingTimeInterval(600).timeIntervalSince1970)),
            makeFeed(routeID: "B", stopID: "B34S", arrivalEpoch: Int64(now.addingTimeInterval(120).timeIntervalSince1970))
        ])

        let service = MTANextTrainService(
            apiKeyProvider: { "test-key" },
            stationRepository: stationProvider,
            realtimeFeedClient: feedProvider
        )

        let result = try await service.fetchNextTrain(
            near: CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.9900),
            now: now
        )

        XCTAssertEqual(result.stationID, "A12")
        XCTAssertEqual(result.routeID, "A")
        XCTAssertEqual(result.minutesAway, 10)
    }

    func testSelectsEarliestArrivalAtNearestStation() async throws {
        let now = Date(timeIntervalSince1970: 1_735_689_600)

        let stationProvider = StaticStationProvider(stations: [
            MTAStation(gtfsStopID: "R14", stopName: "Union Sq", latitude: 40.7359, longitude: -73.9911)
        ])

        let feedProvider = StaticFeedProvider(feeds: [
            makeFeed(routeID: "N", stopID: "R14N", arrivalEpoch: Int64(now.addingTimeInterval(480).timeIntervalSince1970)),
            makeFeed(routeID: "Q", stopID: "R14N", arrivalEpoch: Int64(now.addingTimeInterval(180).timeIntervalSince1970))
        ])

        let service = MTANextTrainService(
            apiKeyProvider: { "test-key" },
            stationRepository: stationProvider,
            realtimeFeedClient: feedProvider
        )

        let result = try await service.fetchNextTrain(
            near: CLLocationCoordinate2D(latitude: 40.7360, longitude: -73.9910),
            now: now
        )

        XCTAssertEqual(result.routeID, "Q")
        XCTAssertEqual(result.minutesAway, 3)
    }

    func testFallsBackToNextNearestStationWhenNearestHasNoService() async throws {
        let now = Date(timeIntervalSince1970: 1_735_689_600)

        let stationProvider = StaticStationProvider(stations: [
            MTAStation(gtfsStopID: "A12", stopName: "Nearest", latitude: 40.7501, longitude: -73.9901),
            MTAStation(gtfsStopID: "B34", stopName: "Second", latitude: 40.7510, longitude: -73.9910)
        ])

        let feedProvider = StaticFeedProvider(feeds: [
            makeFeed(routeID: "D", stopID: "B34N", arrivalEpoch: Int64(now.addingTimeInterval(420).timeIntervalSince1970))
        ])

        let service = MTANextTrainService(
            apiKeyProvider: { "test-key" },
            stationRepository: stationProvider,
            realtimeFeedClient: feedProvider
        )

        let result = try await service.fetchNextTrain(
            near: CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.9900),
            now: now
        )

        XCTAssertEqual(result.stationID, "B34")
        XCTAssertEqual(result.routeID, "D")
        XCTAssertEqual(result.minutesAway, 7)
    }

    func testThrowsMissingAPIKeyWhenUnset() async {
        let stationProvider = StaticStationProvider(stations: [])
        let feedProvider = StaticFeedProvider(feeds: [])

        let service = MTANextTrainService(
            apiKeyProvider: { nil },
            stationRepository: stationProvider,
            realtimeFeedClient: feedProvider
        )

        do {
            _ = try await service.fetchNextTrain(near: CLLocationCoordinate2D(latitude: 40.7, longitude: -74.0), now: Date())
            XCTFail("Expected missingAPIKey error")
        } catch let error as MTANextTrainError {
            XCTAssertEqual(error, .missingAPIKey)
        } catch {
            XCTFail("Unexpected error: \(error)")
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
}

private struct StaticStationProvider: MTAStationProviding {
    let stations: [MTAStation]

    func loadStations(now: Date) async throws -> [MTAStation] {
        stations
    }
}

private struct StaticFeedProvider: MTARealtimeFeedProviding {
    let feeds: [TransitRealtime_FeedMessage]

    func fetchAllFeeds(apiKey: String) async throws -> [TransitRealtime_FeedMessage] {
        feeds
    }
}
