import EvenG1Core
import Foundation

enum DashboardNewsProviderError: Error {
    case invalidURL
    case fetchFailed(String)
    case parseFailed
}

@MainActor
final class DashboardNewsProvider {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchTopHeadline(feedURLString: String) async throws -> DashboardRSSParser.Headline {
        let trimmed = feedURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), !trimmed.isEmpty else {
            throw DashboardNewsProviderError.invalidURL
        }

        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DashboardNewsProviderError.fetchFailed("HTTP \(http.statusCode)")
        }

        do {
            return try DashboardRSSParser.parseTopHeadline(from: data, feedURL: url)
        } catch {
            throw DashboardNewsProviderError.parseFailed
        }
    }
}
