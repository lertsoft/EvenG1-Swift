import CoreLocation
import EvenG1Core
import Foundation

struct DashboardTransitSnapshot: Sendable, Equatable {
    var stationName: String
    var rows: [DashboardTransitRow]
}

enum DashboardTransitProviderError: Error {
    case unavailable(String)
}

@MainActor
final class DashboardTransitProvider {
    private let locationProvider: LocationProviding
    private let transitService: MTANextTrainService
    private let stationLockStore: MTAManualStationLockStore

    init(
        locationProvider: LocationProviding,
        transitService: MTANextTrainService = MTANextTrainService(),
        stationLockStore: MTAManualStationLockStore = MTAManualStationLockStore()
    ) {
        self.locationProvider = locationProvider
        self.transitService = transitService
        self.stationLockStore = stationLockStore
    }

    func fetchNearestArrivals(horizonMinutes: Int, now: Date = Date()) async throws -> DashboardTransitSnapshot {
        let coordinate = try await locationProvider.requestOneShotLocation()
        let query = transitQuery(horizonMinutes: horizonMinutes)

        do {
            let snapshot = try await transitService.fetchTransitSnapshot(
                near: coordinate,
                now: now,
                query: query
            )
            let stationName = snapshot.selectedStation?.stationName
                ?? snapshot.upcomingTrains.first?.stationName
                ?? "Nearest station"
            let rows = DashboardTransitMapper.rows(from: snapshot.upcomingTrains)
            guard !rows.isEmpty else {
                throw DashboardTransitProviderError.unavailable("No upcoming arrivals")
            }
            return DashboardTransitSnapshot(stationName: stationName, rows: rows)
        } catch let error as MTANextTrainError {
            throw DashboardTransitProviderError.unavailable(userFacingMessage(for: error))
        } catch {
            throw DashboardTransitProviderError.unavailable(error.localizedDescription)
        }
    }

    private func transitQuery(horizonMinutes: Int) -> MTATransitQuery {
        if let lockedStation = stationLockStore.lockedStation {
            return MTATransitQuery(
                horizonMinutes: horizonMinutes,
                preferredStationID: lockedStation.stationID,
                preferredStationName: lockedStation.stationName,
                allowFallbackFromPreferredStation: true
            )
        }
        return MTATransitQuery(horizonMinutes: horizonMinutes)
    }

    private func userFacingMessage(for error: MTANextTrainError) -> String {
        switch error {
        case .stationDataUnavailable:
            return "Station data unavailable"
        case .noUpcomingArrival:
            return "No upcoming arrivals"
        case .networkFailure(let details):
            return "Feed request failed: \(details)"
        }
    }
}
