import EventKit
import EvenG1Core
import Foundation

enum DashboardCalendarProviderError: Error {
    case accessDenied
    case unavailable
}

@MainActor
final class DashboardCalendarProvider {
    private let eventStore = EKEventStore()

    func fetchNextEvent(now: Date = Date()) async throws -> DashboardCalendarEvent? {
        let granted = try await requestCalendarAccess()
        guard granted else { throw DashboardCalendarProviderError.accessDenied }

        let calendars = eventStore.calendars(for: .event)
        guard !calendars.isEmpty else { return nil }

        let predicate = eventStore.predicateForEvents(
            withStart: now,
            end: now.addingTimeInterval(7 * 24 * 60 * 60),
            calendars: calendars
        )
        let events = eventStore.events(matching: predicate)
            .filter { $0.startDate >= now }
            .sorted { $0.startDate < $1.startDate }

        guard let event = events.first else { return nil }

        return DashboardCalendarEvent(
            title: event.title ?? "Event",
            startTime: event.startDate,
            endTime: event.isAllDay ? nil : event.endDate
        )
    }

    func fetchIncompleteReminderCount(now: Date = Date()) async throws -> Int {
        let granted = try await requestRemindersAccess()
        guard granted else { throw DashboardCalendarProviderError.accessDenied }

        let calendars = eventStore.calendars(for: .reminder)
        guard !calendars.isEmpty else { return 0 }

        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: calendars
        )

        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                // EventKit invokes this callback on its private reminders-search
                // queue. A nested collection closure inherits the provider's
                // @MainActor isolation and traps there, so inspect EventKit's
                // non-Sendable objects directly and cross the continuation with
                // only the Sendable count.
                var count = 0
                for reminder in reminders ?? [] {
                    guard !reminder.isCompleted else { continue }
                    guard let due = reminder.dueDateComponents?.date else {
                        count += 1
                        continue
                    }
                    if due >= now {
                        count += 1
                    }
                }

                continuation.resume(returning: count)
            }
        }
    }

    private func requestCalendarAccess() async throws -> Bool {
        try await eventStore.requestFullAccessToEvents()
    }

    private func requestRemindersAccess() async throws -> Bool {
        try await eventStore.requestFullAccessToReminders()
    }
}
