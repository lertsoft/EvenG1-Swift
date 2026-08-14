import Foundation

public enum G1NavigationMode: UInt8, CaseIterable, Sendable, Codable {
    case walking = 0x01
    case transit = 0x02
    case biking = 0x03

    public var displayName: String {
        switch self {
        case .walking:
            return "Walking"
        case .transit:
            return "Transit"
        case .biking:
            return "Biking"
        }
    }

    public var shortLabel: String {
        switch self {
        case .walking:
            return "WALK"
        case .transit:
            return "TRANSIT"
        case .biking:
            return "BIKE"
        }
    }
}

public enum G1NavigationTransportMode: String, Sendable, Codable, Equatable {
    case nativePackets
    case textFallback

    public var displayName: String {
        switch self {
        case .nativePackets:
            return "Native"
        case .textFallback:
            return "Text"
        }
    }
}

public enum G1NavigationSessionState: String, Sendable, Codable, Equatable {
    case inactive
    case active
    case rerouting
    case arrived
}

public struct G1NavigationProgress: Sendable, Equatable, Codable {
    public var stepIndex: Int
    public var totalSteps: Int
    public var remainingDistanceMeters: Int
    public var remainingDurationSeconds: Int
    public var etaEpochSeconds: Int?

    public init(stepIndex: Int,
                totalSteps: Int,
                remainingDistanceMeters: Int,
                remainingDurationSeconds: Int,
                etaEpochSeconds: Int?) {
        self.stepIndex = max(0, stepIndex)
        self.totalSteps = max(0, totalSteps)
        self.remainingDistanceMeters = max(0, remainingDistanceMeters)
        self.remainingDurationSeconds = max(0, remainingDurationSeconds)
        self.etaEpochSeconds = etaEpochSeconds
    }
}

public struct G1NavigationInstruction: Sendable, Equatable, Codable {
    public var text: String
    public var stepIndex: Int
    public var totalSteps: Int
    public var distanceToManeuverMeters: Int
    public var remainingDistanceMeters: Int
    public var etaEpochSeconds: Int?

    public init(text: String,
                stepIndex: Int,
                totalSteps: Int,
                distanceToManeuverMeters: Int,
                remainingDistanceMeters: Int,
                etaEpochSeconds: Int?) {
        self.text = text
        self.stepIndex = max(0, stepIndex)
        self.totalSteps = max(0, totalSteps)
        self.distanceToManeuverMeters = max(0, distanceToManeuverMeters)
        self.remainingDistanceMeters = max(0, remainingDistanceMeters)
        self.etaEpochSeconds = etaEpochSeconds
    }

    public func fallbackText(maxLength: Int = 120) -> String {
        let maneuverDistance = max(0, distanceToManeuverMeters)
        let remaining = max(0, remainingDistanceMeters)

        var parts: [String] = []
        if totalSteps > 0 {
            parts.append("\(min(stepIndex + 1, totalSteps))/\(totalSteps)")
        }
        parts.append("In \(maneuverDistance)m")
        parts.append(text)
        parts.append("Rem \(remaining)m")

        if let etaEpochSeconds {
            let etaDate = Date(timeIntervalSince1970: TimeInterval(etaEpochSeconds))
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            parts.append("ETA \(formatter.string(from: etaDate))")
        }

        let joined = parts.joined(separator: " | ")
        return Self.truncated(joined, maxLength: maxLength)
    }

    private static func truncated(_ value: String, maxLength: Int) -> String {
        guard maxLength > 0 else {
            return ""
        }

        if value.count <= maxLength {
            return value
        }

        if maxLength <= 3 {
            return String(value.prefix(maxLength))
        }

        return String(value.prefix(maxLength - 3)) + "..."
    }
}

public enum G1NavigationTraceDirection: String, Sendable, Codable {
    case tx
    case rx
}

public struct G1NavigationTraceEntry: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public let timestamp: Date
    public let direction: G1NavigationTraceDirection
    public let command: UInt8
    public let payloadHex: String
    public let mode: G1NavigationMode?
    public let transportMode: G1NavigationTransportMode
    public let stepIndex: Int?
    public let totalSteps: Int?
    public let remainingDistanceMeters: Int?
    public let etaEpochSeconds: Int?
    public let note: String?

    public init(id: UUID = UUID(),
                timestamp: Date,
                direction: G1NavigationTraceDirection,
                command: UInt8,
                payloadHex: String,
                mode: G1NavigationMode?,
                transportMode: G1NavigationTransportMode,
                stepIndex: Int?,
                totalSteps: Int?,
                remainingDistanceMeters: Int?,
                etaEpochSeconds: Int?,
                note: String?) {
        self.id = id
        self.timestamp = timestamp
        self.direction = direction
        self.command = command
        self.payloadHex = payloadHex
        self.mode = mode
        self.transportMode = transportMode
        self.stepIndex = stepIndex
        self.totalSteps = totalSteps
        self.remainingDistanceMeters = remainingDistanceMeters
        self.etaEpochSeconds = etaEpochSeconds
        self.note = note
    }
}

/// Encodes the manager's newest-first in-memory trace as chronological JSON Lines.
/// A final newline makes the export directly appendable by common JSONL tooling.
public enum G1NavigationTraceExporter {
    public static func jsonLines(newestFirst entries: [G1NavigationTraceEntry]) -> String {
        guard !entries.isEmpty else {
            return ""
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let lines = entries.reversed().compactMap { entry -> String? in
            guard let data = try? encoder.encode(entry) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }

        guard !lines.isEmpty else {
            return ""
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
