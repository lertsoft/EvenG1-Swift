import Combine
import EvenG1Core
import Foundation
import UIKit

/// Owns dashboard state and drives head-up display.
///
/// Design notes tied to the plan's hardware findings:
/// - Head-up sends a *pre-rendered cached frame*; no network/location work runs
///   on the tilt path.
/// - The firmware emits a fast `headDown` ~500-700 ms after `headUp`; a dwell
///   window suppresses that so the dashboard is not cleared immediately.
/// - Duplicate `headUp` frames (one per arm, ~200 ms apart) are coalesced.
/// - Ownership is rechecked immediately before the BLE send so a queued
///   dashboard upload cannot overwrite navigation that started in between.
@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var previewImage: UIImage?
    @Published private(set) var lastSnapshot: DashboardSnapshot?

    let settingsStore: DashboardSettingsStore

    private let renderer = DashboardBitmapRenderer()
    private weak var bluetoothManager: G1BluetoothManager?

    private var cachedFrame: G1BitmapFrame?

    /// Increments on every send request so a late async completion can detect it
    /// is stale and abort.
    private var sendGeneration: UInt64 = 0

    private var lastHeadUpAt: Date?
    private var dwellUntil: Date?
    private let headUpDebounceSeconds: TimeInterval = 1.0
    private let dwellSeconds: TimeInterval = 8.0

    private var cancellables = Set<AnyCancellable>()

    init(settingsStore: DashboardSettingsStore = DashboardSettingsStore()) {
        self.settingsStore = settingsStore
        refreshSnapshot()

        // Re-render the cached frame whenever configuration changes so the
        // preview and the next head-up upload reflect the latest settings.
        settingsStore.$settings
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshSnapshot()
            }
            .store(in: &cancellables)
    }

    func bind(bluetoothManager: G1BluetoothManager) {
        self.bluetoothManager = bluetoothManager
    }

    var isEnabled: Bool {
        settingsStore.settings.isEnabled
    }

    // MARK: - Snapshot / rendering

    /// Rebuilds the snapshot from currently available data and re-renders the
    /// cached frame. Providers that need permissions/entitlements or external
    /// APIs are gated off by default and simply leave their field unavailable.
    func refreshSnapshot(referenceDate: Date = Date()) {
        let settings = settingsStore.settings
        let snapshot = DashboardSnapshot(
            capturedAt: Date(),
            referenceDate: referenceDate,
            reminderCount: nil,
            temperature: nil,
            nextEvent: nil,
            widget: widgetContent(for: settings)
        )
        lastSnapshot = snapshot
        render(snapshot: snapshot, settings: settings)
    }

    private func widgetContent(for settings: DashboardSettings) -> DashboardWidgetContent {
        switch settings.selectedWidget {
        case .quickNote:
            let note = settings.quickNote.trimmingCharacters(in: .whitespacesAndNewlines)
            return note.isEmpty ? .unavailable(reason: "Add a QuickNote in settings") : .quickNote(note)
        case .stocks:
            return .unavailable(reason: "Stocks not configured")
        case .news:
            return .unavailable(reason: "News not configured")
        case .map:
            return .unavailable(reason: "Map not configured")
        }
    }

    private func render(snapshot: DashboardSnapshot, settings: DashboardSettings) {
        guard let rendered = try? renderer.render(snapshot: snapshot, settings: settings) else {
            cachedFrame = nil
            previewImage = nil
            return
        }
        cachedFrame = rendered.frame
        previewImage = rendered.image
    }

    // MARK: - Glasses events

    /// Handle a routed glasses event. `ContentView`'s arbiter only routes here
    /// when the dashboard is the fallback owner; this method still rechecks
    /// enablement and ownership before any BLE work.
    func handleGlassesEvent(_ event: G1Event) async {
        guard settingsStore.settings.isEnabled else { return }
        guard ownershipAvailable() else { return }

        switch event {
        case .headUp:
            let now = Date()
            if let lastHeadUpAt, now.timeIntervalSince(lastHeadUpAt) < headUpDebounceSeconds {
                return // Coalesce the second arm's duplicate frame.
            }
            lastHeadUpAt = now
            dwellUntil = now.addingTimeInterval(dwellSeconds)
            await sendCachedFrame()

        case .headDown:
            // Ignore the firmware's fast head-down during the dwell window.
            if let dwellUntil, Date() < dwellUntil {
                return
            }
            bluetoothManager?.clearDisplay()

        default:
            return
        }
    }

    /// Manually push the current dashboard to the glasses (used by the config
    /// screen's send button and by the feasibility spike).
    func sendNow() async {
        guard ownershipAvailable() else { return }
        await sendCachedFrame()
    }

    private func ownershipAvailable() -> Bool {
        guard let bluetoothManager else { return false }
        // Navigation owns the surface during a trip.
        return bluetoothManager.navigationSessionState == .inactive
    }

    private func sendCachedFrame() async {
        guard let bluetoothManager, let frame = cachedFrame else { return }
        guard bluetoothManager.connectionState == .fullyConnected else { return }

        sendGeneration &+= 1
        let generation = sendGeneration

        // Recheck ownership right before sending: navigation may have started
        // between the head-up event and now.
        guard ownershipAvailable() else { return }
        guard generation == sendGeneration else { return }

        _ = await bluetoothManager.sendBitmap(frame)
    }
}
