import Foundation

public protocol MTARealtimeFeedProviding: Sendable {
    func fetchSubwayRealtimeFeeds(apiKey: String) async throws -> [TransitRealtime_FeedMessage]
    func fetchSubwayServiceAlertsFeed(apiKey: String) async throws -> TransitRealtime_FeedMessage
    func fetchAllFeeds(apiKey: String) async throws -> [TransitRealtime_FeedMessage]
}

public actor MTARealtimeFeedClient: MTARealtimeFeedProviding {
    public static let defaultFeedPaths = [
        "nyct%2Fgtfs",
        "nyct%2Fgtfs-ace",
        "nyct%2Fgtfs-bdfm",
        "nyct%2Fgtfs-g",
        "nyct%2Fgtfs-jz",
        "nyct%2Fgtfs-nqrw",
        "nyct%2Fgtfs-l",
        "nyct%2Fgtfs-7",
        "nyct%2Fgtfs-si"
    ]
    public static let subwayServiceAlertsFeedPath = "camsys%2Fsubway-alerts"

    private let session: URLSession
    private let subwayRealtimeFeedURLs: [URL]
    private let subwayServiceAlertsFeedURL: URL?

    public init(
        session: URLSession = .shared,
        feedPaths: [String] = MTARealtimeFeedClient.defaultFeedPaths,
        subwayServiceAlertsFeedPath: String = MTARealtimeFeedClient.subwayServiceAlertsFeedPath
    ) {
        self.session = session
        self.subwayRealtimeFeedURLs = feedPaths.compactMap {
            URL(string: "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/\($0)")
        }
        self.subwayServiceAlertsFeedURL = URL(
            string: "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/\(subwayServiceAlertsFeedPath)"
        )
    }

    public func fetchAllFeeds(apiKey: String = "") async throws -> [TransitRealtime_FeedMessage] {
        try await fetchSubwayRealtimeFeeds(apiKey: apiKey)
    }

    public func fetchSubwayRealtimeFeeds(apiKey: String = "") async throws -> [TransitRealtime_FeedMessage] {
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let session = self.session
        let feedURLs = self.subwayRealtimeFeedURLs
        guard !feedURLs.isEmpty else {
            return []
        }

        let feeds = await withTaskGroup(of: TransitRealtime_FeedMessage?.self) { group in
            for feedURL in feedURLs {
                group.addTask {
                    try? await Self.fetchFeed(
                        at: feedURL,
                        apiKey: normalizedKey,
                        session: session
                    )
                }
            }

            var feeds: [TransitRealtime_FeedMessage] = []
            for await feed in group {
                if let feed {
                    feeds.append(feed)
                }
            }
            return feeds
        }

        guard !feeds.isEmpty else {
            throw URLError(.cannotLoadFromNetwork)
        }
        return feeds
    }

    public func fetchSubwayServiceAlertsFeed(apiKey: String = "") async throws -> TransitRealtime_FeedMessage {
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let subwayServiceAlertsFeedURL else {
            return TransitRealtime_FeedMessage()
        }

        return try await Self.fetchFeed(
            at: subwayServiceAlertsFeedURL,
            apiKey: normalizedKey,
            session: session
        )
    }

    private static func fetchFeed(
        at url: URL,
        apiKey: String,
        session: URLSession
    ) async throws -> TransitRealtime_FeedMessage {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        if !apiKey.isEmpty {
            // Retained for compatibility with legacy MTA credentials and
            // private proxies. Current public subway feeds require no key.
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.dataReportingRUMResource(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }

        return try TransitRealtime_FeedMessage.decode(from: data)
    }
}
