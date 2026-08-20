import CoreLocation
import Foundation
import MapKit

// #region agent log
nonisolated private func agentLog(_ hypothesisId: String, _ message: String, _ data: [String: Any]) {
    let payload: [String: Any] = [
        "sessionId": "bf2a66", "runId": "location", "hypothesisId": hypothesisId,
        "location": "RouteTracker.swift", "message": message, "data": data,
        "timestamp": Int(Date().timeIntervalSince1970 * 1000)
    ]
    guard let json = try? JSONSerialization.data(withJSONObject: payload),
          let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("debug-bf2a66.log") else { return }
    print("AGENTLOG-bf2a66 \(String(decoding: json, as: UTF8.self))")
    var line = json
    line.append(0x0A)
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    } else {
        try? line.write(to: url)
    }
}
// #endregion

struct RouteTrackingUpdate {
    let location: CLLocation
    let nearestStepIndex: Int
    let distanceToNearestStepMeters: CLLocationDistance
    let distanceToManeuverMeters: Int
    let remainingDistanceMeters: Int
    let remainingDurationSeconds: Int
    let isOffRoute: Bool
    let arrived: Bool
}

@MainActor
final class RouteTracker: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var onLocationUpdate: ((CLLocation) -> Void)?
    private var isTracking = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.activityType = .fitness
    }

    func start(onLocationUpdate: @escaping (CLLocation) -> Void) {
        self.onLocationUpdate = onLocationUpdate
        isTracking = true

        // #region agent log
        agentLog("H32", "route tracker start", [
            "authorization": manager.authorizationStatus.rawValue,
            "distanceFilter": manager.distanceFilter,
            "pausesAutomatically": manager.pausesLocationUpdatesAutomatically,
            "allowsBackground": manager.allowsBackgroundLocationUpdates
        ])
        // #endregion

        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    func stop() {
        isTracking = false
        manager.stopUpdatingLocation()
        onLocationUpdate = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isTracking else {
            manager.stopUpdatingLocation()
            return
        }

        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .notDetermined, .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // #region agent log
        agentLog("H32", "core location callback", [
            "count": locations.count,
            "isTracking": isTracking,
            "accuracy": locations.last?.horizontalAccuracy ?? -1,
            "speed": locations.last?.speed ?? -1,
            "ageSeconds": locations.last.map { abs($0.timestamp.timeIntervalSinceNow) } ?? -1
        ])
        // #endregion
        guard isTracking else { return }

        let freshnessThreshold: TimeInterval = 30
        guard let latest = locations.last(where: {
            $0.horizontalAccuracy >= 0
                && abs($0.timestamp.timeIntervalSinceNow) <= freshnessThreshold
        }) else {
            // #region agent log
            agentLog("H32", "core location callback rejected as stale", [
                "count": locations.count
            ])
            // #endregion
            return
        }
        onLocationUpdate?(latest)
    }

    // #region agent log
    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        agentLog("H32", "core location paused updates", ["isTracking": isTracking])
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        agentLog("H32", "core location resumed updates", ["isTracking": isTracking])
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        agentLog("H32", "core location failed", ["error": String(describing: error)])
    }
    // #endregion

    static func evaluate(location: CLLocation,
                         route: MKRoute,
                         currentStepIndex: Int? = nil,
                         offRouteThresholdMeters: CLLocationDistance = 70,
                         arrivalThresholdMeters: CLLocationDistance = 20) -> RouteTrackingUpdate {
        let candidateRange: Range<Int>
        if let currentStepIndex, !route.steps.isEmpty {
            let lowerBound = max(0, min(currentStepIndex, route.steps.count - 1))
            let upperBound = min(route.steps.count, lowerBound + 4)
            candidateRange = lowerBound..<upperBound
        } else {
            candidateRange = route.steps.indices
        }

        var nearestStepIndex = candidateRange.first ?? 0
        var nearestStepDistance = CLLocationDistance.greatestFiniteMagnitude

        for index in candidateRange {
            let step = route.steps[index]
            let distance = distance(from: location, to: step.polyline)
            if distance < nearestStepDistance {
                nearestStepDistance = distance
                nearestStepIndex = index
            }
        }

        let destinationCoordinate = route.polyline.lastCoordinate ?? route.polyline.coordinate
        let destinationDistance = CLLocation(latitude: destinationCoordinate.latitude, longitude: destinationCoordinate.longitude)
            .distance(from: location)
        let arrived = destinationDistance <= arrivalThresholdMeters

        let maneuverCoordinate = route.steps[safe: nearestStepIndex]?.polyline.lastCoordinate ?? destinationCoordinate
        let maneuverDistance = CLLocation(latitude: maneuverCoordinate.latitude, longitude: maneuverCoordinate.longitude)
            .distance(from: location)

        let remainingStepDistance = remainingDistance(route: route, nearestStepIndex: nearestStepIndex, currentLocation: location)
        let remainingDistance = Int(max(0, remainingStepDistance))

        let durationFraction: Double
        if route.distance > 0 {
            durationFraction = max(0, min(1, remainingStepDistance / route.distance))
        } else {
            durationFraction = 0
        }

        let remainingDuration = Int(max(0, route.expectedTravelTime * durationFraction))
        let isOffRoute = !route.steps.isEmpty
            && nearestStepDistance.isFinite
            && nearestStepDistance > offRouteThresholdMeters

        return RouteTrackingUpdate(
            location: location,
            nearestStepIndex: nearestStepIndex,
            distanceToNearestStepMeters: nearestStepDistance,
            distanceToManeuverMeters: Int(max(0, maneuverDistance)),
            remainingDistanceMeters: remainingDistance,
            remainingDurationSeconds: remainingDuration,
            isOffRoute: isOffRoute,
            arrived: arrived
        )
    }

    private static func remainingDistance(route: MKRoute,
                                          nearestStepIndex: Int,
                                          currentLocation: CLLocation) -> CLLocationDistance {
        guard !route.steps.isEmpty else {
            return route.distance
        }

        let clampedIndex = max(0, min(nearestStepIndex, route.steps.count - 1))
        let currentStep = route.steps[clampedIndex]
        let currentStepEndCoordinate = currentStep.polyline.lastCoordinate ?? route.polyline.lastCoordinate ?? route.polyline.coordinate

        let distanceToStepEnd = CLLocation(latitude: currentStepEndCoordinate.latitude,
                                           longitude: currentStepEndCoordinate.longitude)
            .distance(from: currentLocation)

        let laterStepDistance = route.steps.suffix(from: clampedIndex + 1).reduce(0.0) { partial, step in
            partial + step.distance
        }

        return max(0, distanceToStepEnd + laterStepDistance)
    }

    private static func distance(from location: CLLocation, to polyline: MKPolyline) -> CLLocationDistance {
        guard polyline.pointCount > 0 else {
            return .greatestFiniteMagnitude
        }

        let locationPoint = MKMapPoint(location.coordinate)
        let points = polyline.points()

        guard polyline.pointCount > 1 else {
            return locationPoint.distance(to: points[0])
        }

        var minimum = CLLocationDistance.greatestFiniteMagnitude
        var previous = points[0]

        for index in 1..<polyline.pointCount {
            let current = points[index]
            let distance = distance(from: locationPoint, toSegmentFrom: previous, to: current)
            if distance < minimum {
                minimum = distance
            }
            previous = current
        }

        return minimum
    }

    private static func distance(from point: MKMapPoint,
                                 toSegmentFrom start: MKMapPoint,
                                 to end: MKMapPoint) -> CLLocationDistance {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let squaredLength = deltaX * deltaX + deltaY * deltaY

        guard squaredLength > 0 else {
            return point.distance(to: start)
        }

        let projection = ((point.x - start.x) * deltaX + (point.y - start.y) * deltaY) / squaredLength
        let clampedProjection = max(0, min(1, projection))
        let closestPoint = MKMapPoint(
            x: start.x + clampedProjection * deltaX,
            y: start.y + clampedProjection * deltaY
        )
        return point.distance(to: closestPoint)
    }
}

private extension MKPolyline {
    var lastCoordinate: CLLocationCoordinate2D? {
        guard pointCount > 0 else { return nil }

        var coordinate = kCLLocationCoordinate2DInvalid
        withUnsafeMutablePointer(to: &coordinate) { pointer in
            getCoordinates(pointer, range: NSRange(location: pointCount - 1, length: 1))
        }

        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
