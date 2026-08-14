import Foundation

public enum G1NavigationSubcommand: UInt8, Sendable {
    case setMode = 0x01
    case startSession = 0x02
    case progress = 0x03
    case instruction = 0x04
    case endSession = 0x05
}

public enum G1NavigationPacketError: Error, Equatable {
    case stepOutOfRange
    case totalStepsOutOfRange
    case malformedInstruction
}

public struct G1NavigationPacketBuilder {
    public static let maxInstructionBytes = 120

    public init() {}

    public static func modePacket(mode: G1NavigationMode) -> Data {
        Data([
            G1CompatibilityCommand.navigationPrimary,
            G1NavigationSubcommand.setMode.rawValue,
            mode.rawValue
        ])
    }

    public static func startPacket(mode: G1NavigationMode) -> Data {
        Data([
            G1CompatibilityCommand.navigationPrimary,
            G1NavigationSubcommand.startSession.rawValue,
            mode.rawValue
        ])
    }

    public static func endPacket() -> Data {
        Data([
            G1CompatibilityCommand.navigationPrimary,
            G1NavigationSubcommand.endSession.rawValue
        ])
    }

    public static func progressPacket(_ progress: G1NavigationProgress) throws -> Data {
        guard (0...Int(UInt8.max)).contains(progress.stepIndex) else {
            throw G1NavigationPacketError.stepOutOfRange
        }

        guard (0...Int(UInt8.max)).contains(progress.totalSteps) else {
            throw G1NavigationPacketError.totalStepsOutOfRange
        }

        let distance = UInt16(clamping: progress.remainingDistanceMeters)
        let duration = UInt16(clamping: progress.remainingDurationSeconds)

        let etaMinutes: UInt16
        if let etaEpochSeconds = progress.etaEpochSeconds {
            let now = Int(Date().timeIntervalSince1970)
            let secondsRemaining = max(0, etaEpochSeconds - now)
            etaMinutes = UInt16(clamping: secondsRemaining / 60)
        } else {
            etaMinutes = UInt16.max
        }

        return Data([
            G1CompatibilityCommand.navigationPrimary,
            G1NavigationSubcommand.progress.rawValue,
            UInt8(progress.stepIndex),
            UInt8(progress.totalSteps),
            UInt8((distance >> 8) & 0xFF),
            UInt8(distance & 0xFF),
            UInt8((duration >> 8) & 0xFF),
            UInt8(duration & 0xFF),
            UInt8((etaMinutes >> 8) & 0xFF),
            UInt8(etaMinutes & 0xFF)
        ])
    }

    public static func instructionPacket(_ instruction: G1NavigationInstruction) throws -> Data {
        guard (0...Int(UInt8.max)).contains(instruction.stepIndex) else {
            throw G1NavigationPacketError.stepOutOfRange
        }

        guard (0...Int(UInt8.max)).contains(instruction.totalSteps) else {
            throw G1NavigationPacketError.totalStepsOutOfRange
        }

        let normalized = instruction.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw G1NavigationPacketError.malformedInstruction
        }

        let trimmedText: String
        if let utf8 = normalized.data(using: .utf8), utf8.count <= maxInstructionBytes {
            trimmedText = normalized
        } else {
            trimmedText = truncateToUTF8Boundary(normalized, maxBytes: maxInstructionBytes)
        }

        guard let textData = trimmedText.data(using: .utf8), !textData.isEmpty else {
            throw G1NavigationPacketError.malformedInstruction
        }

        let distanceToManeuver = UInt16(clamping: instruction.distanceToManeuverMeters)
        let remaining = UInt16(clamping: instruction.remainingDistanceMeters)

        let etaMinutes: UInt16
        if let etaEpochSeconds = instruction.etaEpochSeconds {
            let now = Int(Date().timeIntervalSince1970)
            let secondsRemaining = max(0, etaEpochSeconds - now)
            etaMinutes = UInt16(clamping: secondsRemaining / 60)
        } else {
            etaMinutes = UInt16.max
        }

        var bytes: [UInt8] = [
            G1CompatibilityCommand.navigationPrimary,
            G1NavigationSubcommand.instruction.rawValue,
            UInt8(instruction.stepIndex),
            UInt8(instruction.totalSteps),
            UInt8((distanceToManeuver >> 8) & 0xFF),
            UInt8(distanceToManeuver & 0xFF),
            UInt8((remaining >> 8) & 0xFF),
            UInt8(remaining & 0xFF),
            UInt8((etaMinutes >> 8) & 0xFF),
            UInt8(etaMinutes & 0xFF),
            UInt8(textData.count)
        ]
        bytes.append(contentsOf: textData)

        return Data(bytes)
    }

    public static func fallbackSummaryText(mode: G1NavigationMode, progress: G1NavigationProgress) -> String {
        var summary = "\(mode.shortLabel) Step \(max(1, progress.stepIndex + 1))/\(max(1, progress.totalSteps))"
        summary += " | \(progress.remainingDistanceMeters)m left"

        let minutes = max(1, progress.remainingDurationSeconds / 60)
        summary += " | \(minutes)m"
        return summary
    }

    private static func truncateToUTF8Boundary(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else {
            return ""
        }

        var scalarView = ""
        scalarView.reserveCapacity(min(text.count, maxBytes))

        for character in text {
            let candidate = scalarView + String(character)
            guard let data = candidate.data(using: .utf8), data.count <= maxBytes else {
                break
            }
            scalarView = candidate
        }

        return scalarView
    }
}
