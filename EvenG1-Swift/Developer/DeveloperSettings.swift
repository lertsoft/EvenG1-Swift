import Combine
import Foundation

/// Gate for the engineering surfaces that used to sit in the main tab bar.
///
/// The flag is persisted so a developer does not have to re-enable it on every
/// launch, and it is off by default so a consumer build never shows raw
/// protocol tooling.
@MainActor
final class DeveloperSettings: ObservableObject {
    private static let developerModeKey = "EvenG1_DeveloperModeEnabled"

    private let defaults: UserDefaults

    @Published var isDeveloperModeEnabled: Bool {
        didSet {
            guard oldValue != isDeveloperModeEnabled else { return }
            defaults.set(isDeveloperModeEnabled, forKey: Self.developerModeKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // UI tests assert that developer surfaces start hidden, so a flag left on
        // by an earlier run must not carry into the next launch.
        let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        self.isDeveloperModeEnabled = isUITesting ? false : defaults.bool(forKey: Self.developerModeKey)
    }
}
