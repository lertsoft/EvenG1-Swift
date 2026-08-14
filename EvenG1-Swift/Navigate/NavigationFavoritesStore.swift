import Foundation
import CoreLocation
import MapKit
import Combine

enum NavigationFavoriteKind: String, Codable, CaseIterable {
    case home
    case office
    case custom
}

struct NavigationFavorite: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: NavigationFavoriteKind
    var title: String
    var subtitle: String
    var latitude: Double?
    var longitude: Double?

    init(id: UUID = UUID(),
         kind: NavigationFavoriteKind,
         title: String,
         subtitle: String = "Set Location",
         latitude: Double? = nil,
         longitude: Double? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var isConfigured: Bool {
        coordinate != nil
    }

    func toMapItem() -> MKMapItem? {
        guard let coordinate else {
            return nil
        }

        let placemark = MKPlacemark(coordinate: coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = title
        return item
    }
}

@MainActor
final class NavigationFavoritesStore: ObservableObject {
    @Published private(set) var favorites: [NavigationFavorite] = []

    private let key = "G1_NavigationFavorites_v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = Self.mergeWithDefaults(loaded: Self.load(key: key, defaults: defaults))
        persist()
    }

    var configuredFavorites: [NavigationFavorite] {
        favorites.filter(\.isConfigured)
    }

    func favorite(for kind: NavigationFavoriteKind) -> NavigationFavorite? {
        favorites.first(where: { $0.kind == kind })
    }

    func setFavorite(kind: NavigationFavoriteKind, mapItem: MKMapItem) {
        guard kind == .home || kind == .office else {
            return
        }

        guard let coordinate = mapItem.placemark.location?.coordinate else {
            return
        }

        let subtitle = mapItem.placemark.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Saved"

        if let index = favorites.firstIndex(where: { $0.kind == kind }) {
            favorites[index].title = kind == .home ? "Home" : "Office"
            favorites[index].subtitle = subtitle.isEmpty ? "Saved" : subtitle
            favorites[index].latitude = coordinate.latitude
            favorites[index].longitude = coordinate.longitude
        }

        persist()
    }

    func addCustom(mapItem: MKMapItem, preferredTitle: String? = nil) {
        guard let coordinate = mapItem.placemark.location?.coordinate else {
            return
        }

        let inferredTitle = preferredTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = inferredTitle.flatMap { $0.isEmpty ? nil : $0 } ?? mapItem.name ?? "Saved Place"
        let subtitle = mapItem.placemark.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Saved"

        let favorite = NavigationFavorite(
            kind: .custom,
            title: title,
            subtitle: subtitle.isEmpty ? "Saved" : subtitle,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        favorites.append(favorite)
        persist()
    }

    func removeCustom(id: UUID) {
        favorites.removeAll { $0.kind == .custom && $0.id == id }
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(favorites)
            defaults.set(data, forKey: key)
        } catch {
            // Keep in-memory state when persistence fails.
        }
    }

    private static func load(key: String, defaults: UserDefaults) -> [NavigationFavorite] {
        guard let data = defaults.data(forKey: key) else {
            return []
        }

        return (try? JSONDecoder().decode([NavigationFavorite].self, from: data)) ?? []
    }

    private static func mergeWithDefaults(loaded: [NavigationFavorite]) -> [NavigationFavorite] {
        let home = loaded.first(where: { $0.kind == .home }) ?? NavigationFavorite(kind: .home, title: "Home")
        let office = loaded.first(where: { $0.kind == .office }) ?? NavigationFavorite(kind: .office, title: "Office")
        let customs = loaded.filter { $0.kind == .custom }
        return [home, office] + customs
    }
}
