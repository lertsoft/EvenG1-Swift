import CoreLocation
import Foundation

@MainActor
protocol LocationProviding {
    func requestOneShotLocation() async throws -> CLLocationCoordinate2D
}

enum CurrentLocationError: Error {
    case servicesDisabled
    case deniedOrRestricted
    case timeout
    case noLocation
    case underlying(String)
}

@MainActor
final class CurrentLocationProvider: NSObject, LocationProviding, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D, Error>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestOneShotLocation() async throws -> CLLocationCoordinate2D {
        guard CLLocationManager.locationServicesEnabled() else {
            throw CurrentLocationError.servicesDisabled
        }

        guard continuation == nil else {
            throw CurrentLocationError.underlying("Another location request is already in progress.")
        }

        let status = manager.authorizationStatus
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation

                switch status {
                case .denied, .restricted:
                    self.resolve(.failure(CurrentLocationError.deniedOrRestricted))
                case .authorizedAlways, .authorizedWhenInUse:
                    self.startLocationRequest()
                case .notDetermined:
                    self.manager.requestWhenInUseAuthorization()
                @unknown default:
                    self.resolve(.failure(CurrentLocationError.deniedOrRestricted))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingRequest()
            }
        }
    }

    private func startLocationRequest() {
        timeoutTask?.cancel()
        manager.requestLocation()

        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            self?.resolve(.failure(CurrentLocationError.timeout))
        }
    }

    private func cancelPendingRequest() {
        manager.stopUpdatingLocation()
        resolve(.failure(CancellationError()))
    }

    private func resolve(_ result: Result<CLLocationCoordinate2D, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil

        guard let continuation else { return }
        self.continuation = nil

        switch result {
        case .success(let coordinate):
            continuation.resume(returning: coordinate)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if continuation != nil {
                startLocationRequest()
            }
        case .denied, .restricted:
            resolve(.failure(CurrentLocationError.deniedOrRestricted))
        case .notDetermined:
            break
        @unknown default:
            resolve(.failure(CurrentLocationError.deniedOrRestricted))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let clError = error as? CLError, clError.code == .denied {
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                resolve(.failure(CurrentLocationError.servicesDisabled))
            case .denied, .restricted, .notDetermined:
                resolve(.failure(CurrentLocationError.deniedOrRestricted))
            @unknown default:
                resolve(.failure(CurrentLocationError.deniedOrRestricted))
            }
            return
        }

        resolve(.failure(CurrentLocationError.underlying(error.localizedDescription)))
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let freshnessThreshold: TimeInterval = 60
        guard let location = locations.last(where: {
            $0.horizontalAccuracy >= 0
                && abs($0.timestamp.timeIntervalSinceNow) <= freshnessThreshold
        }) else {
            resolve(.failure(CurrentLocationError.noLocation))
            return
        }

        resolve(.success(location.coordinate))
    }
}
