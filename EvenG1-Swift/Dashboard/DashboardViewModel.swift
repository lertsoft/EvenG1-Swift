import Combine
import EvenG1Core
import Foundation
import UIKit

/// Owns dashboard state and drives head-up display.
///
/// Design notes tied to the plan's hardware findings:
/// - Duplicate `headUp`/`headDown` frames (one per arm, ~200 ms apart) are coalesced.
/// - Ownership is rechecked immediately before the BLE send so a queued
///   dashboard upload cannot overwrite navigation that started in between.
/// - Head-up mode commands (`0x0A`/`0x0B`) are never sent; they trigger Even AI.
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
    private var lastHeadDownAt: Date?
    private let headUpDebounceSeconds: TimeInterval = 1.0
    private let headDownDebounceSeconds: TimeInterval = 1.0
    private let headDownDwellAfterHeadUpSeconds: TimeInterval = 3.5

    private var cancellables = Set<AnyCancellable>()
    private var connectionCancellable: AnyCancellable?
    private var requestedFirmwareHeadUpSuppression: Bool?
    private var firmwareHeadUpConfigurationGeneration: UInt64 = 0

    init(settingsStore: DashboardSettingsStore = DashboardSettingsStore()) {
        self.settingsStore = settingsStore
        refreshSnapshot()

        settingsStore.$settings
            .sink { [weak self] settings in
                guard let self else { return }
                self.refreshSnapshot()
                self.synchronizeFirmwareHeadUpAction(suppressed: settings.isEnabled)
            }
            .store(in: &cancellables)
    }

    func bind(bluetoothManager: G1BluetoothManager) {
        self.bluetoothManager = bluetoothManager
        connectionCancellable = bluetoothManager.$connectionState
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                if state == .fullyConnected {
                    self.synchronizeFirmwareHeadUpAction(
                        suppressed: self.settingsStore.settings.isEnabled
                    )
                } else {
                    self.requestedFirmwareHeadUpSuppression = nil
                }
            }
        synchronizeFirmwareHeadUpAction(suppressed: settingsStore.settings.isEnabled)
    }

    var isEnabled: Bool {
        settingsStore.settings.isEnabled
    }

    private func synchronizeFirmwareHeadUpAction(suppressed: Bool) {
        guard let bluetoothManager,
              bluetoothManager.connectionState == .fullyConnected else {
            requestedFirmwareHeadUpSuppression = nil
            return
        }
        guard requestedFirmwareHeadUpSuppression != suppressed else { return }

        requestedFirmwareHeadUpSuppression = suppressed
        firmwareHeadUpConfigurationGeneration &+= 1
        let generation = firmwareHeadUpConfigurationGeneration

        Task { [weak self, weak bluetoothManager] in
            guard let self, let bluetoothManager else { return }
            let acknowledged = await bluetoothManager
                .setFirmwareHeadUpActionSuppressed(suppressed)
            guard generation == self.firmwareHeadUpConfigurationGeneration else {
                self.requestedFirmwareHeadUpSuppression = nil
                self.synchronizeFirmwareHeadUpAction(
                    suppressed: self.settingsStore.settings.isEnabled
                )
                return
            }
            if !acknowledged {
                self.requestedFirmwareHeadUpSuppression = nil
            }
        }
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
                return
            }
            lastHeadUpAt = now

            let stockLayerCleared = await bluetoothManager?.clearDisplayAwaitingCompletion() ?? false
            guard stockLayerCleared else { return }

            refreshSnapshot(referenceDate: now)
            _ = await sendCachedFrame(caller: "headUp")

        case .headDown:
            let now = Date()
            let deltaSinceHeadUp = lastHeadUpAt.map { now.timeIntervalSince($0) }
            let isFirmwareFollowUp = (deltaSinceHeadUp ?? .greatestFiniteMagnitude) < headDownDwellAfterHeadUpSeconds
            if isFirmwareFollowUp {
                return
            }

            if let lastHeadDownAt, now.timeIntervalSince(lastHeadDownAt) < headDownDebounceSeconds {
                return
            }
            lastHeadDownAt = now
            _ = await bluetoothManager?.clearDisplayAwaitingCompletion()

        default:
            return
        }
    }

    /// Manually push the current dashboard to the glasses (used by the config
    /// screen's send button and by the feasibility spike).
    func sendNow() async {
        guard ownershipAvailable() else { return }
        _ = await sendCachedFrame(caller: "sendNow")
    }

    private func ownershipAvailable() -> Bool {
        guard let bluetoothManager else { return false }
        return bluetoothManager.navigationSessionState == .inactive
    }

    private func sendCachedFrame(caller: String) async -> Bool {
        guard let bluetoothManager, let frame = cachedFrame else { return false }
        guard bluetoothManager.connectionState == .fullyConnected else { return false }

        sendGeneration &+= 1
        let generation = sendGeneration

        guard ownershipAvailable() else { return false }
        guard generation == sendGeneration else { return false }

        let sent = await bluetoothManager.sendBitmap(
            frame,
            latchOwner: .dashboard,
            showDashboardBeforeUpload: caller != "headUp"
        )
        return sent
    }
}
