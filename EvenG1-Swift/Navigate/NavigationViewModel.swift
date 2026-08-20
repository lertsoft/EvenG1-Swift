import Combine
import CoreLocation
import Foundation
import MapKit
import SwiftUI
import UIKit
import EvenG1Core

// #region agent log
private let agentLogURL: URL? = FileManager.default
    .urls(for: .documentDirectory, in: .userDomainMask).first?
    .appendingPathComponent("debug-bf2a66.log")

private func agentLog(_ hypothesisId: String, _ message: String, _ data: [String: Any]) {
    guard let url = agentLogURL else { return }
    let payload: [String: Any] = [
        "sessionId": "bf2a66", "runId": "run1", "hypothesisId": hypothesisId,
        "location": "NavigationViewModel.swift", "message": message, "data": data,
        "timestamp": Int(Date().timeIntervalSince1970 * 1000)
    ]
    guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return }
    print("AGENTLOG-bf2a66 \(String(decoding: json, as: UTF8.self))")
    var line = json
    line.append(0x0A)
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    } else {
        try? line.write(to: url)
    }
}
// #endregion

@MainActor
final class NavigationViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case searching
        case routePreview
        case navigating
        case rerouting
        case arrived
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published var searchQuery: String = ""
    @Published private(set) var suggestions: [MapSearchSuggestion] = []
    @Published var selectedMode: G1NavigationMode = .walking

    @Published private(set) var routePolyline: MKPolyline?
    @Published private(set) var destinationCoordinate: CLLocationCoordinate2D?
    @Published private(set) var destinationTitle: String = ""

    @Published var cameraPosition: MapCameraPosition = .automatic
    @Published private(set) var activeInstructionTitle: String = "Search for a destination"
    @Published private(set) var activeInstructionSubtitle: String = "Route guidance will appear here."
    @Published private(set) var progressFraction: Double = 0

    @Published private(set) var isOverlayVisible: Bool = true
    @Published private(set) var isGuidanceMuted: Bool = false
    @Published private(set) var transportModeLabel: String = G1NavigationTransportMode.nativePackets.displayName

    /// Last guidance line handed to the glasses, for the in-app HUD preview.
    @Published private(set) var hudInstructionText: String = ""
    @Published private(set) var currentNavVisualImage: UIImage?
    @Published private(set) var glassesDisplayDetailLabel: String = "Minimal path"

    @Published private(set) var favorites: [NavigationFavorite] = []
    @Published private(set) var userLocation: CLLocationCoordinate2D?
    @Published private(set) var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isFollowingUser: Bool = true
    @Published private(set) var favoriteActionMessage: String?

    private let searchService: MapSearchService
    private let routePlanner: RoutePlanner
    private let routeTracker: RouteTracker
    private let oneShotLocationProvider: LocationProviding
    private let favoritesStore: NavigationFavoritesStore

    private weak var bluetoothManager: G1BluetoothManager?

    private var currentPlan: NavigationRoutePlan?
    private var currentDestination: MKMapItem?
    private var latestTrackingUpdate: RouteTrackingUpdate?
    private var activeStepIndex: Int = 0
    private var previewStepIndex: Int?

    private var periodicPushTask: Task<Void, Never>?
    private var rerouteTask: Task<Void, Never>?
    private var navigationSetupTask: Task<Void, Never>?
    private var isNavigateTabActive = false
    private var cancellables = Set<AnyCancellable>()

    private var gestureLastFiredAt: [G1NavigationGestureAction: Date] = [:]
    private let gestureDebounceSeconds: TimeInterval = 0.35
    private let rerouteCooldownSeconds: TimeInterval = 8
    private let minimumLocationUpdateInterval: TimeInterval = 1.0
    private var lastRerouteAt: Date?
    private var isProcessingLocationUpdate = false
    private var pendingLocationUpdate: CLLocation?
    private var lastProcessedLocationAt: Date?
    private var lastPublishedProgressFraction: Double?
    private var lastPublishedDistanceSubtitle: String?

    private let bitmapRenderer = NavigationBitmapRenderer()
    private var glassesDisplayDetail: NavigationDisplayDetail = .minimal
    private var navigationStartedAt: Date?
    /// The firmware reports a head-down about a second after every head-up,
    /// which is faster than a bitmap upload completes. The overview therefore
    /// owns the display for this long before a head-down can dismiss it.
    private let overviewHoldSeconds: TimeInterval = 8
    private var overviewHoldUntil: Date?
    private var overviewAutoReturnTask: Task<Void, Never>?
    private var lastUploadedBitmapSignature: String?
    private var lastMinimalBitmapAt: Date?
    private var lastDetailedBitmapAt: Date?
    private let minimalBitmapInterval: TimeInterval = 8
    private let detailedBitmapInterval: TimeInterval = 2.5
    private var navigationBitmapGeneration: UInt64 = 0
    private var navigationMapUploadTask: Task<Void, Never>?
    private var isNavigationMapUploadInFlight = false
    private var mapTileUpgradeTask: Task<Void, Never>?
    private var mapTileUpgradeAttempts = 0
    private let maximumMapTileUpgradeAttempts = 3

    private struct PendingNavigationMapUpload {
        let detail: NavigationDisplayDetail
        let userLocation: CLLocation
        let stepChanged: Bool
        let forceUpload: Bool
    }

    private var pendingNavigationMapUpload: PendingNavigationMapUpload?

    private static let idleRegionLatLonDelta = 0.012
    private static let navigationFollowLatLonDelta = 0.008

    private var hasInitializedIdleCamera = false
    private var isProgrammaticCameraMove = false
    private var cameraMoveResetTask: Task<Void, Never>?
    private var isAppActive = true

    init(searchService: MapSearchService,
         routePlanner: RoutePlanner,
         routeTracker: RouteTracker,
         oneShotLocationProvider: LocationProviding,
         favoritesStore: NavigationFavoritesStore) {
        self.searchService = searchService
        self.routePlanner = routePlanner
        self.routeTracker = routeTracker
        self.oneShotLocationProvider = oneShotLocationProvider
        self.favoritesStore = favoritesStore

        bindSearch()
        bindFavorites()
    }

    convenience init() {
        self.init(
            searchService: MapSearchService(),
            routePlanner: RoutePlanner(),
            routeTracker: RouteTracker(),
            oneShotLocationProvider: CurrentLocationProvider(),
            favoritesStore: NavigationFavoritesStore()
        )
    }

    func bind(bluetoothManager: G1BluetoothManager) {
        self.bluetoothManager = bluetoothManager
        transportModeLabel = bluetoothManager.navigationTransportMode.displayName
        isOverlayVisible = bluetoothManager.isNavigationOverlayVisible
        isGuidanceMuted = bluetoothManager.isNavigationMuted
    }

    var showsNavigationControls: Bool {
        switch state {
        case .navigating, .rerouting, .arrived:
            return true
        case .routePreview:
            return routePolyline != nil
        default:
            return false
        }
    }

    var needsLocationPermission: Bool {
        switch locationAuthorizationStatus {
        case .denied, .restricted:
            return true
        default:
            return false
        }
    }

    func setNavigateTabActive(_ isActive: Bool) {
        isNavigateTabActive = isActive

        if !isActive {
            hasInitializedIdleCamera = false
            return
        }

        refreshLocationAuthorizationStatus()

        if state == .idle {
            Task { await bootstrapMapCamera() }
        }
    }

    func setAppActive(_ isActive: Bool) {
        guard isAppActive != isActive else { return }
        isAppActive = isActive
        if !isActive {
            navigationBitmapGeneration &+= 1
            cameraMoveResetTask?.cancel()
            cameraMoveResetTask = nil
            isProgrammaticCameraMove = false
        }
    }

    func bootstrapMapCamera() async {
        guard state == .idle else { return }

        refreshLocationAuthorizationStatus()
        if needsLocationPermission {
            return
        }

        if hasInitializedIdleCamera, let userLocation {
            applyCamera(to: userLocation, latLonDelta: Self.idleRegionLatLonDelta)
            return
        }

        do {
            let coordinate = try await oneShotLocationProvider.requestOneShotLocation()
            userLocation = coordinate
            hasInitializedIdleCamera = true
            isFollowingUser = true
            updateSearchRegion(center: coordinate)
            applyCamera(to: coordinate, latLonDelta: Self.idleRegionLatLonDelta)
        } catch {
            refreshLocationAuthorizationStatus()
        }
    }

    func centerOnUser() async {
        isFollowingUser = true

        if let userLocation {
            applyCamera(to: userLocation, latLonDelta: Self.idleRegionLatLonDelta)
            return
        }

        hasInitializedIdleCamera = false
        await bootstrapMapCamera()
    }

    func stopFollowingUser() {
        isFollowingUser = false
    }

    func userDidMoveMap() {
        guard !isProgrammaticCameraMove else { return }
        stopFollowingUser()
    }

    static func region(around coordinate: CLLocationCoordinate2D, latLonDelta: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: latLonDelta, longitudeDelta: latLonDelta)
        )
    }

    func updateSearchQuery(_ query: String) {
        searchQuery = query
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            suggestions = []
            if state == .searching {
                state = .idle
            }
            return
        }

        state = .searching
        updateSearchRegionIfNeeded()
        searchService.updateQuery(query)
    }

    func submitSearchQuery() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        updateSearchRegionIfNeeded()

        do {
            state = .searching
            let mapItem = try await searchService.resolveNaturalLanguageQuery(query)
            await previewRoute(to: mapItem)
        } catch {
            if let firstSuggestion = suggestions.first {
                await selectSuggestion(firstSuggestion)
            } else {
                state = .error("Could not find that location nearby")
            }
        }
    }

    func selectSuggestion(_ suggestion: MapSearchSuggestion) async {
        // #region agent log
        agentLog("H11,H12", "selectSuggestion tapped", [
            "title": suggestion.title,
            "state": String(describing: state),
            "suggestionCount": suggestions.count
        ])
        // #endregion
        do {
            state = .searching
            let mapItem = try await searchService.resolve(suggestion)
            await previewRoute(to: mapItem)
        } catch {
            // #region agent log
            agentLog("H7", "selectSuggestion resolve failed", ["error": String(describing: error)])
            // #endregion
            state = .error("Could not resolve location")
        }
    }

    func previewFavorite(_ favorite: NavigationFavorite) async {
        if let item = favorite.toMapItem() {
            await previewRoute(to: item)
        }
    }

    func previewRoute(to destination: MKMapItem) async {
        do {
            stopFollowingUser()
            state = .searching
            let source = try await oneShotLocationProvider.requestOneShotLocation()
            userLocation = source
            updateSearchRegion(center: source)
            let plan = try await routePlanner.planRoute(from: source, to: destination, mode: selectedMode)
            // #region agent log
            agentLog("H9,H10", "previewRoute planned", [
                "hasRoute": plan.route != nil,
                "stepCount": plan.route?.steps.count ?? -1,
                "destination": plan.destinationName
            ])
            // #endregion

            currentPlan = plan
            currentDestination = destination
            destinationCoordinate = destination.placemark.location?.coordinate
            destinationTitle = plan.destinationName
            routePolyline = plan.route?.polyline
            suggestions = []
            state = .routePreview
            activeInstructionTitle = plan.destinationName
            activeInstructionSubtitle = subtitleForPreview(plan)
            progressFraction = 0
            hudInstructionText = plan.route
                .flatMap { buildInstruction(for: $0, stepIndex: 0, tracking: nil) }
                .map { $0.fallbackText() } ?? ""

            if let route = plan.route {
                let rect = route.polyline.boundingMapRect
                if !rect.isNull {
                    setCameraPosition(.rect(rect))
                }
            } else if let coordinate = destinationCoordinate {
                let region = MKCoordinateRegion(
                    center: coordinate,
                    latitudinalMeters: 1800,
                    longitudinalMeters: 1800
                )
                setCameraPosition(.region(region))
            }

            DatadogTelemetryService.shared.trackTiming(name: "route_preview_ready")
        } catch {
            // #region agent log
            agentLog("H9,H10", "previewRoute failed", [
                "error": String(describing: error),
                "message": userFacingError(error)
            ])
            // #endregion
            state = .error(userFacingError(error))
            activeInstructionTitle = "Route unavailable"
            activeInstructionSubtitle = userFacingError(error)
        }
    }

    func startNavigation() async {
        guard let plan = currentPlan else {
            state = .error("Pick a destination first")
            return
        }

        periodicPushTask?.cancel()
        rerouteTask?.cancel()
        navigationSetupTask?.cancel()
        routeTracker.stop()
        navigationBitmapGeneration &+= 1

        state = .navigating
        activeStepIndex = 0
        previewStepIndex = nil
        latestTrackingUpdate = nil
        navigationStartedAt = Date()

        // The current G1 firmware NACKs the experimental native navigation
        // command family. Waiting for those retries delayed startup and then
        // emitted text that replaced the bitmap. Bitmap navigation owns the
        // display directly, so mark the local session active without sending
        // unsupported native/text packets.
        bluetoothManager?.setNavigationSessionState(.active)
        transportModeLabel = "Bitmap map"
        lastPublishedProgressFraction = nil
        lastPublishedDistanceSubtitle = nil
        lastProcessedLocationAt = nil
        pendingLocationUpdate = nil

        if let route = plan.route {
            if let initialInstruction = buildInstruction(for: route, stepIndex: 0, tracking: nil) {
                await publishInstruction(initialInstruction, forceEvenIfMuted: true)
            }

            let initialCoordinate: CLLocationCoordinate2D?
            if let userLocation {
                initialCoordinate = userLocation
            } else {
                initialCoordinate = try? await oneShotLocationProvider.requestOneShotLocation()
            }

            // #region agent log
            agentLog("H6", "startNavigation resolved initial coordinate", [
                "hasCoordinate": initialCoordinate != nil,
                "stepCount": route.steps.count,
                "routeDistance": Int(route.distance),
                "state": String(describing: state),
                "connectionState": String(describing: bluetoothManager?.connectionState)
            ])
            // #endregion

            if let coordinate = initialCoordinate {
                let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                userLocation = coordinate

                let generation = navigationBitmapGeneration
                navigationSetupTask = Task { [weak self] in
                    guard let self else { return }
                    // #region agent log
                    agentLog("H6", "navigationSetupTask entered", [
                        "cancelled": Task.isCancelled,
                        "generationMatch": generation == self.navigationBitmapGeneration,
                        "state": String(describing: self.state)
                    ])
                    // #endregion
                    guard !Task.isCancelled,
                          generation == self.navigationBitmapGeneration else {
                        return
                    }

                    // Head gestures are already delivered as app events by the
                    // connected firmware. Do not send the unsupported head-up
                    // mode commands or hide the dashboard surface here: 0x07
                    // can suppress the custom bitmap even after a valid upload.
                    await self.publishNavigationMap(
                        detail: .minimal,
                        userLocation: location,
                        stepChanged: true,
                        forceUpload: true
                    )
                }
            }

            routeTracker.start { [weak self] location in
                Task { @MainActor in
                    await self?.enqueueLocationUpdate(location)
                }
            }
        }

        startPeriodicStatusPush()
    }

    func stopNavigation() async {
        navigationBitmapGeneration &+= 1
        state = .idle
        navigationSetupTask?.cancel()
        navigationSetupTask = nil
        navigationMapUploadTask?.cancel()
        navigationMapUploadTask = nil
        isNavigationMapUploadInFlight = false
        pendingNavigationMapUpload = nil
        mapTileUpgradeTask?.cancel()
        mapTileUpgradeTask = nil
        mapTileUpgradeAttempts = 0
        periodicPushTask?.cancel()
        periodicPushTask = nil
        rerouteTask?.cancel()
        rerouteTask = nil
        routeTracker.stop()
        previewStepIndex = nil
        pendingLocationUpdate = nil

        bluetoothManager?.setNavigationSessionState(.inactive)
        transportModeLabel = bluetoothManager?.navigationTransportMode.displayName ?? transportModeLabel
        _ = await bluetoothManager?.clearDisplayAwaitingCompletion()

        activeInstructionTitle = "Search for a destination"
        activeInstructionSubtitle = "Route guidance will appear here."
        progressFraction = 0
        hudInstructionText = ""
        currentNavVisualImage = nil
        glassesDisplayDetail = .minimal
        glassesDisplayDetailLabel = "Minimal path"
        lastUploadedBitmapSignature = nil
        lastMinimalBitmapAt = nil
        lastDetailedBitmapAt = nil
        routePolyline = nil
        destinationCoordinate = nil
        destinationTitle = ""
        currentPlan = nil
        currentDestination = nil
        hasInitializedIdleCamera = false
        isFollowingUser = true
        await bootstrapMapCamera()
    }

    func saveFavorite(kind: NavigationFavoriteKind) async {
        // #region agent log
        agentLog("H11,H7", "saveFavorite tapped", [
            "kind": String(describing: kind),
            "hasCurrentDestination": currentDestination != nil,
            "suggestionCount": suggestions.count,
            "query": searchQuery,
            "state": String(describing: state)
        ])
        // #endregion
        guard kind == .home || kind == .office else { return }

        do {
            let mapItem = try await resolveMapItemForSaving()
            favoritesStore.setFavorite(kind: kind, mapItem: mapItem)
            favoriteActionMessage = "\(kind == .home ? "Home" : "Office") saved"
            // #region agent log
            agentLog("H11", "saveFavorite stored", ["name": mapItem.name ?? "<unnamed>"])
            // #endregion
        } catch {
            // #region agent log
            agentLog("H7", "saveFavorite failed", ["error": String(describing: error)])
            // #endregion
            favoriteActionMessage = "Search for a place first, then save it"
        }
    }

    func addCustomFavorite() async {
        do {
            let mapItem = try await resolveMapItemForSaving()
            favoritesStore.addCustom(mapItem: mapItem)
            favoriteActionMessage = "Location saved to favorites"
        } catch {
            favoriteActionMessage = "Search for a place first, then save it"
        }
    }

    func clearFavoriteActionMessage() {
        favoriteActionMessage = nil
    }

    func removeFavorite(id: UUID) {
        favoritesStore.removeCustom(id: id)
    }

    func handleGlassesEvent(_ event: G1Event) async {
        let isNavigationActive: Bool
        switch state {
        case .navigating, .rerouting, .arrived:
            isNavigationActive = true
        case .idle, .searching, .routePreview, .error:
            isNavigationActive = false
        }

        let mappedAction = G1NavigationGestureMapper.action(for: event, isNavigationActive: isNavigationActive)
        // #region agent log
        var rawPayload = "<mapped>"
        if case .unknown(let command, let firstByte, let payload) = event {
            rawPayload = String(format: "cmd=%02X code=%02X ", command, firstByte ?? 0)
                + payload.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
        agentLog("H17,H18,H23", "glasses event", [
            "event": String(describing: event),
            "raw": rawPayload,
            "isNavigationActive": isNavigationActive,
            "action": mappedAction.map { String(describing: $0) } ?? "<none>",
            "debounced": mappedAction.map { isGestureWithinDebounce($0) } ?? false,
            "currentDetail": glassesDisplayDetail.rawValue,
            "dashboardVisible": bluetoothManager?.isDashboardVisible ?? false
        ])
        // #endregion

        guard let action = mappedAction, shouldHandleGesture(action) else {
            return
        }

        switch action {
        case .repeatCurrentInstruction:
            guard isNavigateTabActive else { return }
            if let instruction = latestInstructionForDisplay() {
                await publishInstruction(instruction, forceEvenIfMuted: true)
            }
            await refreshNavigationBitmap(forceUpload: true)

        case .announceStatus:
            guard isNavigateTabActive else { return }
            await announceConciseStatus()

        case .previewNextStep:
            guard isNavigateTabActive else { return }
            await previewRelativeStep(delta: 1)

        case .previewPreviousStep:
            guard isNavigateTabActive else { return }
            await previewRelativeStep(delta: -1)

        case .recenterToLiveStep:
            guard isNavigateTabActive else { return }
            previewStepIndex = nil
            recenterCameraToCurrentRoute()
            await refreshNavigationBitmap(forceUpload: true)

        case .endNavigation:
            await stopNavigation()

        case .toggleMute:
            guard isNavigateTabActive else { return }
            isGuidanceMuted.toggle()
            _ = bluetoothManager?.toggleNavigationMute()
            activeInstructionSubtitle = isGuidanceMuted ? "Guidance muted" : "Guidance unmuted"

        case .showOverlay:
            overviewHoldUntil = Date().addingTimeInterval(overviewHoldSeconds)
            scheduleOverviewAutoReturn()
            await setGlassesDisplayDetail(.detailed)
            if isNavigateTabActive {
                isOverlayVisible = true
                bluetoothManager?.setNavigationOverlayVisible(true)
            }

        case .hideOverlay:
            if let overviewHoldUntil, Date() < overviewHoldUntil {
                // #region agent log
                agentLog("H22", "head-down ignored during overview hold", [
                    "remainingSeconds": overviewHoldUntil.timeIntervalSinceNow,
                    "currentDetail": glassesDisplayDetail.rawValue
                ])
                // #endregion
                return
            }
            await returnToHeadLevelView()
        }
    }

    // MARK: - Internal Updates

    private func enqueueLocationUpdate(_ location: CLLocation) async {
        // #region agent log
        agentLog("H32", "location enqueued", [
            "coalescedAway": isProcessingLocationUpdate,
            "state": String(describing: state)
        ])
        // #endregion
        pendingLocationUpdate = location
        guard !isProcessingLocationUpdate else { return }

        isProcessingLocationUpdate = true
        defer { isProcessingLocationUpdate = false }

        while let nextLocation = pendingLocationUpdate {
            pendingLocationUpdate = nil

            if let lastProcessedLocationAt {
                let elapsed = Date().timeIntervalSince(lastProcessedLocationAt)
                if elapsed < minimumLocationUpdateInterval {
                    let remaining = minimumLocationUpdateInterval - elapsed
                    try? await Task.sleep(for: .seconds(remaining))
                }
            }

            lastProcessedLocationAt = Date()
            await handleLocationUpdate(nextLocation)
        }
    }

    private func handleLocationUpdate(_ location: CLLocation) async {
        guard state == .navigating || state == .rerouting,
              let route = currentPlan?.route else {
            return
        }

        // Keep progress monotonic and limit look-ahead so parallel/crossing
        // route geometry cannot jump guidance arbitrarily far ahead.
        let update = RouteTracker.evaluate(
            location: location,
            route: route,
            currentStepIndex: activeStepIndex
        )
        latestTrackingUpdate = update
        userLocation = location.coordinate

        // #region agent log
        agentLog("H1", "location update evaluated", [
            "arrived": update.arrived,
            "remainingDistanceMeters": update.remainingDistanceMeters,
            "distanceToManeuverMeters": update.distanceToManeuverMeters,
            "nearestStepIndex": update.nearestStepIndex,
            "state": String(describing: state)
        ])
        // #endregion

        if isFollowingUser, isNavigateTabActive, isAppActive {
            applyCamera(to: location.coordinate, latLonDelta: Self.navigationFollowLatLonDelta)
        }

        let rawProgress = route.distance > 0
            ? max(0, min(1, 1 - (Double(update.remainingDistanceMeters) / route.distance)))
            : 0
        let quantizedProgress = (rawProgress * 200).rounded() / 200
        if lastPublishedProgressFraction != quantizedProgress {
            progressFraction = quantizedProgress
            lastPublishedProgressFraction = quantizedProgress
        }

        if update.arrived {
            state = .arrived
            periodicPushTask?.cancel()
            periodicPushTask = nil
            rerouteTask?.cancel()
            rerouteTask = nil
            routeTracker.stop()
            activeInstructionTitle = "Arrived"
            activeInstructionSubtitle = destinationTitle
            bluetoothManager?.setNavigationSessionState(.arrived)

            let arrivedInstruction = G1NavigationInstruction(
                text: "Arrived at \(destinationTitle)",
                stepIndex: update.nearestStepIndex,
                totalSteps: max(1, route.steps.count),
                distanceToManeuverMeters: 0,
                remainingDistanceMeters: 0,
                etaEpochSeconds: Int(Date().timeIntervalSince1970)
            )
            hudInstructionText = arrivedInstruction.fallbackText()
            // The map bitmap only renders while actively navigating, so the
            // arrival confirmation is delivered as text on the glasses.
            _ = await bluetoothManager?.sendNavigationInstruction(arrivedInstruction)
            transportModeLabel = bluetoothManager?.navigationTransportMode.displayName ?? transportModeLabel
            return
        }

        if update.isOffRoute {
            await triggerRerouteIfNeeded(from: location)
        }

        let stepChanged = update.nearestStepIndex != activeStepIndex
        activeStepIndex = update.nearestStepIndex

        if let instruction = buildInstruction(for: route, stepIndex: activeStepIndex, tracking: update) {
            activeInstructionTitle = instruction.text
            let roundedMeters = (max(0, update.distanceToManeuverMeters) / 10) * 10
            let subtitle = "In \(roundedMeters)m"
            if lastPublishedDistanceSubtitle != subtitle {
                activeInstructionSubtitle = subtitle
                lastPublishedDistanceSubtitle = subtitle
            }

            if stepChanged {
                await publishInstruction(instruction, forceEvenIfMuted: false)
            }

            let progress = G1NavigationProgress(
                stepIndex: update.nearestStepIndex,
                totalSteps: max(1, route.steps.count),
                remainingDistanceMeters: update.remainingDistanceMeters,
                remainingDurationSeconds: update.remainingDurationSeconds,
                etaEpochSeconds: Int(Date().addingTimeInterval(TimeInterval(update.remainingDurationSeconds)).timeIntervalSince1970)
            )

            if stepChanged || !isGuidanceMuted {
                await publishProgress(progress)
            }

            await publishNavigationMap(
                detail: glassesDisplayDetail,
                userLocation: location,
                stepChanged: stepChanged,
                forceUpload: stepChanged
            )
        }
    }

    private func triggerRerouteIfNeeded(from location: CLLocation) async {
        let now = Date()
        if let lastRerouteAt, now.timeIntervalSince(lastRerouteAt) < rerouteCooldownSeconds {
            return
        }
        lastRerouteAt = now

        guard let destination = currentDestination else {
            return
        }

        state = .rerouting
        bluetoothManager?.setNavigationSessionState(.rerouting)

        rerouteTask?.cancel()
        rerouteTask = Task { [weak self] in
            guard let self else { return }
            do {
                let plan = try await self.routePlanner.planRoute(
                    from: location.coordinate,
                    to: destination,
                    mode: self.selectedMode
                )

                guard !Task.isCancelled, self.state == .rerouting else { return }
                self.currentPlan = plan
                self.routePolyline = plan.route?.polyline
                self.activeStepIndex = 0
                self.previewStepIndex = nil
                self.latestTrackingUpdate = nil
                self.state = .navigating
                self.bluetoothManager?.setNavigationSessionState(.active)
                self.activeInstructionSubtitle = "Rerouted"
                await self.publishNavigationMap(
                    detail: self.glassesDisplayDetail,
                    userLocation: location,
                    stepChanged: true,
                    forceUpload: true
                )
            } catch {
                guard !Task.isCancelled, self.state == .rerouting else { return }
                // Keep tracking the previous route; a transient directions
                // failure should not terminate an active navigation session.
                self.state = .navigating
                self.bluetoothManager?.setNavigationSessionState(.active)
                self.activeInstructionSubtitle = "Unable to reroute; continuing current route"
            }
        }
    }

    private func previewRelativeStep(delta: Int) async {
        guard let route = currentPlan?.route,
              !route.steps.isEmpty else {
            return
        }

        let base = previewStepIndex ?? activeStepIndex
        let clamped = max(0, min(route.steps.count - 1, base + delta))
        previewStepIndex = clamped

        if let update = latestTrackingUpdate,
           let instruction = buildInstruction(for: route, stepIndex: clamped, tracking: update) {
            activeInstructionTitle = instruction.text
            activeInstructionSubtitle = "Preview step \(clamped + 1)"
            await publishInstruction(instruction, forceEvenIfMuted: true)
        }

        // Re-render the map for the previewed step so the glasses show the
        // relevant maneuver instead of leaving the previous frame in place.
        await refreshNavigationBitmap(forceUpload: true)
    }

    private func announceConciseStatus() async {
        guard let progress = latestProgressForDisplay() else {
            return
        }

        let summary = G1NavigationPacketBuilder.fallbackSummaryText(mode: selectedMode, progress: progress)
        let statusInstruction = G1NavigationInstruction(
            text: summary,
            stepIndex: progress.stepIndex,
            totalSteps: progress.totalSteps,
            distanceToManeuverMeters: latestTrackingUpdate?.distanceToManeuverMeters ?? 0,
            remainingDistanceMeters: progress.remainingDistanceMeters,
            etaEpochSeconds: progress.etaEpochSeconds
        )
        await publishInstruction(statusInstruction, forceEvenIfMuted: true)

        // Refresh the map so the status request re-surfaces the path rather than
        // leaving a stale (or text) frame on the glasses.
        await refreshNavigationBitmap(forceUpload: true)
    }

    /// When the glasses are connected we render the full navigation map (path +
    /// instruction + distance) as a bitmap. The glasses can only show one
    /// surface at a time, so sending text/native guidance packets would
    /// immediately overwrite that map. In that case the bitmap is the single
    /// source of truth and text sends are suppressed.
    private var glassesPrefersBitmap: Bool {
        bluetoothManager?.connectionState == .fullyConnected
    }

    private func lastKnownNavigationLocation() -> CLLocation? {
        if let tracked = latestTrackingUpdate?.location {
            return tracked
        }
        if let userLocation {
            return CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
        }
        return nil
    }

    /// Re-render and push the navigation map bitmap using the most recent known
    /// location. Used to keep the map on screen and current without letting text
    /// packets clobber it.
    private func refreshNavigationBitmap(stepChanged: Bool = false, forceUpload: Bool) async {
        guard let location = lastKnownNavigationLocation() else {
            return
        }
        await publishNavigationMap(
            detail: glassesDisplayDetail,
            userLocation: location,
            stepChanged: stepChanged,
            forceUpload: forceUpload
        )
    }

    private func publishInstruction(_ instruction: G1NavigationInstruction, forceEvenIfMuted: Bool) async {
        guard forceEvenIfMuted || !isGuidanceMuted else {
            return
        }

        hudInstructionText = instruction.fallbackText()

        // The bitmap map already carries this instruction; sending it as text
        // would overwrite the rendered path on the glasses.
        if glassesPrefersBitmap {
            return
        }

        _ = await bluetoothManager?.sendNavigationInstruction(instruction)
        transportModeLabel = bluetoothManager?.navigationTransportMode.displayName ?? transportModeLabel
    }

    private func publishProgress(_ progress: G1NavigationProgress) async {
        guard !isGuidanceMuted else {
            return
        }

        // Progress (distance/ETA) is baked into the bitmap; avoid the text
        // surface overwriting the map while connected.
        if glassesPrefersBitmap {
            return
        }

        _ = await bluetoothManager?.updateNavigationSession(progress: progress)
        transportModeLabel = bluetoothManager?.navigationTransportMode.displayName ?? transportModeLabel
    }

    /// Returns to the head-level map once the overview has had its turn, so a
    /// missing head-down cannot strand the glasses on the overview.
    private func scheduleOverviewAutoReturn() {
        overviewAutoReturnTask?.cancel()
        overviewAutoReturnTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.overviewHoldSeconds))
            guard !Task.isCancelled, self.glassesDisplayDetail == .detailed else { return }
            await self.returnToHeadLevelView()
        }
    }

    private func returnToHeadLevelView() async {
        overviewAutoReturnTask?.cancel()
        overviewAutoReturnTask = nil
        overviewHoldUntil = nil
        await setGlassesDisplayDetail(.minimal)
        if isNavigateTabActive {
            isOverlayVisible = false
            bluetoothManager?.setNavigationOverlayVisible(false)
        }
    }

    private func setGlassesDisplayDetail(_ detail: NavigationDisplayDetail) async {
        guard glassesDisplayDetail != detail else {
            // A repeated head gesture should recover the requested view if a
            // previous snapshot/upload was interrupted.
            await refreshNavigationBitmap(forceUpload: true)
            return
        }

        glassesDisplayDetail = detail
        glassesDisplayDetailLabel = detail == .detailed ? "Full map" : "Minimal path"
        mapTileUpgradeAttempts = 0
        mapTileUpgradeTask?.cancel()

        let location: CLLocation
        if let tracked = latestTrackingUpdate?.location {
            location = tracked
        } else if let coordinate = try? await oneShotLocationProvider.requestOneShotLocation() {
            location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        } else {
            return
        }

        await publishNavigationMap(
            detail: detail,
            userLocation: location,
            stepChanged: true,
            forceUpload: true
        )
    }

    /// Sends a route frame to the glasses, coalescing rapid refresh requests so
    /// gesture bursts do not stack overlapping 51-packet uploads.
    private func publishNavigationMap(detail: NavigationDisplayDetail,
                                      userLocation: CLLocation,
                                      stepChanged: Bool,
                                      forceUpload: Bool) async {
        pendingNavigationMapUpload = PendingNavigationMapUpload(
            detail: detail,
            userLocation: userLocation,
            stepChanged: stepChanged,
            forceUpload: forceUpload
        )

        if isNavigationMapUploadInFlight {
            await navigationMapUploadTask?.value
            return
        }

        navigationMapUploadTask = Task { [weak self] in
            await self?.drainNavigationMapUploadQueue()
        }
        await navigationMapUploadTask?.value
    }

    private func drainNavigationMapUploadQueue() async {
        guard !isNavigationMapUploadInFlight else { return }
        isNavigationMapUploadInFlight = true
        defer {
            isNavigationMapUploadInFlight = false
            navigationMapUploadTask = nil
        }

        repeat {
            guard let pending = pendingNavigationMapUpload else {
                break
            }
            pendingNavigationMapUpload = nil

            if !pending.forceUpload {
                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled else { return }
            await performNavigationMapUpload(pending)
        } while pendingNavigationMapUpload != nil
    }

    private func performNavigationMapUpload(_ pending: PendingNavigationMapUpload) async {
        let detail = pending.detail
        let userLocation = pending.userLocation
        let stepChanged = pending.stepChanged
        let forceUpload = pending.forceUpload

        // #region agent log
        agentLog("H1,H2,H4", "performNavigationMapUpload entry", [
            "detail": detail.rawValue,
            "forceUpload": forceUpload,
            "stepChanged": stepChanged,
            "state": String(describing: state),
            "isAppActive": isAppActive,
            "connectionState": String(describing: bluetoothManager?.connectionState),
            "hasRoute": currentPlan?.route != nil
        ])
        // #endregion

        guard isAppActive, state == .navigating || state == .rerouting else {
            return
        }
        let generation = navigationBitmapGeneration

        let now = Date()
        if !forceUpload {
            switch detail {
            case .minimal:
                if !stepChanged,
                   let lastMinimalBitmapAt,
                   now.timeIntervalSince(lastMinimalBitmapAt) < minimalBitmapInterval {
                    // #region agent log
                    agentLog("H30", "refresh skipped by interval", [
                        "detail": detail.rawValue,
                        "secondsSinceLastUpload": now.timeIntervalSince(lastMinimalBitmapAt)
                    ])
                    // #endregion
                    return
                }
            case .detailed:
                if let lastDetailedBitmapAt,
                   now.timeIntervalSince(lastDetailedBitmapAt) < detailedBitmapInterval {
                    return
                }
            }
        }

        let builtScene = buildNavigationMapScene(detail: detail, userLocation: userLocation)
        guard let scene = builtScene else {
            // #region agent log
            agentLog("H2", "scene build returned nil", ["hasRoute": currentPlan?.route != nil])
            // #endregion
            return
        }

        if !forceUpload, lastUploadedBitmapSignature == scene.uploadSignature {
            // #region agent log
            agentLog("H30", "refresh skipped, identical signature", [
                "detail": detail.rawValue,
                "signature": scene.uploadSignature,
                "secondsSinceLastUpload": lastMinimalBitmapAt.map { now.timeIntervalSince($0) } ?? -1
            ])
            // #endregion
            return
        }

        // Forced updates (startup, head gestures, step changes) must reach the
        // glasses immediately, so they only wait briefly for map tiles and fall
        // back to plain route geometry. A follow-up pass below swaps in the
        // street map once the snapshot lands.
        let rendered = try? await bitmapRenderer.render(
            scene: scene,
            snapshotTimeout: forceUpload ? .milliseconds(900) : .seconds(4)
        )

        // #region agent log
        agentLog("H2,H3", "render finished", [
            "renderedNil": rendered == nil,
            "usedMapTiles": rendered?.usedMapTiles ?? false,
            "routeCoordinateCount": scene.routeCoordinates.count,
            "generationMatch": generation == navigationBitmapGeneration,
            "state": String(describing: state)
        ])
        // #endregion

        guard let rendered else {
            return
        }
        guard generation == navigationBitmapGeneration,
              isAppActive,
              state == .navigating || state == .rerouting else {
            return
        }

        currentNavVisualImage = rendered.image
        lastUploadedBitmapSignature = scene.uploadSignature

        switch detail {
        case .minimal:
            lastMinimalBitmapAt = now
        case .detailed:
            lastDetailedBitmapAt = now
        }

        let connectionAtUpload = String(describing: bluetoothManager?.connectionState)
        guard bluetoothManager?.connectionState == .fullyConnected else {
            // #region agent log
            agentLog("H4", "upload skipped, not fully connected", ["connectionState": connectionAtUpload])
            // #endregion
            return
        }

        let sent = await uploadNavigationBitmap(rendered.frame, detail: detail)
        // #region agent log
        agentLog("H4,H5,H24", "bitmap upload result", [
            "sent": sent,
            "detail": detail.rawValue,
            "connectionState": connectionAtUpload,
            "msSinceNavigationStart": navigationStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        ])
        // #endregion
        if !sent {
            lastUploadedBitmapSignature = nil
        }

        if rendered.usedMapTiles {
            mapTileUpgradeAttempts = 0
        } else if sent {
            scheduleMapTileUpgrade(for: detail)
        }
    }

    /// Re-renders shortly after a tile-less frame so the street map replaces the
    /// bare route once MapKit finishes the snapshot.
    private func scheduleMapTileUpgrade(for detail: NavigationDisplayDetail) {
        guard mapTileUpgradeAttempts < maximumMapTileUpgradeAttempts else {
            return
        }
        mapTileUpgradeAttempts += 1

        let generation = navigationBitmapGeneration
        mapTileUpgradeTask?.cancel()
        mapTileUpgradeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard let self, !Task.isCancelled else { return }
            guard generation == self.navigationBitmapGeneration,
                  self.glassesDisplayDetail == detail else {
                return
            }
            await self.refreshNavigationBitmap(forceUpload: true)
        }
    }

    @discardableResult
    private func uploadNavigationBitmap(_ frame: G1BitmapFrame,
                                        detail: NavigationDisplayDetail) async -> Bool {
        guard let bluetoothManager else {
            return false
        }

        let sent = await bluetoothManager.sendBitmap(frame)
        if sent {
            DatadogTelemetryService.shared.trackAction(
                type: .custom,
                name: "navigation_map_upload",
                attributes: ["detail": detail.rawValue]
            )
        } else {
            DatadogTelemetryService.shared.trackAction(
                type: .custom,
                name: "navigation_map_upload_failed",
                attributes: ["detail": detail.rawValue]
            )
        }
        return sent
    }

    private func buildNavigationMapScene(detail: NavigationDisplayDetail,
                                         userLocation: CLLocation) -> NavigationMapScene? {
        guard let route = currentPlan?.route else {
            return nil
        }

        let remainingRoute = NavigationBitmapRenderer.remainingRouteCoordinates(
            route: route,
            userLocation: userLocation
        )
        guard let resolvedDestination = destinationCoordinate ?? remainingRoute.last else {
            return nil
        }

        let stepIndex = previewStepIndex ?? activeStepIndex
        let tracking = latestTrackingUpdate
        let instruction = buildInstruction(for: route, stepIndex: stepIndex, tracking: tracking)

        let clampedStep = max(0, min(stepIndex, max(route.steps.count - 1, 0)))
        let maneuverCoordinate = route.steps.indices.contains(clampedStep)
            ? NavigationBitmapRenderer.lastCoordinate(from: route.steps[clampedStep].polyline)
            : resolvedDestination

        let remainingMinutes = max(1, (tracking?.remainingDurationSeconds ?? Int(route.expectedTravelTime)) / 60)

        return NavigationMapScene(
            detailLevel: detail,
            userCoordinate: userLocation.coordinate,
            destinationCoordinate: resolvedDestination,
            routeCoordinates: remainingRoute,
            maneuverCoordinate: maneuverCoordinate,
            instructionText: instruction?.text ?? destinationTitle,
            distanceToManeuverMeters: tracking?.distanceToManeuverMeters ?? 0,
            remainingDistanceMeters: tracking?.remainingDistanceMeters ?? Int(route.distance),
            remainingMinutes: remainingMinutes
        )
    }

    private func startPeriodicStatusPush() {
        periodicPushTask?.cancel()
        periodicPushTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self {
                    if self.isAppActive, self.state == .navigating || self.state == .rerouting {
                        if self.glassesPrefersBitmap {
                            // Keep the rendered map on screen and current instead
                            // of pushing status text that would overwrite it.
                            await self.refreshNavigationBitmap(forceUpload: false)
                        } else if let progress = self.latestProgressForDisplay() {
                            await self.publishProgress(progress)
                        }
                    }
                } else {
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    break
                }
            }
        }
    }

    private func latestProgressForDisplay() -> G1NavigationProgress? {
        guard let update = latestTrackingUpdate,
              let plan = currentPlan else {
            return nil
        }

        let totalSteps = max(1, plan.route?.steps.count ?? 1)
        return G1NavigationProgress(
            stepIndex: min(update.nearestStepIndex, totalSteps - 1),
            totalSteps: totalSteps,
            remainingDistanceMeters: max(0, update.remainingDistanceMeters),
            remainingDurationSeconds: max(0, update.remainingDurationSeconds),
            etaEpochSeconds: Int(Date().addingTimeInterval(TimeInterval(max(0, update.remainingDurationSeconds))).timeIntervalSince1970)
        )
    }

    private func latestInstructionForDisplay() -> G1NavigationInstruction? {
        if let route = currentPlan?.route,
           let update = latestTrackingUpdate {
            return buildInstruction(for: route, stepIndex: previewStepIndex ?? activeStepIndex, tracking: update)
        }

        if let progress = latestProgressForDisplay() {
            return G1NavigationInstruction(
                text: G1NavigationPacketBuilder.fallbackSummaryText(mode: selectedMode, progress: progress),
                stepIndex: progress.stepIndex,
                totalSteps: progress.totalSteps,
                distanceToManeuverMeters: latestTrackingUpdate?.distanceToManeuverMeters ?? 0,
                remainingDistanceMeters: progress.remainingDistanceMeters,
                etaEpochSeconds: progress.etaEpochSeconds
            )
        }

        return nil
    }

    private func buildInstruction(for route: MKRoute,
                                  stepIndex: Int,
                                  tracking: RouteTrackingUpdate?) -> G1NavigationInstruction? {
        guard !route.steps.isEmpty else {
            return nil
        }

        let clampedStep = max(0, min(stepIndex, route.steps.count - 1))
        let step = route.steps[clampedStep]

        let instructionText: String
        let raw = step.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            instructionText = "Continue"
        } else {
            instructionText = raw
        }

        let distanceToManeuver = tracking?.distanceToManeuverMeters ?? Int(step.distance)
        let remainingDistance = tracking?.remainingDistanceMeters ?? Int(max(0, route.distance - step.distance))
        let etaEpoch = tracking.map {
            Int(Date().addingTimeInterval(TimeInterval(max(0, $0.remainingDurationSeconds))).timeIntervalSince1970)
        }

        return G1NavigationInstruction(
            text: instructionText,
            stepIndex: clampedStep,
            totalSteps: max(1, route.steps.count),
            distanceToManeuverMeters: distanceToManeuver,
            remainingDistanceMeters: remainingDistance,
            etaEpochSeconds: etaEpoch
        )
    }

    private func refreshLocationAuthorizationStatus() {
        locationAuthorizationStatus = oneShotLocationProvider.authorizationStatus
    }

    private func updateSearchRegionIfNeeded() {
        if let userLocation {
            updateSearchRegion(center: userLocation)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            if let coordinate = try? await self.oneShotLocationProvider.requestOneShotLocation() {
                self.userLocation = coordinate
                self.updateSearchRegion(center: coordinate)
            }
        }
    }

    private func updateSearchRegion(center: CLLocationCoordinate2D) {
        searchService.updateRegion(center: center)
    }

    private func resolveMapItemForSaving() async throws -> MKMapItem {
        if let currentDestination {
            return currentDestination
        }

        if let firstSuggestion = suggestions.first {
            return try await searchService.resolve(firstSuggestion)
        }

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw FavoriteSaveError.noLocationSelected
        }

        updateSearchRegionIfNeeded()
        return try await searchService.resolveNaturalLanguageQuery(query)
    }

    private enum FavoriteSaveError: Error {
        case noLocationSelected
    }

    private func applyCamera(to coordinate: CLLocationCoordinate2D, latLonDelta: Double) {
        setCameraPosition(.region(Self.region(around: coordinate, latLonDelta: latLonDelta)))
    }

    private func setCameraPosition(_ position: MapCameraPosition) {
        isProgrammaticCameraMove = true
        cameraPosition = position
        cameraMoveResetTask?.cancel()
        cameraMoveResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.isProgrammaticCameraMove = false
            self?.cameraMoveResetTask = nil
        }
    }

    private func recenterCameraToCurrentRoute() {
        if let route = currentPlan?.route {
            let rect = route.polyline.boundingMapRect
            if !rect.isNull {
                setCameraPosition(.rect(rect))
                return
            }
        }

        if let destinationCoordinate {
            let region = MKCoordinateRegion(
                center: destinationCoordinate,
                latitudinalMeters: 1800,
                longitudinalMeters: 1800
            )
            setCameraPosition(.region(region))
        }
    }

    // #region agent log
    /// Read-only view of the debounce window, so instrumentation can report a
    /// dropped gesture without consuming it.
    private func isGestureWithinDebounce(_ action: G1NavigationGestureAction) -> Bool {
        guard let lastFired = gestureLastFiredAt[action] else { return false }
        return Date().timeIntervalSince(lastFired) < gestureDebounceSeconds
    }
    // #endregion

    private func shouldHandleGesture(_ action: G1NavigationGestureAction) -> Bool {
        let now = Date()
        if let lastFired = gestureLastFiredAt[action],
           now.timeIntervalSince(lastFired) < gestureDebounceSeconds {
            return false
        }

        gestureLastFiredAt[action] = now
        return true
    }

    private func bindSearch() {
        searchService.$suggestions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.suggestions = value
                if !value.isEmpty {
                    DatadogTelemetryService.shared.trackTiming(name: "search_results")
                }
                if self.state == .searching, !value.isEmpty {
                    self.activeInstructionTitle = "Select destination"
                    self.activeInstructionSubtitle = "\(value.count) result(s)"
                }
            }
            .store(in: &cancellables)
    }

    private func bindFavorites() {
        favoritesStore.$favorites
            .receive(on: DispatchQueue.main)
            .sink { [weak self] values in
                self?.favorites = values
            }
            .store(in: &cancellables)
    }

    private func subtitleForPreview(_ plan: NavigationRoutePlan) -> String {
        let distance = Int(plan.estimatedDistanceMeters)
        let minutes = Int(max(1, plan.estimatedDurationSeconds / 60))

        return "\(plan.mode.displayName) · \(distance)m · \(minutes)m"
    }

    private func userFacingError(_ error: Error) -> String {
        if let locationError = error as? CurrentLocationError {
            switch locationError {
            case .servicesDisabled:
                return "Location services are disabled."
            case .deniedOrRestricted:
                return "Enable location permissions to route."
            case .timeout:
                return "Location request timed out."
            case .noLocation:
                return "Current location unavailable."
            case .underlying(let details):
                return "Location error: \(details)"
            }
        }

        if error is RoutePlannerError {
            return "No route found for the selected mode."
        }

        return error.localizedDescription
    }
}
