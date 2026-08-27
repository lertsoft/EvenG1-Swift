import Foundation

/// Maps MTA arrival results into dashboard transit rows.
public enum DashboardTransitMapper {
    public static func rows(from trains: [MTANextTrainResult], limit: Int = 4) -> [DashboardTransitRow] {
        trains.prefix(max(0, limit)).map { train in
            DashboardTransitRow(
                routeID: train.routeID,
                direction: shortDirection(train.direction),
                minutesAway: train.minutesAway
            )
        }
    }

    public static func shortDirection(_ direction: String) -> String {
        let normalized = direction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "northbound": return "N"
        case "southbound": return "S"
        case "eastbound": return "E"
        case "westbound": return "W"
        default:
            if normalized.hasPrefix("north") { return "N" }
            if normalized.hasPrefix("south") { return "S" }
            if normalized.hasPrefix("east") { return "E" }
            if normalized.hasPrefix("west") { return "W" }
            return String(direction.prefix(1)).uppercased()
        }
    }
}
