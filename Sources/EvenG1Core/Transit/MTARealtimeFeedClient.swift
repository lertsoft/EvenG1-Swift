import Foundation

public protocol MTARealtimeFeedProviding: Sendable {
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
        "nyct%2Fgtfs-si"
    ]

    private let session: URLSession
    private let feedURLs: [URL]

    public init(session: URLSession = .shared, feedPaths: [String] = MTARealtimeFeedClient.defaultFeedPaths) {
        self.session = session
        self.feedURLs = feedPaths.compactMap {
            URL(string: "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/\($0)")
        }
    }

    public func fetchAllFeeds(apiKey: String) async throws -> [TransitRealtime_FeedMessage] {
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            return []
        }

        let session = self.session
        let feedURLs = self.feedURLs

        return try await withThrowingTaskGroup(of: TransitRealtime_FeedMessage.self) { group in
            for feedURL in feedURLs {
                group.addTask {
                    var request = URLRequest(url: feedURL)
                    request.httpMethod = "GET"
                    request.setValue(normalizedKey, forHTTPHeaderField: "x-api-key")

                    let (data, response) = try await session.data(for: request)

                    if let httpResponse = response as? HTTPURLResponse,
                       !(200...299).contains(httpResponse.statusCode) {
                        throw URLError(.badServerResponse)
                    }

                    return try TransitRealtime_FeedMessage.decode(from: data)
                }
            }

            var feeds: [TransitRealtime_FeedMessage] = []
            for try await feed in group {
                feeds.append(feed)
            }
            return feeds
        }
    }
}
