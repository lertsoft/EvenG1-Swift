import CoreLocation
import EvenG1Core
import Foundation

enum MTADirectionPreferenceMode: String, Codable, CaseIterable, Identifiable {
    case both
    case uptownOnly
    case downtownOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .both:
            return "Both"
        case .uptownOnly:
            return "Uptown"
        case .downtownOnly:
            return "Downtown"
        }
    }
}

struct MTAStationSelection: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let stationID: String
    let stationName: String
    let latitude: Double
    let longitude: Double
    let distanceMeters: Double?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(stationID: String,
         stationName: String,
         latitude: Double,
         longitude: Double,
         distanceMeters: Double? = nil) {
        self.stationID = stationID
        self.stationName = stationName
        self.latitude = latitude
        self.longitude = longitude
        self.distanceMeters = distanceMeters
        self.id = "\(stationID)-\(String(format: "%.6f", latitude))-\(String(format: "%.6f", longitude))"
    }

    init(station: MTAStation, userCoordinate: CLLocationCoordinate2D?) {
        let distance: Double?
        if let userCoordinate {
            let user = CLLocation(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude)
            let stationLoc = CLLocation(latitude: station.latitude, longitude: station.longitude)
            distance = user.distance(from: stationLoc)
        } else {
            distance = nil
        }

        self.init(
            stationID: station.gtfsStopID,
            stationName: station.stopName,
            latitude: station.latitude,
            longitude: station.longitude,
            distanceMeters: distance
        )
    }

    init(selectedStation: MTASelectedStation) {
        self.init(
            stationID: selectedStation.stationID,
            stationName: selectedStation.stationName,
            latitude: selectedStation.latitude,
            longitude: selectedStation.longitude,
            distanceMeters: selectedStation.distanceMeters
        )
    }
}

enum MTATrainDirectionBucket: String {
    case uptown
    case downtown
    case other
}

nonisolated func mtaDirectionBucket(for direction: String) -> MTATrainDirectionBucket {
    switch direction {
    case "Northbound":
        return .uptown
    case "Southbound":
        return .downtown
    default:
        return .other
    }
}

nonisolated func mtaDirectionDualLabel(for direction: String) -> String {
    switch direction {
    case "Northbound":
        return "Uptown/Northbound"
    case "Southbound":
        return "Downtown/Southbound"
    default:
        return direction
    }
}
