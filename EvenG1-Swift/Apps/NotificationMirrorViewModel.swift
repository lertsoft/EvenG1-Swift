import Combine
import EvenG1Core
import Foundation
import UIKit
import UserNotifications

/// Bridges notification events and head gestures to the lens.
///
/// The state machine in `G1NotificationMirror` decides *what* to show; this type
/// decides *whether* it may be shown right now (connected, foreground, and not
/// outranked by navigation) and performs the BLE writes in order.
@MainActor
final class NotificationMirrorViewModel: ObservableObject {
    /// Long enough to read a couple of lines, short enough that a message the
    /// wearer looked at and ignored does not sit on the lens indefinitely.
    private static let readTimeoutSeconds: TimeInterval = 15
    private static let enabledDefaultsKey = "notificationMirror.enabled"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var pendingCount = 0
    @Published private(set) var isReading = false
    @Published private(set) var statusMessage = "Mirror is off."
    /// Icon currently destined for the lens, for the in-app preview.
    @Published private(set) var previewIcon: UIImage?
    /// Message currently on the lens, for the in-app preview.
    @Published private(set) var previewText: String?
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private var mirror = G1NotificationMirror()
    private weak var bluetoothManager: G1BluetoothManager?
    private let renderer = NotificationIconRenderer()

    private var isNavigationOwningDisplay = false
    private var isAppActive = true
    private var isConnected = false

