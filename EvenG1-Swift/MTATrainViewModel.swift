import Combine
import CoreLocation
import EvenG1Core
import Foundation
import UIKit

@MainActor
final class MTATrainViewModel: ObservableObject {
    enum RefreshTrigger: String {
        case manualButton
        case autoTimer
        case doubleTapGesture
        case headTiltGesture
        case edgeBoundary
    }

    @Published private(set) var isRefreshing = false
    @Published private(set) var nearestStationName = "No train lookup yet"
    @Published private(set) var statusDetail = "Tap Refresh to fetch nearest MTA arrivals."
    @Published private(set) var upcomingTrains: [MTANextTrainResult] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var autoRefreshEnabled = false
    @Published private(set) var topAlertSummary: String?
    @Published private(set) var additionalAlertCount = 0
    @Published private(set) var alertsUnavailable = false

    @Published private(set) var selectedStation: MTAStationSelection?
    /// Page currently mirrored to the glasses, so the app can preview it.
    @Published private(set) var currentVisualPage: MTAVisualPage?
    /// Cached preview image from the last single-pass render; never rasterized in SwiftUI body.
    @Published private(set) var currentVisualImage: UIImage?
    @Published private(set) var visualPageIndexText = "Page 0/0"
    @Published private(set) var bitmapDeliveryStatus = "Bitmap idle"
    @Published private(set) var lockStatusText = "Auto-nearest"
    @Published private(set) var currentStationPreferenceMode: MTADirectionPreferenceMode = .both
    @Published private(set) var savedDirectionPreferences: [MTAStationDirectionPreference] = []
    @Published private(set) var lockedStation: MTAManualStationLock?

    private let locationProvider: LocationProviding
    private let transitService: MTANextTrainService
    private let directionPreferencesStore: MTAStationDirectionPreferencesStore
    private let stationLockStore: MTAManualStationLockStore
    private let bitmapRenderer = MTABitmapRenderer()
    private weak var bluetoothManager: G1BluetoothManager?

    private var autoRefreshTask: Task<Void, Never>?
    private(set) var isWidgetActive = false
    private var lastTiltRefreshAt: Date?
    private var lastEdgeRefreshAt: Date?
    private var currentPages: [MTAVisualPage] = []
    private var latestAlerts: [MTAServiceAlert] = []
    private var lastKnownUserCoordinate: CLLocationCoordinate2D?
    private var cancellables = Set<AnyCancellable>()
    private var bitmapRenderGeneration: UInt64 = 0

    private let tiltRefreshDebounceSeconds: TimeInterval = 2.0
    private let edgeRefreshCooldownSeconds: TimeInterval = 2.0
    private let refreshIntervalSeconds: UInt64 = 30
    private let maxAlertSnippetLength = 56
    private let maxGlassesPayloadLength = 120

    init(locationProvider: LocationProviding,
         transitService: MTANextTrainService,
         directionPreferencesStore: MTAStationDirectionPreferencesStore,
         stationLockStore: MTAManualStationLockStore) {
        self.locationProvider = locationProvider
        self.transitService = transitService
        self.directionPreferencesStore = directionPreferencesStore
        self.stationLockStore = stationLockStore

        savedDirectionPreferences = directionPreferencesStore.preferences
        lockedStation = stationLockStore.lockedStation
        syncLockStatusText()
        bindStores()
    }

    convenience init() {
        self.init(
            locationProvider: CurrentLocationProvider(),
            transitService: MTANextTrainService(),
            directionPreferencesStore: MTAStationDirectionPreferencesStore(),
            stationLockStore: MTAManualStationLockStore()
        )
    }

    func bind(bluetoothManager: G1BluetoothManager) {
        self.bluetoothManager = bluetoothManager
    }

    /// Whether the transit widget is on screen. Gates auto-refresh and glasses
    /// gestures so the widget never fights another feature for the display.
    func setWidgetActive(_ isActive: Bool) {
        guard isWidgetActive != isActive else { return }
        isWidgetActive = isActive
        bitmapRenderGeneration &+= 1
        updateAutoRefreshTask()
    }

    func setAutoRefreshEnabled(_ enabled: Bool) {
        autoRefreshEnabled = enabled
        updateAutoRefreshTask()
    }

    func lockToNearestStation() {
        guard let selectedStation else { return }
        stationLockStore.setLock(station: selectedStation)
    }

    func lockToStation(_ station: MTAStationSelection) {
        stationLockStore.setLock(station: station)
    }

    func clearManualLock() {
        stationLockStore.clearLock()
    }

