import CoreLocation
import Foundation
import MapKit
import EvenG1Core

enum RoutePlannerError: Error {
    case noRoute
    case missingDestinationCoordinate
}

struct NavigationRoutePlan {
    let mode: G1NavigationMode
    let destination: MKMapItem
    let destinationName: String
    let route: MKRoute?
    let estimatedDistanceMeters: CLLocationDistance
    let estimatedDurationSeconds: TimeInterval

    var hasInAppRoute: Bool {
        route != nil
    }
}

final class RoutePlanner {
    func planRoute(from source: CLLocationCoordinate2D,
                   to destination: MKMapItem,
                   mode: G1NavigationMode) async throws -> NavigationRoutePlan {
        let destinationName = destination.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? destination.name!
            : "Destination"

        guard destination.placemark.location != nil else {
            throw RoutePlannerError.missingDestinationCoordinate
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: source))
        request.destination = destination
        request.requestsAlternateRoutes = true

        switch mode {
        case .walking:
            request.transportType = .walking
        case .transit:
            request.transportType = .transit
        case .biking:
            request.transportType = .cycling
        }

        let directions = MKDirections(request: request)
        if mode == .transit {
            // MapKit exposes public-transit timing through calculateETA, but
            // does not provide the complete Apple Maps transit itinerary to
            // embedded apps. Never misrepresent an ETA as turn-by-turn steps.
            let eta = try await directions.calculateETA()
            return NavigationRoutePlan(
                mode: mode,
                destination: destination,
                destinationName: destinationName,
                route: nil,
                estimatedDistanceMeters: eta.distance,
                estimatedDurationSeconds: eta.expectedTravelTime
            )
        }

        let response = try await directions.calculate()
        guard let route = response.routes.min(by: {
            if $0.expectedTravelTime == $1.expectedTravelTime {
                return $0.distance < $1.distance
            }
            return $0.expectedTravelTime < $1.expectedTravelTime
        }) else { throw RoutePlannerError.noRoute }

        return NavigationRoutePlan(
            mode: mode,
            destination: destination,
            destinationName: destinationName,
            route: route,
            estimatedDistanceMeters: route.distance,
            estimatedDurationSeconds: route.expectedTravelTime
        )
    }
}
