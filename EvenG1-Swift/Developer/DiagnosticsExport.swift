import SwiftUI
import UIKit
import UniformTypeIdentifiers
import EvenG1Core

/// Plain-text document used for the support-facing diagnostic export and the
/// developer-facing navigation trace.
struct DiagnosticsDocument: FileDocument {
    // Neither the log bundle nor JSON Lines has a system UTType. Generic data
    // preserves the explicit filename instead of letting a `.txt` suffix be appended.
    static var readableContentTypes: [UTType] { [.data] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Builds the single text file a user can hand to support, combining the state
/// and buffers that previously required three separate debug screens to read.
enum DiagnosticsBundle {
    static func text(for bluetoothManager: G1BluetoothManager, appVersion: String = Self.appVersion) -> String {
        var sections: [String] = []

        sections.append(
            """
            EvenG1 Swift diagnostic report
            Generated: \(ISO8601DateFormatter().string(from: Date()))
            App version: \(appVersion)
            iOS: \(UIDevice.current.systemVersion)
            Device: \(UIDevice.current.model)
            """
        )

        sections.append(
            """
            == Connection ==
            State: \(bluetoothManager.connectionState.displayString)
            Scanning: \(bluetoothManager.isScanning)
            Glasses: \(bluetoothManager.connectedGlasses?.displayName ?? "none")
            Left battery: \(batteryText(bluetoothManager.connectedGlasses?.leftBattery))
            Right battery: \(batteryText(bluetoothManager.connectedGlasses?.rightBattery))
            Silent mode: \(bluetoothManager.isSilentModeEnabled ? "on" : "off")
            Brightness: \(bluetoothManager.brightnessLevel)%\(bluetoothManager.isAutoBrightnessEnabled ? " (auto)" : "")
            Microphone: \(bluetoothManager.microphoneState.displayName)
            Navigation session: \(bluetoothManager.navigationSessionState.rawValue)
            Navigation transport: \(bluetoothManager.navigationTransportMode.displayName)
            """
        )

        let logLines = bluetoothManager.diagnostics.logs.map { entry in
            "\(entry.formattedTime) [\(entry.level.rawValue)] \(entry.message)"
        }
        sections.append("== Logs (\(logLines.count)) ==\n" + (logLines.isEmpty ? "none" : logLines.joined(separator: "\n")))

        let eventLines = bluetoothManager.diagnostics.events.map(\.displayString)
        sections.append("== Events (\(eventLines.count)) ==\n" + (eventLines.isEmpty ? "none" : eventLines.joined(separator: "\n")))

        let trace = bluetoothManager.exportNavigationTraceJSONL()
        sections.append("== Navigation trace (\(bluetoothManager.navigationTraceEntries.count)) ==\n" + (trace.isEmpty ? "none" : trace))

        return sections.joined(separator: "\n\n")
    }

    static func filename(prefix: String = "EvenG1-diagnostics", extension pathExtension: String = "txt") -> String {
        "\(prefix)-\(Int(Date().timeIntervalSince1970)).\(pathExtension)"
    }

    static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    private static func batteryText(_ level: Int?) -> String {
        level.map { "\($0)%" } ?? "unknown"
    }
}
