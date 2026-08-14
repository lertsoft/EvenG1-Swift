import Combine
import CoreLocation
import EvenG1Core
import Foundation

@MainActor
final class MTAStationPickerViewModel: ObservableObject {
    @Published var query: String = ""
    @Published private(set) var stations: [MTAStationSelection] = []
    @Published private(set) var recentStations: [MTAStationSelection] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let repository: MTAStationRepository
    private let defaults: UserDefaults
    private let recentKey = "G1_MTAStationPickerRecent_v1"

    init(repository: MTAStationRepository = MTAStationRepository(),
         defaults: UserDefaults = .standard) {
        self.repository = repository
        self.defaults = defaults
        self.recentStations = Self.loadRecents(key: recentKey, defaults: defaults)
    }

    var filteredStations: [MTAStationSelection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            return stations
        }

        return stations.filter { station in
            station.stationName.lowercased().contains(trimmed) ||
            station.stationID.lowercased().contains(trimmed)
        }
    }

    func reloadStations(userCoordinate: CLLocationCoordinate2D?) async {
        if isLoading {
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let loaded = try await repository.loadStations(now: Date())
            let mapped = loaded
                .map { MTAStationSelection(station: $0, userCoordinate: userCoordinate) }
                .sorted { lhs, rhs in
                    let lhsDistance = lhs.distanceMeters ?? .greatestFiniteMagnitude
                    let rhsDistance = rhs.distanceMeters ?? .greatestFiniteMagnitude
                    if lhsDistance != rhsDistance {
                        return lhsDistance < rhsDistance
                    }
                    return lhs.stationName < rhs.stationName
                }
            stations = mapped
        } catch {
            errorMessage = "Could not load station list."
        }
    }

    func markRecent(_ station: MTAStationSelection) {
        var updated = recentStations.filter { $0.id != station.id }
        updated.insert(station, at: 0)
        if updated.count > 20 {
            updated = Array(updated.prefix(20))
        }
        recentStations = updated
        persistRecents(updated)
    }

    private func persistRecents(_ values: [MTAStationSelection]) {
        do {
            let data = try JSONEncoder().encode(values)
            defaults.set(data, forKey: recentKey)
        } catch {
            // Keep in-memory state if persistence fails.
        }
    }

    private static func loadRecents(key: String, defaults: UserDefaults) -> [MTAStationSelection] {
        guard let data = defaults.data(forKey: key) else {
            return []
        }
        return (try? JSONDecoder().decode([MTAStationSelection].self, from: data)) ?? []
    }
}
