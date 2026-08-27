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

        return try await withCheckedThrowingContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                let count = reminders?.filter { reminder in
                    guard !reminder.isCompleted else { return false }
                    guard let due = reminder.dueDateComponents?.date else { return true }
                    return due >= now
                }.count ?? 0
                continuation.resume(returning: count)
            }
        }
    }

    private func requestCalendarAccess() async throws -> Bool {
        if #available(iOS 17.0, *) {
            return try await eventStore.requestFullAccessToEvents()
        }
        return try await withCheckedThrowingContinuation { continuation in
            eventStore.requestAccess(to: .event) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func requestRemindersAccess() async throws -> Bool {
        if #available(iOS 17.0, *) {
            return try await eventStore.requestFullAccessToReminders()
        }
        return try await withCheckedThrowingContinuation { continuation in
            eventStore.requestAccess(to: .reminder) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