    func setCurrentStationPreferenceMode(_ mode: MTADirectionPreferenceMode) async {
        guard let selectedStation else {
            return
        }
        directionPreferencesStore.setPreferenceMode(mode, for: selectedStation)
        currentStationPreferenceMode = directionPreferencesStore.preferenceMode(for: selectedStation)
        rebuildVisualPages(resetToFirst: true)
        await sendCurrentPageToGlassesIfConnected()
    }

    func setPreferenceMode(_ mode: MTADirectionPreferenceMode, for station: MTAStationSelection) {
        directionPreferencesStore.setPreferenceMode(mode, for: station)
        if selectedStation?.id == station.id {
            currentStationPreferenceMode = directionPreferencesStore.preferenceMode(for: station)
            rebuildVisualPages(resetToFirst: true)
        }
    }

    func removePreference(id: UUID) {
        directionPreferencesStore.removePreference(id: id)
    }

    func currentUserCoordinate() -> CLLocationCoordinate2D? {
        lastKnownUserCoordinate
    }

    func refreshNow(trigger: RefreshTrigger) async {
        if isRefreshing {
            return
        }

        isRefreshing = true
        errorMessage = nil
        defer {
            isRefreshing = false
        }

        do {
            let now = Date()
            let coordinate = try await locationProvider.requestOneShotLocation()
            lastKnownUserCoordinate = coordinate

            let query = currentTransitQuery()
            let snapshot = try await transitService.fetchTransitSnapshot(near: coordinate, now: now, query: query)
            upcomingTrains = snapshot.upcomingTrains
            latestAlerts = snapshot.alerts
            lastUpdatedAt = now
            applyAlerts(snapshot.alerts, unavailable: snapshot.alertsFetchFailed)

            if let selected = snapshot.selectedStation {
                selectedStation = MTAStationSelection(selectedStation: selected)
            } else if let first = snapshot.upcomingTrains.first {
                selectedStation = MTAStationSelection(
                    stationID: first.stationID,
                    stationName: first.stationName,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    distanceMeters: first.distanceMeters
                )
            } else {
                selectedStation = nil
            }

            if snapshot.usedFallbackFromPreferredStation, stationLockStore.lockedStation != nil {
                stationLockStore.clearLock()
                statusDetail = "Locked station had no arrivals. Returned to nearest station."
            } else {
                statusDetail = "Found \(snapshot.upcomingTrains.count) arrivals in next 30 minutes."
            }

            nearestStationName = selectedStation?.stationName ?? "No trains found"
            syncCurrentStationPreferenceMode()
            rebuildVisualPages(resetToFirst: true)
            await sendCurrentPageToGlassesIfConnected()
            DatadogTelemetryService.shared.trackTiming(name: "transit_refresh_complete")
        } catch {
            // Disabling auto-refresh or leaving the tab cancels the task. That
            // lifecycle event should not replace valid results with an error.
            if Task.isCancelled || error is CancellationError {
                return
            }

            let message = userFacingMessage(for: error)
            errorMessage = message

            if upcomingTrains.isEmpty {
                nearestStationName = "MTA lookup failed"
                statusDetail = message
                topAlertSummary = nil
                additionalAlertCount = 0
                alertsUnavailable = false
                selectedStation = nil
                currentPages = []
                latestAlerts = []
                visualPageIndexText = "Page 0/0"
                currentVisualImage = nil
                bitmapDeliveryStatus = "Bitmap idle"
            } else {
                // Preserve the last good snapshot during transient failures.
                statusDetail = "\(message) Showing the previous results."
            }

            if trigger == .manualButton {
                sendTextToGlassesIfConnected("MTA error: \(message)")
            }
        }
    }

    func handleGlassesEvent(_ event: G1Event) async {
        guard isWidgetActive else {
            return
        }
        // Navigation owns the glasses display during an active trip. In
        // particular, transit's head-down handler must not clear the route map.
        guard bluetoothManager?.navigationSessionState != .active,
              bluetoothManager?.navigationSessionState != .rerouting,
              bluetoothManager?.navigationSessionState != .arrived else {
            return
        }

        switch event {
        case .doubleTap:
            await refreshNow(trigger: .doubleTapGesture)
        case .headUp:
            let now = Date()
            if let lastTiltRefreshAt, now.timeIntervalSince(lastTiltRefreshAt) < tiltRefreshDebounceSeconds {
                return
            }
            lastTiltRefreshAt = now
            await refreshNow(trigger: .headTiltGesture)
        case .headDown:
            bluetoothManager?.clearDisplay()
        case .swipeForward:
            await paginate(delta: 1)
        case .swipeBackward:
            await paginate(delta: -1)
        default:
            return
        }
    }

