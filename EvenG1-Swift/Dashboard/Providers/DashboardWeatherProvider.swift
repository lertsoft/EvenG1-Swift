import CoreLocation
import EvenG1Core
import Foundation
import WeatherKit

enum DashboardWeatherProviderError: Error {
    case accessDenied
    case unavailable(String)
}

@MainActor
final class DashboardWeatherProvider {
    private let locationProvider: LocationProviding
    private let weatherService: WeatherService

    init(
        locationProvider: LocationProviding,
        weatherService: WeatherService = .shared
    ) {
        self.locationProvider = locationProvider
        self.weatherService = weatherService
    }

    func fetchCurrentTemperature() async throws -> DashboardTemperature {
        let coordinate = try await locationProvider.requestOneShotLocation()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        do {
            let weather = try await weatherService.weather(for: location)
            let celsius = weather.currentWeather.temperature.converted(to: .celsius).value
            return DashboardTemperature(value: celsius, unit: .celsius)
        } catch {
            throw DashboardWeatherProviderError.unavailable(error.localizedDescription)
        }
    }
}
