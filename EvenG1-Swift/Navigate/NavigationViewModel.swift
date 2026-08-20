import Combine
import CoreLocation
import Foundation
import MapKit
import SwiftUI
import UIKit
import EvenG1Core

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

    var canStartTurnByTurn: Bool {
        currentPlan?.route != nil
    }

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
        do {
            state = .searching
            let mapItem = try await searchService.resolve(suggestion)
            await previewRoute(to: mapItem)
        } catch {
            state = .error("Could not resolve location")
            DatadogTelemetryService.shared.capture(
                error: error,
                message: "Navigation search result could not be resolved",
                attributes: ["component": "navigation", "operation": "resolve_search_result"]
            )
        }
    }

    func previewFavorite(_ favorite: NavigationFavorite) async {
        if let item = favorite.toMapItem() {
            await previewRoute(to: item)
        }
    }

    func previewFavorite(named name: String) async {
        guard let favorite = favorite(named: name) else { return }
        await previewFavorite(favorite)
    }

    func startNavigationToFavorite(named name: String) async {
        guard let favorite = favorite(named: name) else { return }
        guard let item = favorite.toMapItem() else {
            state = .error("\(favorite.title) does not have a saved location.")
            return
        }
        await previewRoute(to: item)
        guard state == .routePreview, canStartTurnByTurn else { return }
        await startNavigation()
    }

    func previewRoute(to destination: MKMapItem) async {
        let startedAt = Date()
        do {
            stopFollowingUser()
            state = .searching
            let source = try await oneShotLocationProvider.requestOneShotLocation()
            userLocation = source
            updateSearchRegion(center: source)
            let plan = try await routePlanner.planRoute(from: source, to: destination, mode: selectedMode)

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
            DatadogTelemetryService.shared.trackProductEvent(
                name: "navigation_route_previewed",
                attributes: [
                    "navigation.mode": selectedMode.displayName.lowercased(),
                    "route.distance_meters": Int(plan.estimatedDistanceMeters),
                    "route.duration_seconds": Int(plan.estimatedDurationSeconds),
                    "operation.duration_ms": Int(Date().timeIntervalSince(startedAt) * 1_000)
                ]
            )
        } catch {
            state = .error(userFacingError(error))
            activeInstructionTitle = "Route unavailable"
            activeInstructionSubtitle = userFacingError(error)
            DatadogTelemetryService.shared.capture(
                error: error,
                message: "Navigation route preview failed",
                attributes: [
                    "component": "navigation",
                    "operation": "preview_route",
                    "navigation.mode": selectedMode.displayName.lowercased(),
                    "operation.duration_ms": Int(Date().timeIntervalSince(startedAt) * 1_000)
                ]
            )
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

            if let coordinate = initialCoordinate {
                let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                userLocation = coordinate

                let generation = navigationBitmapGeneration
                navigationSetupTask = Task { [weak self] in
                    guard let self else { return }
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
        DatadogTelemetryService.shared.trackProductEvent(
            name: "navigation_started",
            attributes: [
                "navigation.mode": selectedMode.displayName.lowercased(),
                "navigation.transport": transportModeLabel.lowercased(),
                "route.has_turn_by_turn": plan.route != nil
            ]
        )
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

        DatadogTelemetryService.shared.trackProductEvent(
            name: "navigation_stopped",
            attributes: ["navigation.mode": selectedMode.displayName.lowercased()]
        )
    }

    func saveFavorite(kind: NavigationFavoriteKind) async {
        guard kind == .home || kind == .office else { return }

        do {
            let mapItem = try await resolveMapItemForSaving()
            favoritesStore.setFavorite(kind: kind, mapItem: mapItem)
            favoriteActionMessage = "\(kind == .home ? "Home" : "Office") saved"
        } catch {
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
                return
            }
            await returnToHeadLevelView()
        }
    }

    // MARK: - Internal Updates

    private func enqueueLocationUpdate(_ location: CLLocation) async {
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
            // The map bitmap only renders while actively navigating, so the
            // arrival confirmation is delivered as text on the glasses.
            await publishInstruction(arrivedInstruction, forceEvenIfMuted: true)
            transportModeLabel = bluetoothManager?.navigationTransportMode.displayName ?? transportModeLabel
            DatadogTelemetryService.shared.trackProductEvent(
                name: "navigation_arrived",
                attributes: [
                    "navigation.mode": selectedMode.displayName.lowercased(),
                    "route.total_steps": max(1, route.steps.count)
                ]
            )
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
        DatadogTelemetryService.shared.trackProductEvent(
            name: "navigation_reroute_started",
            attributes: ["navigation.mode": selectedMode.displayName.lowercased()]
        )

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
                DatadogTelemetryService.shared.trackProductEvent(
                    name: "navigation_reroute_succeeded",
                    attributes: ["navigation.mode": self.selectedMode.displayName.lowercased()]
                )
            } catch {
                guard !Task.isCancelled, self.state == .rerouting else { return }
                // Keep tracking the previous route; a transient directions
                // failure should not terminate an active navigation session.
                self.state = .navigating
                self.bluetoothManager?.setNavigationSessionState(.active)
                self.activeInstructionSubtitle = "Unable to reroute; continuing current route"
                DatadogTelemetryService.shared.capture(
                    error: error,
                    message: "Navigation reroute failed",
                    attributes: [
                        "component": "navigation",
                        "operation": "reroute",
                        "navigation.mode": self.selectedMode.displayName.lowercased()
                    ]
                )
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
            // previous render or upload was interrupted.
            await refreshNavigationBitmap(forceUpload: true)
            return
        }

        glassesDisplayDetail = detail
        glassesDisplayDetailLabel = detail == .detailed ? "Full map" : "Minimal path"

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
            return
        }

        if !forceUpload, lastUploadedBitmapSignature == scene.uploadSignature {
            return
        }

        let rendered = try? await bitmapRenderer.render(scene: scene)

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

        guard bluetoothManager?.connectionState == .fullyConnected else {
            return
        }

        let sent = await uploadNavigationBitmap(rendered.frame, detail: detail)
        if !sent {
            lastUploadedBitmapSignature = nil
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
        if plan.mode == .transit, !plan.hasInAppRoute {
            return "Transit ETA · \(minutes)m · open Transit for NYC arrivals"
        }
        return "\(plan.mode.displayName) · \(distance)m · \(minutes)m"
    }

    private func favorite(named name: String) -> NavigationFavorite? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let favorite = favorites.first(where: {
            $0.title.localizedCaseInsensitiveCompare(normalized) == .orderedSame
        }) else {
            state = .error("No saved destination named \(normalized).")
            return nil
        }
        return favorite
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
