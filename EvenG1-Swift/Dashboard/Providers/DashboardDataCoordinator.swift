import EvenG1Core
import Foundation

/// Cached dashboard data from async providers. The renderer reads snapshots built
/// from this cache, never the live services.
@MainActor
final class DashboardDataCoordinator {
    struct Cache: Equatable {
        var nextEvent: DashboardCalendarEvent?
        var reminderCount: Int?
        var temperature: DashboardTemperature?
        var newsHeadline: DashboardRSSParser.Headline?
        var transit: DashboardTransitSnapshot?

        var calendarError: String?
        var remindersError: String?
        var weatherError: String?
        var newsError: String?
        var transitError: String?

        var lastRefreshedAt: Date?
    }

    private(set) var cache = Cache()

    private let calendarProvider: DashboardCalendarProvider
    private let weatherProvider: DashboardWeatherProvider
    private let newsProvider: DashboardNewsProvider
    private let transitProvider: DashboardTransitProvider

    init(
        calendarProvider: DashboardCalendarProvider = DashboardCalendarProvider(),
        weatherProvider: DashboardWeatherProvider? = nil,
        newsProvider: DashboardNewsProvider = DashboardNewsProvider(),
        transitProvider: DashboardTransitProvider? = nil,
        locationProvider: LocationProviding = CurrentLocationProvider()
    ) {
        self.calendarProvider = calendarProvider
        self.weatherProvider = weatherProvider ?? DashboardWeatherProvider(locationProvider: locationProvider)
        self.newsProvider = newsProvider
        self.transitProvider = transitProvider ?? DashboardTransitProvider(locationProvider: locationProvider)
    }

    func refresh(settings: DashboardSettings, now: Date = Date()) async {
        var updated = cache
        updated.lastRefreshedAt = now

        if settings.calendarEnabled {
            do {
                updated.nextEvent = try await calendarProvider.fetchNextEvent(now: now)
                updated.calendarError = nil
            } catch {
                updated.nextEvent = nil
                updated.calendarError = "Calendar unavailable"
            }
        } else {
            updated.nextEvent = nil
            updated.calendarError = nil
        }

        if settings.remindersEnabled {
            do {
                updated.reminderCount = try await calendarProvider.fetchIncompleteReminderCount(now: now)
                updated.remindersError = nil
            } catch {
                updated.reminderCount = nil
                updated.remindersError = "Reminders unavailable"
            }
        } else {
            updated.reminderCount = nil
            updated.remindersError = nil
        }

        if settings.weatherEnabled {
            do {
                updated.temperature = try await weatherProvider.fetchCurrentTemperature()
                updated.weatherError = nil
            } catch {
                updated.temperature = nil
                updated.weatherError = "Weather unavailable"
            }
        } else {
            updated.temperature = nil
            updated.weatherError = nil
        }

        if settings.selectedWidgets.contains(.news) {
            let feedURL = settings.newsFeedURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if feedURL.isEmpty {
                updated.newsHeadline = nil
                updated.newsError = "Add an RSS feed URL"
            } else {
                do {
                    updated.newsHeadline = try await newsProvider.fetchTopHeadline(feedURLString: feedURL)
                    updated.newsError = nil
                } catch {
                    updated.newsHeadline = nil
                    updated.newsError = "News unavailable"
                }
            }
        } else {
            updated.newsHeadline = nil
            updated.newsError = nil
        }

        let wantsTransit = settings.transitEnabled && settings.selectedWidgets.contains(.transit)
        if wantsTransit {
            do {
                updated.transit = try await transitProvider.fetchNearestArrivals(
                    horizonMinutes: settings.transitHorizonMinutes,
                    now: now
                )
                updated.transitError = nil
            } catch let error as DashboardTransitProviderError {
                updated.transit = nil
                switch error {
                case .unavailable(let message):
                    updated.transitError = message
                }
            } catch {
                updated.transit = nil
                updated.transitError = "Transit unavailable"
            }
        } else {
            updated.transit = nil
            updated.transitError = nil
        }

        cache = updated
    }
}
