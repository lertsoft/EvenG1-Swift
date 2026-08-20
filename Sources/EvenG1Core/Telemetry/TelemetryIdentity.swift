import Foundation

/// Privacy-safe install identifier for correlating RUM sessions without PII.
public enum TelemetryIdentity {
    private static let defaultsKey = "com.eveng1.telemetry.install_id"

    public static func anonymousInstallID() -> String {
        if let existing = UserDefaults.standard.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }

        let generated = UUID().uuidString.lowercased()
        UserDefaults.standard.set(generated, forKey: defaultsKey)
        return generated
    }
}

public enum TelemetryBuildInfo {
    public static var marketingVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    public static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }

    public static var rumViewAttributes: [String: String] {
        [
            "app.version": marketingVersion,
            "app.build": buildNumber
        ]
    }
}
