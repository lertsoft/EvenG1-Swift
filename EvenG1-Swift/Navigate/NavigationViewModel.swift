import Combine
import CoreLocation
import Foundation
import MapKit
import SwiftUI
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

    @Published private(set) var favorites: [NavigationFavorite] = []

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
    private var isNavigateTabActive = false
    private var cancellables = Set<AnyCancellable>()

    private var gestureLastFiredAt: [G1NavigationGestureAction: Date] = [:]
    private let gestureDebounceSeconds: TimeInterval = 0.35
    private let rerouteCooldownSeconds: TimeInterval = 8
    private var lastRerouteAt: Date?

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

    func setNavigateTabActive(_ isActive: Bool) {
        isNavigateTabActive = isActive
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
        searchService.updateQuery(query)
    }

    func selectSuggestion(_ suggestion: MapSearchSuggestion) async {
        do {
            state = .searching
            let mapItem = try await searchService.resolve(suggestion)
            await previewRoute(to: mapItem)
        } catch {
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
            state = .searching
            let source = try await oneShotLocationProvider.requestOneShotLocation()
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
                    cameraPosition = .rect(rect)
                }
            } else if let coordinate = destinationCoordinate {
                let region = MKCoordinateRegion(
                    center: coordinate,
                    latitudinalMeters: 1800,
                    longitudinalMeters: 1800
                )
                cameraPosition = .region(region)
            }
        } catch {
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
        routeTracker.stop()

        state = .navigating
        activeStepIndex = 0
        previewStepIndex = nil
        latestTrackingUpdate = nil

        await bluetoothManager?.startNavigationSession(mode: selectedMode)
        transportModeLabel = bluetoothManager?.navigationTransportMode.displayName ?? transportModeLabel

        if let route = plan.route {
            routeTracker.start { [weak self] location in
                Task { @MainActor in
                    await self?.handleLocationUpdate(location)
                }
            }

            if let initialInstruction = buildInstruction(for: route, stepIndex: 0, tracking: nil) {
                await publishInstruction(initialInstruction, forceEvenIfMuted: true)
            }
        }

        startPeriodicStatusPush()
    }

    func stopNavigation() async {
        periodicPushTask?.cancel()
        periodicPushTask = nil
        rerouteTask?.cancel()
        rerouteTask = nil
        routeTracker.stop()
        previewStepIndex = nil

        _ = await bluetoothManager?.stopNavigationSession(sendSummary: true)
        transportModeLabel = bluetoothManager?.navigationTransportMode.displayName ?? transportModeLabel

        state = .idle
        activeInstructionTitle = "Navigation stopped"
        activeInstructionSubtitle = "Search for another destination"
        progressFraction = 0
        hudInstructionText = ""
    }

    func setFavorite(kind: NavigationFavoriteKind) {
        guard kind == .home || kind == .office,
              let currentDestination else {
            return
        }

        favoritesStore.setFavorite(kind: kind, mapItem: currentDestination)
    }

    func addCurrentAsCustomFavorite() {
        guard let currentDestination else {
            return
        }
        favoritesStore.addCustom(mapItem: currentDestination)
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

        guard isNavigateTabActive,
              let action = G1NavigationGestureMapper.action(for: event, isNavigationActive: isNavigationActive),
              shouldHandleGesture(action) else {
            return
        }

        switch action {
        case .repeatCurrentInstruction:
            if let instruction = latestInstructionForDisplay() {
                await publishInstruction(instruction, forceEvenIfMuted: true)
            }

        case .announceStatus:
            await announceConciseStatus()

        case .previewNextStep:
            await previewRelativeStep(delta: 1)

        case .previewPreviousStep:
            await previewRelativeStep(delta: -1)

        case .recenterToLiveStep:
            previewStepIndex = nil
            recenterCameraToCurrentRoute()

        case .endNavigation:
            await stopNavigation()

        case .toggleMute:
            isGuidanceMuted.toggle()
            _ = bluetoothManager?.toggleNavigationMute()
            activeInstructionSubtitle = isGuidanceMuted ? "Guidance muted" : "Guidance unmuted"

        case .showOverlay:
            isOverlayVisible = true
            bluetoothManager?.setNavigationOverlayVisible(true)

        case .hideOverlay:
            isOverlayVisible = false
            bluetoothManager?.setNavigationOverlayVisible(false)
        }
    }

    // MARK: - Internal Updates

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
        progressFraction = route.distance > 0 ? max(0, min(1, 1 - (Double(update.remainingDistanceMeters) / route.distance))) : 0

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
            await publishInstruction(arrivedInstruction, forceEvenIfMuted: true)
            return
        }

        if update.isOffRoute {
            await triggerRerouteIfNeeded(from: location)
        }

        let stepChanged = update.nearestStepIndex != activeStepIndex
        activeStepIndex = update.nearestStepIndex

        if let instruction = buildInstruction(for: route, stepIndex: activeStepIndex, tracking: update) {
            activeInstructionTitle = instruction.text
            activeInstructionSubtitle = "In \(max(0, update.distanceToManeuverMeters))m"

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
    }

    private func publishInstruction(_ instruction: G1NavigationInstruction, forceEvenIfMuted: Bool) async {
        guard forceEvenIfMuted || !isGuidanceMuted else {
            return
        }

        hudInstructionText = instruction.fallbackText()
        _ = await bluetoothManager?.sendNavigationInstruction(instruction)
        transportModeLabel = bluetoothManager?.navigationTransportMode.displayName ?? transportModeLabel
    }

    private func publishProgress(_ progress: G1NavigationProgress) async {
        guard !isGuidanceMuted else {
            return
        }
        _ = await bluetoothManager?.updateNavigationSession(progress: progress)
        transportModeLabel = bluetoothManager?.navigationTransportMode.displayName ?? transportModeLabel
    }

    private func startPeriodicStatusPush() {
        periodicPushTask?.cancel()
        periodicPushTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if self.state == .navigating || self.state == .rerouting {
                    if let progress = self.latestProgressForDisplay() {
                        await self.publishProgress(progress)
                    }
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

    private func recenterCameraToCurrentRoute() {
        if let route = currentPlan?.route {
            let rect = route.polyline.boundingMapRect
            if !rect.isNull {
                cameraPosition = .rect(rect)
                return
            }
        }

        if let destinationCoordinate {
            let region = MKCoordinateRegion(
                center: destinationCoordinate,
                latitudinalMeters: 1800,
                longitudinalMeters: 1800
            )
            cameraPosition = .region(region)
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
                if self.state == .searching, !value.isEmpty {
                    self.state = .routePreview
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
