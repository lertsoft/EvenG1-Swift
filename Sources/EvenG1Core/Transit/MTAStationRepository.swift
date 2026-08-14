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
    private enum JSONValue: Decodable, Sendable {
        case string(String)
        case number(Double)
        case object([String: JSONValue])
        case array([JSONValue])
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([String: JSONValue].self) {
                self = .object(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
            }
        }

        var stringValue: String? {
            switch self {
            case .string(let value):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            case .number(let value):
                return value.formatted(.number.grouping(.never))
            default:
                return nil
            }
        }

        var doubleValue: Double? {
            switch self {
            case .number(let value):
                return value
            case .string(let value):
                return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
            default:
                return nil
            }
        }
    }

    private struct StationCacheEnvelope: Codable, Sendable {
        let fetchedAt: Date
        let stations: [MTAStation]
    }

    public static let defaultEndpoint = URL(
        string: "https://data.ny.gov/resource/39hk-dx4f.json?$select=gtfs_stop_id,stop_name,gtfs_latitude,gtfs_longitude&$where=gtfs_stop_id%20IS%20NOT%20NULL%20AND%20gtfs_latitude%20IS%20NOT%20NULL%20AND%20gtfs_longitude%20IS%20NOT%20NULL&$order=gtfs_stop_id&$limit=50000"
    )!

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
            // A cache write is an optimization. A full, valid network response
            // remains usable when the cache directory is temporarily unwritable.
            try? persistDiskCache(envelope)
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
        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.dataReportingRUMResource(for: request)

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
        let rows = try JSONDecoder().decode([[String: JSONValue]].self, from: data)

        var results: [MTAStation] = []
        var seenStationIDs = Set<String>()

        for row in rows {
            let latitude =
                doubleValue(
                    forAnyOf: ["gtfs_latitude", "stop_lat", "latitude", "station_latitude", "entrance_latitude"],
                    in: row
                )
                ?? georeferenceCoordinate(in: row, index: 1)

            let longitude =
                doubleValue(
                    forAnyOf: ["gtfs_longitude", "stop_lon", "longitude", "station_longitude", "entrance_longitude"],
                    in: row
                )
                ?? georeferenceCoordinate(in: row, index: 0)

            guard
                let rawStopID = value(forAnyOf: ["gtfs_stop_id", "stop_id", "GTFS Stop ID"], in: row),
                let stopName = value(forAnyOf: ["stop_name", "station_name", "Stop Name"], in: row),
                let latitude,
                let longitude
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

    private func value(forAnyOf keys: [String], in row: [String: JSONValue]) -> String? {
        for key in keys {
            if let value = row[key]?.stringValue {
                return value
            }
        }
        return nil
    }

    private func doubleValue(forAnyOf keys: [String], in row: [String: JSONValue]) -> Double? {
        for key in keys {
            if let value = row[key]?.doubleValue {
                return value
            }
        }
        return nil
    }

    private func georeferenceCoordinate(in row: [String: JSONValue], index: Int) -> Double? {
        guard
            case .object(let georeference) = row["entrance_georeference"],
            case .array(let coordinates) = georeference["coordinates"],
            coordinates.indices.contains(index)
        else {
            return nil
        }
        return coordinates[index].doubleValue
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
        // v2 invalidates entrance-derived v1 caches now that the canonical
        // station-centroid dataset is used.
        cacheDirectoryURL.appendingPathComponent("mta-stations-cache-v2.json")
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
