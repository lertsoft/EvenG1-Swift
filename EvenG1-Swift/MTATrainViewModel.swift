import CoreLocation
import EvenG1Core
import Foundation
import Combine

@MainActor
final class MTATrainViewModel: ObservableObject {
    enum RefreshTrigger: String {
        case manualButton
        case autoTimer
        case doubleTapGesture
        case headTiltGesture
    }

    @Published private(set) var isRefreshing = false
    @Published private(set) var statusTitle = "No train lookup yet"
    @Published private(set) var statusDetail = "Tap Refresh to fetch the nearest MTA arrival."
    @Published private(set) var lastResult: MTANextTrainResult?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var autoRefreshEnabled = false

    private let locationProvider: LocationProviding
    private let transitService: MTANextTrainService
    private weak var bluetoothManager: G1BluetoothManager?

    private var autoRefreshTask: Task<Void, Never>?
    private var isDisplayTabActive = false
    private var lastTiltRefreshAt: Date?
    private let tiltRefreshDebounceSeconds: TimeInterval = 2.0

    init(locationProvider: LocationProviding, transitService: MTANextTrainService) {
        self.locationProvider = locationProvider
        self.transitService = transitService
    }

    convenience init() {
        self.init(
            locationProvider: CurrentLocationProvider(),
            transitService: MTANextTrainService(
                apiKeyProvider: {
                    Bundle.main.infoDictionary?["MTA_API_KEY"] as? String
                }
            )
        )
    }

    func bind(bluetoothManager: G1BluetoothManager) {
        self.bluetoothManager = bluetoothManager
    }

    func setDisplayTabActive(_ isActive: Bool) {
        isDisplayTabActive = isActive
        updateAutoRefreshTask()
    }

    func setAutoRefreshEnabled(_ enabled: Bool) {
        autoRefreshEnabled = enabled
        updateAutoRefreshTask()
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
            let coordinate = try await locationProvider.requestOneShotLocation()
            let result = try await transitService.fetchNextTrain(near: coordinate, now: Date())

            lastResult = result
            lastUpdatedAt = Date()
            statusTitle = "\(result.routeID) \(result.direction) in \(result.minutesAway)m"
            statusDetail = "\(result.stationName)"

            sendResultToGlassesIfConnected(result)
        } catch {
            let message = userFacingMessage(for: error)
            errorMessage = message
            statusTitle = "MTA lookup failed"
            statusDetail = message

            if trigger == .manualButton {
                let fallbackText = "MTA error: \(message)"
                sendTextToGlassesIfConnected(fallbackText)
            }
        }
    }

    func handleGlassesEvent(_ event: G1Event) async {
        guard isDisplayTabActive else {
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
        default:
            return
        }
    }

    private func updateAutoRefreshTask() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil

        guard autoRefreshEnabled, isDisplayTabActive else {
            return
        }

        autoRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshNow(trigger: .autoTimer)
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
    }

    private func sendResultToGlassesIfConnected(_ result: MTANextTrainResult) {
        let shortDirection: String
        switch result.direction {
        case "Northbound": shortDirection = "NB"
        case "Southbound": shortDirection = "SB"
        case "Eastbound": shortDirection = "EB"
        case "Westbound": shortDirection = "WB"
        default: shortDirection = "?"
        }

        let text = "MTA \(result.routeID) \(shortDirection) \(result.minutesAway)m \(result.stationName)"
        sendTextToGlassesIfConnected(text)
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
            case .missingAPIKey:
                return "Missing MTA API key. Set MTA_API_KEY in build settings."
            case .stationDataUnavailable:
                return "Could not load station metadata from MTA open data."
            case .noUpcomingArrival:
                return "No upcoming arrival found near your closest station."
            case .networkFailure(let details):
                return "Realtime feed request failed: \(details)"
            }
        }

        return error.localizedDescription
    }
}