    /// FIFO chain so a later display command cannot overtake an earlier one.
    private var displayTask: Task<Void, Never>?
    private var readTimeoutTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        // UI tests assert the mirror starts off, so a flag left on by an earlier
        // run must not carry into the next launch.
        let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        self.isEnabled = isUITesting ? false : defaults.bool(forKey: Self.enabledDefaultsKey)
        self.statusMessage = isEnabled ? "Waiting for a notification." : "Mirror is off."
    }

    // MARK: - Wiring

    func bind(bluetoothManager: G1BluetoothManager) {
        self.bluetoothManager = bluetoothManager
        isConnected = bluetoothManager.connectionState == .fullyConnected
        syncSurfaceClaim()
    }

    /// Whether the mirror should receive head gestures. Consulted by
    /// `G1LensSurfaceArbiter` so an idle mirror does not steal them from transit.
    var isEligibleForHeadGestures: Bool {
        isEnabled && (mirror.ownsDisplay || mirror.hasContent)
    }

    func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)

        if enabled {
            statusMessage = "Waiting for a notification."
        } else {
            apply(.reset)
            statusMessage = "Mirror is off."
        }
    }

    func setNavigationSessionState(_ state: G1NavigationSessionState) {
        // Navigation owns the lens for the whole trip, including arrival, which
        // still draws to the surface.
        isNavigationOwningDisplay = state != .inactive
        syncSuspension()
    }

    func setAppActive(_ active: Bool) {
        // Without a background BLE mode the app is suspended shortly after
        // leaving the foreground, so writes queued there would never land.
        isAppActive = active
        syncSuspension()
    }

    func setConnected(_ connected: Bool) {
        guard isConnected != connected else { return }
        isConnected = connected
        if !connected {
            // The lens is blank after a disconnect and unread state would be
            // stale by the time the glasses come back.
            apply(.reset)
            if isEnabled {
                statusMessage = "Glasses disconnected."
            }
        } else if isEnabled {
            statusMessage = "Waiting for a notification."
        }
    }

    // MARK: - Sources

    func post(title: String, body: String, id: String = UUID().uuidString) {
        guard isEnabled else { return }
        let notification = G1MirroredNotification(
            id: id,
            title: title,
            body: body,
            receivedAt: Date()
        )
        apply(.arrived(notification))
    }

    func handleGlassesEvent(_ event: G1Event) {
        guard isEnabled else { return }
        switch event {
        case .headUp:
            apply(.headUp)
        case .headDown:
            apply(.headDown)
        default:
            break
        }
    }

    /// Dismiss whatever is showing, from the phone.
    func dismissAll() {
        apply(.reset)
        if isEnabled {
            statusMessage = "Cleared."
        }
    }

    // MARK: - Notification authorization

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    func requestAuthorization() async {
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            statusMessage = "Could not request notification permission."
        }
        await refreshAuthorizationStatus()
    }

    /// Posts a real local notification so the delegate path can be exercised,
    /// rather than only the direct in-app hand-off.
    func scheduleLocalNotification(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            statusMessage = "Local notification scheduled in 2s."
        } catch {
            statusMessage = "Could not schedule local notification."
        }
    }

    // MARK: - State machine plumbing

    private func syncSuspension() {
        if isNavigationOwningDisplay || !isAppActive {
            apply(.suspend)
        } else {
            apply(.resume)
        }
    }

    private func apply(_ input: G1NotificationMirrorInput) {
        let display = mirror.apply(input, now: Date())
        refreshPublishedState()
        syncSurfaceClaim()

        guard let display else { return }
        scheduleReadTimeout(for: display)
        enqueueDisplay(display)
    }

    private func refreshPublishedState() {
        pendingCount = mirror.pendingCount
        if case .reading = mirror.state {
            isReading = true
        } else {
            isReading = false
        }

        guard isEnabled else {
            previewIcon = nil
            previewText = nil
            return
        }

        switch mirror.state {
        case .reading(let notification):
            previewIcon = nil
            previewText = notification.lensText
            statusMessage = "Reading on the lens."
        case .iconVisible:
            previewText = nil
            // Image only: the preview does not need the packed frame the lens gets.
            previewIcon = renderer.renderImage(pendingCount: mirror.pendingCount)
            statusMessage = mirror.pendingCount == 1
                ? "1 unread. Tilt your head up to read it."
                : "\(mirror.pendingCount) unread. Tilt your head up to read the newest."
        case .suspended:
            previewIcon = nil
            previewText = nil
            statusMessage = isNavigationOwningDisplay
                ? "Paused while navigation uses the lens."
                : "Paused while the app is in the background."
        case .idle:
            previewIcon = nil
            previewText = nil
            if isConnected {
                statusMessage = "Waiting for a notification."
            }
        }
    }

    private func syncSurfaceClaim() {
        bluetoothManager?.setCustomDisplaySurfaceClaimed(isEnabled && mirror.ownsDisplay)
    }

    private func scheduleReadTimeout(for display: G1NotificationMirrorDisplay) {
        readTimeoutTask?.cancel()
        readTimeoutTask = nil

        guard case .text(let notification) = display else { return }
        readTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.readTimeoutSeconds))
            guard !Task.isCancelled else { return }
            // The state machine also checks the identifier, so a timer that
            // survives a race cannot dismiss a different message.
            self?.apply(.readTimeout(id: notification.id))
        }
    }

    private func enqueueDisplay(_ display: G1NotificationMirrorDisplay) {
        let previous = displayTask
        displayTask = Task { [weak self] in
            await previous?.value
            await self?.performDisplay(display)
        }
    }

    private func performDisplay(_ display: G1NotificationMirrorDisplay) async {
        // Deliberately not gated on `isEnabled`: turning the feature off produces a
        // clear, and skipping it would strand the envelope on the lens. Nothing can
        // be queued while disabled because `post` and `handleGlassesEvent` refuse.
        guard let bluetoothManager else { return }
        guard bluetoothManager.connectionState == .fullyConnected else { return }

        switch display {
        case .icon(let pendingCount):
            guard let frame = try? renderer.render(pendingCount: pendingCount).frame else {
                statusMessage = "Could not render the notification icon."
                return
            }
            _ = await bluetoothManager.sendBitmap(frame)
        case .text(let notification):
            // Awaited so a following clear cannot win the display gate first.
            _ = await bluetoothManager.sendTextAwaitingCompletion(
                G1TextSendRequest(text: notification.lensText, mode: .text)
            )
        case .clear:
            _ = await bluetoothManager.clearDisplayAwaitingCompletion()
        }
    }
}