    private func paginate(delta: Int) async {
        guard !currentPages.isEmpty else {
            return
        }

        let target = currentPageIndex + delta
        if currentPages.indices.contains(target) {
            currentPageIndex = target
            updatePageStatus()
            await sendCurrentPageToGlassesIfConnected()
            return
        }

        let now = Date()
        if let lastEdgeRefreshAt, now.timeIntervalSince(lastEdgeRefreshAt) < edgeRefreshCooldownSeconds {
            return
        }

        lastEdgeRefreshAt = now
        await refreshNow(trigger: .edgeBoundary)
    }

    private var currentPageIndex: Int = 0

    private func rebuildVisualPages(resetToFirst: Bool) {
        guard let selectedStation else {
            currentPages = []
            currentPageIndex = 0
            updatePageStatus()
            return
        }

        currentPages = MTAVisualBoardBuilder.buildPages(
            station: selectedStation,
            userCoordinate: lastKnownUserCoordinate,
            trains: upcomingTrains,
            alerts: latestAlerts,
            directionMode: currentStationPreferenceMode
        )

        if resetToFirst || currentPageIndex >= currentPages.count {
            currentPageIndex = 0
        }
        updatePageStatus()
    }

    private func updatePageStatus() {
        let total = currentPages.count
        if total == 0 {
            currentVisualPage = nil
            currentVisualImage = nil
            visualPageIndexText = "Page 0/0"
            return
        }
        currentVisualPage = currentPages.indices.contains(currentPageIndex) ? currentPages[currentPageIndex] : nil
        visualPageIndexText = "Page \(currentPageIndex + 1)/\(total)"
    }

    private func renderCurrentPage() async -> MTABitmapRenderer.RenderedPage? {
        guard currentPages.indices.contains(currentPageIndex) else {
            return nil
        }

        let page = currentPages[currentPageIndex]
        let renderer = bitmapRenderer
        let renderStartedAt = ContinuousClock.now

        let rendered = try? await Task.detached(priority: .userInitiated) {
            try renderer.render(page: page)
        }.value

        let renderDurationMs = Int64(renderStartedAt.duration(to: ContinuousClock.now) / .milliseconds(1))
        DatadogTelemetryService.shared.trackTiming(name: "bitmap_render_complete")
        DatadogTelemetryService.shared.trackAction(
            type: .custom,
            name: "bitmap_render_duration",
            attributes: ["duration_ms": renderDurationMs]
        )

        return rendered
    }

    private func sendCurrentPageToGlassesIfConnected() async {
        guard isWidgetActive else { return }
        bitmapRenderGeneration &+= 1
        let generation = bitmapRenderGeneration
        let pageIndex = currentPageIndex

        guard bluetoothManager?.connectionState == .fullyConnected else {
            bitmapDeliveryStatus = "Results shown in app (glasses disconnected)"
            if let rendered = await renderCurrentPage(),
               isWidgetActive,
               generation == bitmapRenderGeneration,
               pageIndex == currentPageIndex {
                currentVisualImage = rendered.image
            }
            return
        }

        guard currentPages.indices.contains(currentPageIndex) else {
            bitmapDeliveryStatus = "No page to render"
            currentVisualImage = nil
            return
        }

        guard let rendered = await renderCurrentPage() else {
            guard isWidgetActive, generation == bitmapRenderGeneration else { return }
            bitmapDeliveryStatus = "Bitmap failed, used text fallback"
            currentVisualImage = nil
            sendTextFallbackForCurrentPage()
            return
        }

        guard isWidgetActive,
              generation == bitmapRenderGeneration,
              pageIndex == currentPageIndex else {
            return
        }
        currentVisualImage = rendered.image

        let sent = await bluetoothManager?.sendBitmap(rendered.frame) ?? false
        guard isWidgetActive,
              generation == bitmapRenderGeneration,
              pageIndex == currentPageIndex else {
            return
        }
        if sent {
            bitmapDeliveryStatus = "Bitmap \(currentPageIndex + 1)/\(currentPages.count)"
            return
        }

        bitmapDeliveryStatus = "Bitmap failed, used text fallback"
        sendTextFallbackForCurrentPage()
    }

