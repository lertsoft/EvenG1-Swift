import Combine
import Foundation

/// Buffered BLE diagnostics isolated from ``G1BluetoothManager`` so high-frequency
/// log and frame traffic does not invalidate consumer tabs.
@MainActor
public final class G1DiagnosticsStore: ObservableObject {
    @Published public private(set) var logs: [G1BluetoothManager.LogEntry] = []
    @Published public private(set) var events: [G1Event] = []
    @Published public private(set) var recentFrames: [G1Frame] = []

    public init() {}

    public func appendLog(_ entry: G1BluetoothManager.LogEntry) {
        logs.append(entry)
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
    }

    public func appendEvent(_ event: G1Event) {
        events.insert(event, at: 0)
        if events.count > 50 {
            events.removeLast()
        }
    }

    public func appendFrame(_ frame: G1Frame) {
        recentFrames.insert(frame, at: 0)
        if recentFrames.count > 100 {
            recentFrames.removeLast()
        }
    }

    public func clearAll() {
        logs.removeAll()
        events.removeAll()
        recentFrames.removeAll()
    }
}

/// Lightweight glasses-event signal for gesture routing without republishing the
/// full diagnostics buffers to every tab.
@MainActor
public final class G1GlassesEventNotifier: ObservableObject {
    @Published public private(set) var revision: UInt64 = 0
    public private(set) var latestEvent: G1Event?

    public init() {}

    public func notify(_ event: G1Event) {
        latestEvent = event
        revision &+= 1
    }
}
