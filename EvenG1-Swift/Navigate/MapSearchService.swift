import Foundation
import MapKit
import Combine

struct MapSearchSuggestion: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    fileprivate let completion: MKLocalSearchCompletion

    var displaySubtitle: String {
        subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class MapSearchService: NSObject, ObservableObject, @preconcurrency MKLocalSearchCompleterDelegate {
    @Published private(set) var suggestions: [MapSearchSuggestion] = []
    @Published private(set) var isSearching: Bool = false

    private let completer: MKLocalSearchCompleter
    private var debounceTask: Task<Void, Never>?
    private var searchRegion: MKCoordinateRegion?
    private var lastQueryFragment: String?

    override init() {
        let completer = MKLocalSearchCompleter()
        completer.resultTypes = [.address, .pointOfInterest]
        self.completer = completer
        super.init()
        self.completer.delegate = self
    }

    func updateRegion(center: CLLocationCoordinate2D) {
        let region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: 25_000,
            longitudinalMeters: 25_000
        )
        searchRegion = region
        completer.region = region

        if let lastQueryFragment, lastQueryFragment.count >= 2 {
            completer.queryFragment = lastQueryFragment
        }
    }

    func updateQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        lastQueryFragment = trimmed.isEmpty ? nil : trimmed

        debounceTask?.cancel()
        if trimmed.count < 2 {
            suggestions = []
            isSearching = false
            return
        }

        isSearching = true
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self else { return }
            self.completer.queryFragment = trimmed
        }
    }

    func clear() {
        debounceTask?.cancel()
        lastQueryFragment = nil
        suggestions = []
        isSearching = false
    }

    func resolve(_ suggestion: MapSearchSuggestion) async throws -> MKMapItem {
        let request = MKLocalSearch.Request(completion: suggestion.completion)
        if let searchRegion {
            request.region = searchRegion
        }
        let response = try await MKLocalSearch(request: request).start()

        if let first = response.mapItems.first {
            return first
        }

        let fallbackPlacemark = MKPlacemark(coordinate: response.boundingRegion.center)
        let fallback = MKMapItem(placemark: fallbackPlacemark)
        fallback.name = suggestion.title
        return fallback
    }

    func resolveNaturalLanguageQuery(_ query: String) async throws -> MKMapItem {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MapSearchError.emptyQuery
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.resultTypes = [.address, .pointOfInterest]
        if let searchRegion {
            request.region = searchRegion
        }

        let response = try await MKLocalSearch(request: request).start()
        if let first = response.mapItems.first {
            return first
        }

        throw MapSearchError.noResults
    }

    // MARK: - MKLocalSearchCompleterDelegate

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = completer.results.map {
            MapSearchSuggestion(title: $0.title, subtitle: $0.subtitle, completion: $0)
        }
        isSearching = false
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        suggestions = []
        isSearching = false
    }
}

enum MapSearchError: Error {
    case emptyQuery
    case noResults
}
