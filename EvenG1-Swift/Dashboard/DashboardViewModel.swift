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
    @Published private(set) var pageIndex: Int = 0
    @Published private(set) var isRefreshingData = false

    let settingsStore: DashboardSettingsStore
    let stationLockStore: MTAManualStationLockStore

    private let renderer = DashboardBitmapRenderer()
    private let dataCoordinator: DashboardDataCoordinator
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

    private var autoRotateTask: Task<Void, Never>?
    private var refreshDataTask: Task<Void, Never>?
    private var isDataRefreshQueued = false
    private var isDashboardDisplayed = false
    private var lastDataRefreshFingerprint: DataRefreshFingerprint?

    private struct DataRefreshFingerprint: Equatable {
        var calendarEnabled: Bool
        var remindersEnabled: Bool
        var weatherEnabled: Bool
        var transitEnabled: Bool
        var newsFeedURL: String
        var transitHorizonMinutes: Int
        var selectedWidgets: [DashboardWidgetKind]
    }

    private static func dataRefreshFingerprint(for settings: DashboardSettings) -> DataRefreshFingerprint {
        DataRefreshFingerprint(
            calendarEnabled: settings.calendarEnabled,
            remindersEnabled: settings.remindersEnabled,
            weatherEnabled: settings.weatherEnabled,
            transitEnabled: settings.transitEnabled,
            newsFeedURL: settings.newsFeedURL,
            transitHorizonMinutes: settings.transitHorizonMinutes,
            selectedWidgets: settings.selectedWidgets
        )
    }

    init(
        settingsStore: DashboardSettingsStore = DashboardSettingsStore(),
        stationLockStore: MTAManualStationLockStore = MTAManualStationLockStore(),
        dataCoordinator: DashboardDataCoordinator? = nil
    ) {
        self.settingsStore = settingsStore
        self.stationLockStore = stationLockStore
        self.dataCoordinator = dataCoordinator ?? DashboardDataCoordinator(
            transitProvider: DashboardTransitProvider(
                locationProvider: CurrentLocationProvider(),
                stationLockStore: stationLockStore
            )
        )
        refreshSnapshot()

        settingsStore.$settings
            .sink { [weak self] settings in
                guard let self else { return }
                self.clampPageIndex(for: settings)
                let fingerprint = Self.dataRefreshFingerprint(for: settings)
                if fingerprint != self.lastDataRefreshFingerprint {
                    self.lastDataRefreshFingerprint = fingerprint
                    Task { await self.refreshData() }
                } else {
                    self.refreshSnapshot()
                }
                self.synchronizeFirmwareHeadUpAction(suppressed: settings.isEnabled)
                self.updateAutoRotateTask(isDisplayed: self.isDashboardDisplayed)
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
                    self.isDashboardDisplayed = false
                    self.updateAutoRotateTask(isDisplayed: false)
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

    // MARK: - Data refresh

    func refreshData() async {
        if isRefreshingData {
            isDataRefreshQueued = true
            return
        }

        isRefreshingData = true
        defer { isRefreshingData = false }

        repeat {
            isDataRefreshQueued = false
            let settings = settingsStore.settings
            await dataCoordinator.refresh(settings: settings)
            refreshSnapshot()
        } while isDataRefreshQueued && !Task.isCancelled
    }

    private func refreshDataAndResendIfChanged() {
        refreshDataTask?.cancel()
        refreshDataTask = Task { [weak self] in
            guard let self else { return }
            let previous = self.lastSnapshot
            await self.refreshData()
            guard !Task.isCancelled else { return }
            guard self.isDashboardDisplayed else { return }
            if self.lastSnapshot != previous {
                _ = await self.sendCachedFrame(caller: "refreshData")
            }
        }
    }

    // MARK: - Snapshot / rendering

    /// Rebuilds the snapshot from currently available data and re-renders the
    /// cached frame. Providers that need permissions/entitlements or external
    /// APIs are gated off by default and simply leave their field unavailable.
    func refreshSnapshot(referenceDate: Date = Date()) {
        let settings = settingsStore.settings
        clampPageIndex(for: settings)
        let widgets = widgetContents(for: settings)
        let snapshot = DashboardSnapshot(
            capturedAt: Date(),
            referenceDate: referenceDate,
            reminderCount: settings.remindersEnabled ? dataCoordinator.cache.reminderCount : nil,
            temperature: settings.weatherEnabled ? dataCoordinator.cache.temperature : nil,
            nextEvent: settings.calendarEnabled ? dataCoordinator.cache.nextEvent : nil,
            widgets: widgets,
            displayMode: settings.widgetDisplayMode,
            pageIndex: pageIndex
        )
        lastSnapshot = snapshot
        render(snapshot: snapshot, settings: settings)
    }

    private func widgetContents(for settings: DashboardSettings) -> [DashboardWidgetContent] {
        let selected = settings.selectedWidgets
        guard !selected.isEmpty else {
            return [.unavailable(reason: "Select a widget in settings")]
        }

        return selected.map { kind in
            widgetContent(for: kind, settings: settings)
        }
    }

    private func widgetContent(for kind: DashboardWidgetKind, settings: DashboardSettings) -> DashboardWidgetContent {
        switch kind {
        case .quickNote:
            let note = settings.quickNote.trimmingCharacters(in: .whitespacesAndNewlines)
            return note.isEmpty ? .unavailable(reason: "Add a QuickNote in settings") : .quickNote(note)

        case .stocks:
            if settings.stockSymbols.isEmpty {
                return .unavailable(reason: "Add stock symbols in settings")
            }
            return .unavailable(reason: "Stocks not configured")

        case .news:
            if let headline = dataCoordinator.cache.newsHeadline {
                return .news(source: headline.source, headline: headline.title)
            }
            return .unavailable(reason: dataCoordinator.cache.newsError ?? "News unavailable")

        case .map:
            return .unavailable(reason: "Map not configured")

        case .transit:
            guard settings.transitEnabled else {
                return .unavailable(reason: "Enable Transit in settings")
            }
            if let transit = dataCoordinator.cache.transit {
                return .transit(station: transit.stationName, rows: transit.rows)
            }
            return .unavailable(reason: dataCoordinator.cache.transitError ?? "Transit unavailable")
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

    // MARK: - Paging

    private func clampPageIndex(for settings: DashboardSettings) {
        let count = max(1, settings.selectedWidgets.count)
        if pageIndex >= count {
            pageIndex = 0
        }
    }

    private func paginate(delta: Int, wrap: Bool = false) {
        let settings = settingsStore.settings
        let widgets = widgetContents(for: settings)
        guard widgets.count > 1 else { return }

        let next = pageIndex + delta
        if widgets.indices.contains(next) {
            pageIndex = next
        } else if wrap {
            pageIndex = delta > 0 ? 0 : widgets.count - 1
        } else {
            return
        }

        refreshSnapshot()
        if isDashboardDisplayed {
            Task { _ = await sendCachedFrame(caller: "paginate") }
        }
    }

    private func updateAutoRotateTask(isDisplayed: Bool) {
        autoRotateTask?.cancel()
        autoRotateTask = nil

        let settings = settingsStore.settings
        guard isDisplayed,
              settings.isEnabled,
              settings.widgetDisplayMode == .autoRotate,
              settings.selectedWidgets.count > 1 else {
            return
        }

        let interval = max(3, settings.autoRotateSeconds)
        autoRotateTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(Int64(clamping: interval)))
                } catch {
                    break
                }
                guard let self, !Task.isCancelled else { return }
                self.paginate(delta: 1, wrap: true)
            }
        }
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
            isDashboardDisplayed = true
            updateAutoRotateTask(isDisplayed: true)
            _ = await sendCachedFrame(caller: "headUp")
            refreshDataAndResendIfChanged()

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
            isDashboardDisplayed = false
            updateAutoRotateTask(isDisplayed: false)
            _ = await bluetoothManager?.clearDisplayAwaitingCompletion()

        case .swipeForward:
            guard settingsStore.settings.widgetDisplayMode == .paged else { return }
            paginate(delta: 1)

        case .swipeBackward:
            guard settingsStore.settings.widgetDisplayMode == .paged else { return }
            paginate(delta: -1)

        default:
            return
        }
    }

    /// Whether swipe paging should be handled by the dashboard instead of transit.
    func shouldHandleSwipePaging(
        navigationSessionState: G1NavigationSessionState,
        isNotificationMirrorEligible: Bool,
        isTransitWidgetActive: Bool
    ) -> Bool {
        guard settingsStore.settings.isEnabled,
              settingsStore.settings.widgetDisplayMode == .paged,
              settingsStore.settings.selectedWidgets.count > 1 else {
            return false
        }

        let owner = G1LensSurfaceArbiter.headGestureOwner(
            navigationSessionState: navigationSessionState,
            isNotificationMirrorEligible: isNotificationMirrorEligible,
            isTransitWidgetActive: isTransitWidgetActive
        )
        return owner == .dashboardFallback
    }

    /// Manually push the current dashboard to the glasses (used by the config
    /// screen's send button and by the feasibility spike).
    func sendNow() async {
        guard ownershipAvailable() else { return }
        await refreshData()
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
