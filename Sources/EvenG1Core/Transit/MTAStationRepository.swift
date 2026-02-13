import Foundation

public struct MTAStation: Codable, Sendable {
    public let gtfsStopID: String
    public let stopName: String
    public let latitude: Double
    public let longitude: Double

    public init(gtfsStopID: String, stopName: String, latitude: Double, longitude: Double) {
        self.gtfsStopID = gtfsStopID
        self.stopName = stopName
        self.latitude = latitude
        self.longitude = longitude
    }
}

public protocol MTAStationProviding: Sendable {
    func loadStations(now: Date) async throws -> [MTAStation]
}

public actor MTAStationRepository: MTAStationProviding {
    private struct StationCacheEnvelope: Codable, Sendable {
        let fetchedAt: Date
        let stations: [MTAStation]
    }

    public static let defaultEndpoint = URL(string: "https://data.ny.gov/resource/i9wp-a4ja.json?$select=gtfs_stop_id,stop_name,gtfs_latitude,gtfs_longitude")!

    private let session: URLSession
    private let endpoint: URL
    private let fileManager: FileManager
    private let cacheDirectoryURL: URL
    private let cacheTTL: TimeInterval

    private var inMemoryCache: StationCacheEnvelope?

    public init(
        session: URLSession = .shared,
        endpoint: URL = MTAStationRepository.defaultEndpoint,
        fileManager: FileManager = .default,
        cacheDirectoryURL: URL? = nil,
        cacheTTL: TimeInterval = 24 * 60 * 60
    ) {
        self.session = session
        self.endpoint = endpoint
        self.fileManager = fileManager
        self.cacheDirectoryURL = cacheDirectoryURL
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.cacheTTL = cacheTTL
    }

    public func loadStations(now: Date = Date()) async throws -> [MTAStation] {
        if let inMemoryCache, now.timeIntervalSince(inMemoryCache.fetchedAt) < cacheTTL {
            return inMemoryCache.stations
        }

        if let diskCache = try? loadDiskCache(), now.timeIntervalSince(diskCache.fetchedAt) < cacheTTL {
            inMemoryCache = diskCache
            return diskCache.stations
        }

        do {
            let freshStations = try await fetchStationsFromNetwork()
            let envelope = StationCacheEnvelope(fetchedAt: now, stations: freshStations)
            inMemoryCache = envelope
            try persistDiskCache(envelope)
            return freshStations
        } catch {
            if let fallbackCache = try? loadDiskCache(), !fallbackCache.stations.isEmpty {
                inMemoryCache = fallbackCache
                return fallbackCache.stations
            }
            throw error
        }
    }

    private func fetchStationsFromNetwork() async throws -> [MTAStation] {
        let (data, response) = try await session.data(from: endpoint)

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }

        let stations = try decodeStations(from: data)
        guard !stations.isEmpty else {
            throw URLError(.cannotDecodeContentData)
        }

        return stations
    }

    private func decodeStations(from data: Data) throws -> [MTAStation] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw URLError(.cannotDecodeContentData)
        }

        var results: [MTAStation] = []
        var seenStationIDs = Set<String>()

        for row in rows {
            guard
                let rawStopID = value(forAnyOf: ["gtfs_stop_id", "stop_id", "GTFS Stop ID"], in: row),
                let stopName = value(forAnyOf: ["stop_name", "station_name", "Stop Name"], in: row),
                let latitude = doubleValue(forAnyOf: ["gtfs_latitude", "stop_lat", "latitude", "station_latitude"], in: row),
                let longitude = doubleValue(forAnyOf: ["gtfs_longitude", "stop_lon", "longitude", "station_longitude"], in: row)
            else {
                continue
            }

            let normalizedStopID = Self.normalizedStationStopID(rawStopID)
            guard seenStationIDs.insert(normalizedStopID).inserted else {
                continue
            }

            results.append(
                MTAStation(
                    gtfsStopID: normalizedStopID,
                    stopName: stopName,
                    latitude: latitude,
                    longitude: longitude
                )
            )
        }

        return results
    }

    private func value(forAnyOf keys: [String], in row: [String: Any]) -> String? {
        for key in keys {
            if let value = row[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            } else if let number = row[key] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    private func doubleValue(forAnyOf keys: [String], in row: [String: Any]) -> Double? {
        for key in keys {
            if let value = row[key] as? NSNumber {
                return value.doubleValue
            }
            if let value = row[key] as? String,
               let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }

    private static func normalizedStationStopID(_ rawStopID: String) -> String {
        let trimmed = rawStopID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let suffix = trimmed.last else {
            return trimmed
        }

        if suffix == "N" || suffix == "S" {
            return String(trimmed.dropLast())
        }

        return trimmed
    }

    private func cacheFileURL() -> URL {
        cacheDirectoryURL.appendingPathComponent("mta-stations-cache.json")
    }

    private func loadDiskCache() throws -> StationCacheEnvelope {
        let cacheURL = cacheFileURL()
        let data = try Data(contentsOf: cacheURL)
        return try JSONDecoder().decode(StationCacheEnvelope.self, from: data)
    }

    private func persistDiskCache(_ envelope: StationCacheEnvelope) throws {
        try fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(envelope)
        try data.write(to: cacheFileURL(), options: .atomic)
    }
}
