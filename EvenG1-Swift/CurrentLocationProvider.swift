import CoreLocation
import Foundation

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
        let status = manager.authorizationStatus
        return try await withCheckedThrowingContinuation { continuation in
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
    }

    private func startLocationRequest() {
        timeoutTask?.cancel()
        manager.requestLocation()

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
            guard let self else { return }
            guard let continuation = self.continuation else { return }
            self.continuation = nil
            continuation.resume(throwing: CurrentLocationError.timeout)
        }
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
        guard let coordinate = locations.last?.coordinate else {
            resolve(.failure(CurrentLocationError.noLocation))
            return
        }

        resolve(.success(coordinate))
    }
}
