import Combine
import CoreLocation
import Foundation

struct MTAStationDirectionPreference: Identifiable, Codable, Equatable {
    let id: UUID
    var stationID: String
    var stationName: String
    var latitude: Double
    var longitude: Double
    var mode: MTADirectionPreferenceMode
    var updatedAt: Date

    init(id: UUID = UUID(),
         stationID: String,
         stationName: String,
         latitude: Double,
         longitude: Double,
         mode: MTADirectionPreferenceMode,
         updatedAt: Date = Date()) {
        self.id = id
        self.stationID = stationID
        self.stationName = stationName
        self.latitude = latitude
        self.longitude = longitude
        self.mode = mode
        self.updatedAt = updatedAt
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

@MainActor
final class MTAStationDirectionPreferencesStore: ObservableObject {
    @Published private(set) var preferences: [MTAStationDirectionPreference] = []

    private let defaults: UserDefaults
    private let key = "G1_MTAStationDirectionPreferences_v1"

    private let matchingRadiusMeters: Double = 400
    private let mergeRadiusMeters: Double = 150

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.preferences = Self.load(key: key, defaults: defaults)
    }

    func preferenceMode(for station: MTAStationSelection) -> MTADirectionPreferenceMode {
        guard let match = closestMatch(for: station, maxDistanceMeters: matchingRadiusMeters) else {
            return .both
        }
        return match.mode
    }

    func setPreferenceMode(_ mode: MTADirectionPreferenceMode, for station: MTAStationSelection) {
        if mode == .both {
            clearPreference(for: station)
            return
        }

        if let existing = closestMatch(for: station, maxDistanceMeters: mergeRadiusMeters),
           let index = preferences.firstIndex(where: { $0.id == existing.id }) {
            preferences[index].stationID = station.stationID
            preferences[index].stationName = station.stationName
            preferences[index].latitude = station.latitude
            preferences[index].longitude = station.longitude
            preferences[index].mode = mode
            preferences[index].updatedAt = Date()
        } else {
            preferences.append(
                MTAStationDirectionPreference(
                    stationID: station.stationID,
                    stationName: station.stationName,
                    latitude: station.latitude,
                    longitude: station.longitude,
                    mode: mode
                )
            )
        }

        persist()
    }

    func clearPreference(for station: MTAStationSelection) {
        guard let match = closestMatch(for: station, maxDistanceMeters: matchingRadiusMeters) else {
            return
        }
        preferences.removeAll { $0.id == match.id }
        persist()
    }

    func removePreference(id: UUID) {
        preferences.removeAll { $0.id == id }
        persist()
    }

    private func closestMatch(for station: MTAStationSelection, maxDistanceMeters: Double) -> MTAStationDirectionPreference? {
        let normalizedTargetName = normalizedName(station.stationName)
        let targetLocation = CLLocation(latitude: station.latitude, longitude: station.longitude)

        return preferences
            .filter { normalizedName($0.stationName) == normalizedTargetName }
            .compactMap { preference -> (MTAStationDirectionPreference, Double)? in
                let preferenceLocation = CLLocation(latitude: preference.latitude, longitude: preference.longitude)
                let distance = targetLocation.distance(from: preferenceLocation)
                guard distance <= maxDistanceMeters else {
                    return nil
                }
                return (preference, distance)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 < rhs.1
                }
                return lhs.0.updatedAt > rhs.0.updatedAt
            }
            .first?
            .0
    }

    private func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(preferences)
            defaults.set(data, forKey: key)
        } catch {
            // Keep in-memory state if persistence fails.
        }
    }

    private static func load(key: String, defaults: UserDefaults) -> [MTAStationDirectionPreference] {
        guard let data = defaults.data(forKey: key) else {
            return []
        }
        return (try? JSONDecoder().decode([MTAStationDirectionPreference].self, from: data)) ?? []
    }
}
