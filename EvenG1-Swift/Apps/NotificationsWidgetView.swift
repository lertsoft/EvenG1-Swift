import SwiftUI
import EvenG1Core

/// Sends an app-authored notification to the lens.
///
/// iOS does not let an app read other apps' Notification Center content, so this
/// is the honest scope of the feature rather than a protocol test harness.
struct NotificationsWidgetView: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager

    @State private var title = "EvenG1 Swift"
    @State private var message = "This is a test notification."
    @State private var status = "Not sent"
    @State private var isSending = false
    @FocusState private var isFieldFocused: Bool

    private var isDisconnected: Bool {
        bluetoothManager.connectionState != .fullyConnected
    }

    private var canSend: Bool {
        !isDisconnected &&
        !isSending &&
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            if isDisconnected {
                Section {
                    Label("Connect glasses to send notifications", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("notifications.connectRequiredLabel")
                }
            }

            Section {
                GlassesHUDPreview(text: previewText, placeholder: "Write a notification to preview it")
            } header: {
                Text("Preview")
            }

            Section("Message") {
                TextField("Title", text: $title)
                    .focused($isFieldFocused)
                    .accessibilityIdentifier("notifications.titleField")

                TextField("Body", text: $message, axis: .vertical)
                    .lineLimit(2...4)
                    .focused($isFieldFocused)
                    .accessibilityIdentifier("notifications.messageField")
            }

            Section {
                Button {
                    Task { await send() }
                } label: {
                    if isSending {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Sending…")
                        }
                    } else {
                        Label("Send to glasses", systemImage: "bell.badge")
                    }
                }
                .accessibilityIdentifier("notifications.sendButton")
                .disabled(!canSend)

                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("notifications.status")
            } footer: {
                Text("The glasses must accept this app onto their notification list first. That happens automatically the first time you send.")
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isFieldFocused = false }
            }
        }
    }

    private var previewText: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return [trimmedTitle, trimmedMessage]
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }

    private func send() async {
        isSending = true
        defer { isSending = false }

        let appIdentifier = Bundle.main.bundleIdentifier ?? "com.eveng1.swift"
        let app = G1NotificationApp(identifier: appIdentifier, displayName: "EvenG1 Swift")
        status = "Preparing glasses…"

        guard await bluetoothManager.configureNotificationWhitelist(
            G1NotificationWhitelist(apps: [app])
        ) else {
            status = "The glasses did not accept this app. Try reconnecting."
            DatadogTelemetryService.shared.log(
                .warn,
                "Notification whitelist configuration failed",
                attributes: ["component": "notifications"]
            )
            DatadogTelemetryService.shared.trackProductEvent(
                name: "notification_delivery_failed",
                attributes: ["notification.stage": "whitelist"]
            )
            return
        }

        status = "Sending…"
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let notification = G1Notification(
            messageID: timestamp,
            appIdentifier: appIdentifier,
            title: title,
            message: message,
            timestampMilliseconds: timestamp,
            displayName: app.displayName
        )

        let sent = await bluetoothManager.sendNotification(notification)
        status = sent ? "Delivered to your glasses" : "The glasses did not confirm delivery."
        DatadogTelemetryService.shared.trackProductEvent(
            name: sent ? "notification_delivered" : "notification_delivery_failed",
            attributes: ["notification.stage": "delivery"]
        )
        if !sent {
            DatadogTelemetryService.shared.log(
                .warn,
                "Notification delivery was not acknowledged",
                attributes: ["component": "notifications"]
            )
        }
        if sent {
            isFieldFocused = false
        }
    }
}
