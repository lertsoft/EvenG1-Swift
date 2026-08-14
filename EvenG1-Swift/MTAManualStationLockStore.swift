import Combine
import Foundation

struct MTAManualStationLock: Codable, Equatable {
    let stationID: String
    let stationName: String
    let latitude: Double
    let longitude: Double
    let lockedAt: Date

    init(station: MTAStationSelection, lockedAt: Date = Date()) {
        self.stationID = station.stationID
        self.stationName = station.stationName
        self.latitude = station.latitude
        self.longitude = station.longitude
        self.lockedAt = lockedAt
    }

    var asSelection: MTAStationSelection {
        MTAStationSelection(
            stationID: stationID,
            stationName: stationName,
            latitude: latitude,
            longitude: longitude,
            distanceMeters: nil
        )
    }
}

@MainActor
final class MTAManualStationLockStore: ObservableObject {
    @Published private(set) var lockedStation: MTAManualStationLock?

    private let defaults: UserDefaults
    private let key = "G1_MTAManualStationLock_v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.lockedStation = Self.load(key: key, defaults: defaults)
    }

    func setLock(station: MTAStationSelection) {
        lockedStation = MTAManualStationLock(station: station)
        persist()
    }

    func clearLock() {
        lockedStation = nil
        defaults.removeObject(forKey: key)
    }

    private func persist() {
        guard let lockedStation else {
            defaults.removeObject(forKey: key)
            return
        }

        do {
            let data = try JSONEncoder().encode(lockedStation)
            defaults.set(data, forKey: key)
        } catch {
            // Keep in-memory state if persistence fails.
        }
    }

    private static func load(key: String, defaults: UserDefaults) -> MTAManualStationLock? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(MTAManualStationLock.self, from: data)
    }
}
