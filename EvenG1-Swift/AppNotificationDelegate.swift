import Foundation
import UserNotifications

/// Feeds notifications addressed to this app into the lens mirror.
///
/// Must be retained by the app: `UNUserNotificationCenter` holds its delegate
/// weakly, so a temporary object silently stops receiving callbacks.
///
/// Only two moments reach an app: delivery while it is in the foreground
/// (`willPresent`), and the user opening a notification (`didReceive`). A local
/// notification that arrives while the app is suspended is shown by iOS without
/// running app code, so it is not mirrored until one of those two happens.
final class AppNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    @MainActor private weak var viewModel: NotificationMirrorViewModel?

    @MainActor
    func register(viewModel: NotificationMirrorViewModel) {
        self.viewModel = viewModel
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await forward(notification)
        // The lens only shows an envelope, so the phone keeps presenting the
        // message itself.
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await forward(response.notification)
    }

    private func forward(_ notification: UNNotification) async {
        let request = notification.request
        let title = request.content.title
        let body = request.content.body
        // Reusing the request identifier means a notification that is delivered
        // in the foreground and then tapped is mirrored once, not twice.
        let id = request.identifier

        await MainActor.run {
            viewModel?.post(title: title, body: body, id: id)
        }
    }
}
