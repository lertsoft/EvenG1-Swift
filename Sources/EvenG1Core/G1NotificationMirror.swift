import Foundation

/// A notification the app is mirroring onto the lens.
public struct G1MirroredNotification: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let body: String
    public let receivedAt: Date

    public init(id: String, title: String, body: String, receivedAt: Date) {
        self.id = id
        self.title = title
        self.body = body
        self.receivedAt = receivedAt
    }

    /// Single-line form for the lens. The 1-bit display has five short lines and
    /// no styling, so the title is folded into the body rather than emphasized.
    public var lensText: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return [trimmedTitle, trimmedBody]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

public enum G1NotificationMirrorInput: Sendable, Equatable {
    case arrived(G1MirroredNotification)
    case headUp
    case headDown
    /// Carries the notification it was scheduled for so a late timer cannot
    /// dismiss whatever the wearer is reading now.
    case readTimeout(id: String)
    /// Navigation (or anything else with higher precedence) took the surface.
    case suspend
    case resume
    /// Feature disabled, glasses disconnected, or an explicit dismissal.
    case reset
}

/// What the lens should show. `nil` from `apply` means "no change".
public enum G1NotificationMirrorDisplay: Sendable, Equatable {
    case icon(pendingCount: Int)
    case text(G1MirroredNotification)
    case clear
}

public enum G1NotificationMirrorState: Sendable, Equatable {
    case idle
    case iconVisible
    case reading(G1MirroredNotification)
    case suspended
}

/// Drives the icon-then-tilt-to-read notification flow.
///
/// Pure and synchronous so the awkward parts are testable without BLE: the
/// firmware emits its own `headDown` 500-700 ms after every `headUp`
/// (`RESEARCH/GLASSES_FIRMWARE_BEHAVIOR.md`), and each head gesture arrives
/// twice because both arms report it.
public struct G1NotificationMirror: Sendable, Equatable {
    /// Long enough to swallow the firmware's automatic `headDown` and the second
    /// arm's copy of the gesture, short enough that a deliberate look-down still
    /// dismisses the message.
    public static let defaultHoldWindow: TimeInterval = 1.0
    public static let defaultMaximumPending = 5

    public private(set) var state: G1NotificationMirrorState = .idle
    /// The notification currently on the lens, already acknowledged.
    public private(set) var current: G1MirroredNotification?
    /// Unread notifications, oldest first. The newest is read first.
    public private(set) var pending: [G1MirroredNotification] = []

    private let holdWindow: TimeInterval
    private let maximumPending: Int
    private var holdUntil: Date?

    public init(holdWindow: TimeInterval = G1NotificationMirror.defaultHoldWindow,
                maximumPending: Int = G1NotificationMirror.defaultMaximumPending) {
        self.holdWindow = holdWindow
        self.maximumPending = max(1, maximumPending)
    }

    public var pendingCount: Int {
        pending.count
    }

    /// Whether the mirror is currently the owner of the custom display surface.
    /// Consulted by gesture routing so transit and the stock dashboard do not
    /// overwrite an icon or a message the wearer is reading.
    public var ownsDisplay: Bool {
        switch state {
        case .iconVisible, .reading:
            return true
        case .idle, .suspended:
            return false
        }
    }

    /// Whether anything would be shown once the mirror is allowed to draw again.
    public var hasContent: Bool {
        current != nil || !pending.isEmpty
    }

    public mutating func apply(_ input: G1NotificationMirrorInput,
                               now: Date) -> G1NotificationMirrorDisplay? {
        switch input {
        case .arrived(let notification):
            return enqueue(notification)
        case .headUp:
            return beginReading(now: now)
        case .headDown:
            return handleHeadDown(now: now)
        case .readTimeout(let id):
            guard case .reading(let reading) = state, reading.id == id else {
                return nil
            }
            return dismissCurrent()
        case .suspend:
            return suspend()
        case .resume:
            return resume()
        case .reset:
            return reset()
        }
    }

    private mutating func enqueue(_ notification: G1MirroredNotification) -> G1NotificationMirrorDisplay? {
        guard current?.id != notification.id,
              !pending.contains(where: { $0.id == notification.id }) else {
            return nil
        }

        pending.append(notification)
        if pending.count > maximumPending {
            // Newest is read first, so the oldest backlog entry is the one the
            // wearer is least likely to still care about.
            pending.removeFirst(pending.count - maximumPending)
        }

        switch state {
        case .suspended, .reading:
            // Something with the surface already; do not interrupt it.
            return nil
        case .idle, .iconVisible:
            state = .iconVisible
            return .icon(pendingCount: pending.count)
        }
    }

    private mutating func beginReading(now: Date) -> G1NotificationMirrorDisplay? {
        switch state {
        case .suspended, .reading:
            // `.reading` covers the second arm's copy of the same head-up and any
            // firmware repeat: keep showing what is already on the lens.
            return nil
        case .idle, .iconVisible:
            guard let newest = pending.popLast() else {
                return nil
            }
            // Reading is the acknowledgement, so the notification leaves the
            // queue here rather than when it is dismissed.
            current = newest
            state = .reading(newest)
            holdUntil = now.addingTimeInterval(holdWindow)
            return .text(newest)
        }
    }

    private mutating func handleHeadDown(now: Date) -> G1NotificationMirrorDisplay? {
        guard case .reading = state else {
            return nil
        }
        if let holdUntil, now < holdUntil {
            return nil
        }
        return dismissCurrent()
    }

    private mutating func dismissCurrent() -> G1NotificationMirrorDisplay? {
        current = nil
        holdUntil = nil

        if pending.isEmpty {
            state = .idle
            return .clear
        }
        state = .iconVisible
        return .icon(pendingCount: pending.count)
    }

    private mutating func suspend() -> G1NotificationMirrorDisplay? {
        guard state != .suspended else {
            return nil
        }
        state = .suspended
        holdUntil = nil
        // The new owner draws over the lens, so the mirror issues no command.
        return nil
    }

    private mutating func resume() -> G1NotificationMirrorDisplay? {
        guard state == .suspended else {
            return nil
        }

        if let current {
            state = .reading(current)
            // Deliberately not re-arming the hold window: the wearer's head has
            // been wherever it liked while navigation owned the surface, so the
            // next head-down is a real dismissal.
            return .text(current)
        }
        if !pending.isEmpty {
            state = .iconVisible
            return .icon(pendingCount: pending.count)
        }
        state = .idle
        return nil
    }

    private mutating func reset() -> G1NotificationMirrorDisplay? {
        let wasOwningDisplay = ownsDisplay
        state = .idle
        current = nil
        pending.removeAll()
        holdUntil = nil
        // Only clear a surface the mirror was actually drawing on; while
        // suspended the lens belongs to navigation.
        return wasOwningDisplay ? .clear : nil
    }
}
