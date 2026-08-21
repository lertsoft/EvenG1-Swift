import Combine
import EvenG1Core
import Foundation

/// Persists ``DashboardSettings`` behind a versioned `UserDefaults` key, matching
/// the Codable-JSON store pattern used across the app (see `DeveloperSettings`
/// and the MTA stores). Injectable defaults keep it testable.
@MainActor
final class DashboardSettingsStore: ObservableObject {
    private static let storageKey = "G1_DashboardSettings_v1"

    private let defaults: UserDefaults

    @Published var settings: DashboardSettings {
        didSet {
            guard oldValue != settings else { return }
            persist()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(DashboardSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = .default
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