    private func sendTextFallbackForCurrentPage() {
        guard currentPages.indices.contains(currentPageIndex) else {
            sendTextToGlassesIfConnected("MTA: No visual page available.")
            return
        }

        let page = currentPages[currentPageIndex]
        var parts: [String] = [
            page.title,
            "\(currentPageIndex + 1)/\(max(1, currentPages.count))"
        ]
        let rowSummary = page.rows.prefix(3).map { "\($0.routeID) \($0.minutesAway)m" }.joined(separator: ", ")
        if !rowSummary.isEmpty {
            parts.append(rowSummary)
        }
        if let topAlertSummary {
            parts.append("Alert: \(truncated(topAlertSummary, maxLength: maxAlertSnippetLength))")
        }

        sendTextToGlassesIfConnected(truncated(parts.joined(separator: " | "), maxLength: maxGlassesPayloadLength))
    }

    private func bindStores() {
        directionPreferencesStore.$preferences
            .sink { [weak self] values in
                guard let self else { return }
                self.savedDirectionPreferences = values.sorted(by: { $0.updatedAt > $1.updatedAt })
                self.syncCurrentStationPreferenceMode()
            }
            .store(in: &cancellables)

        stationLockStore.$lockedStation
            .sink { [weak self] lock in
                guard let self else { return }
                self.lockedStation = lock
                self.syncLockStatusText()
            }
            .store(in: &cancellables)
    }

    private func syncLockStatusText() {
        if let lockedStation {
            lockStatusText = "Locked: \(lockedStation.stationName)"
        } else {
            lockStatusText = "Auto-nearest"
        }
    }

    private func syncCurrentStationPreferenceMode() {
        guard let selectedStation else {
            currentStationPreferenceMode = .both
            return
        }
        currentStationPreferenceMode = directionPreferencesStore.preferenceMode(for: selectedStation)
    }

    private func currentTransitQuery() -> MTATransitQuery {
        if let lockedStation = stationLockStore.lockedStation {
            return MTATransitQuery(
                horizonMinutes: 30,
                preferredStationID: lockedStation.stationID,
                preferredStationName: lockedStation.stationName,
                allowFallbackFromPreferredStation: true
            )
        }

        return MTATransitQuery(horizonMinutes: 30)
    }

    private func updateAutoRefreshTask() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil

        guard autoRefreshEnabled, isWidgetActive else {
            return
        }

        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refreshNow(trigger: .autoTimer)
                guard let refreshIntervalSeconds = self?.refreshIntervalSeconds else { return }
                do {
                    try await Task.sleep(for: .seconds(Int64(clamping: refreshIntervalSeconds)))
                } catch {
                    break
                }
            }
        }
    }

    private func applyAlerts(_ alerts: [MTAServiceAlert], unavailable: Bool) {
        alertsUnavailable = unavailable

        guard let first = alerts.first else {
            topAlertSummary = nil
            additionalAlertCount = 0
            return
        }

        topAlertSummary = summarizeAlert(first)
        additionalAlertCount = max(0, alerts.count - 1)
    }

    private func summarizeAlert(_ alert: MTAServiceAlert) -> String {
        let header = alert.header.trimmingCharacters(in: .whitespacesAndNewlines)
        if !header.isEmpty {
            return "\(alert.effect) - \(header)"
        }

        if let description = alert.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            return "\(alert.effect) - \(description)"
        }

        return alert.effect
    }

    private func truncated(_ value: String, maxLength: Int) -> String {
        guard maxLength > 0 else {
            return ""
        }

        if value.count <= maxLength {
            return value
        }

        if maxLength <= 3 {
            return String(value.prefix(maxLength))
        }

        return String(value.prefix(maxLength - 3)) + "..."
    }

    private func sendTextToGlassesIfConnected(_ text: String) {
        guard bluetoothManager?.connectionState == .fullyConnected else {
            return
        }

        bluetoothManager?.sendText(text)
    }

    private func userFacingMessage(for error: Error) -> String {
        if let locationError = error as? CurrentLocationError {
            switch locationError {
            case .servicesDisabled:
                return "Location services are disabled. Enable them in Settings."
            case .deniedOrRestricted:
                return "Location permission is denied. Enable While Using App access in Settings."
            case .timeout:
                return "Location request timed out. Try again in a few seconds."
            case .noLocation:
                return "Unable to determine your location right now."
            case .underlying(let details):
                return "Location error: \(details)"
            }
        }

        if let transitError = error as? MTANextTrainError {
            switch transitError {
            case .stationDataUnavailable:
                return "Could not load station metadata from MTA open data."
            case .noUpcomingArrival:
                return "No upcoming arrivals in the next 30 minutes."
            case .networkFailure(let details):
                return "Realtime feed request failed: \(details)"
            }
        }

        return error.localizedDescription
    }
}
