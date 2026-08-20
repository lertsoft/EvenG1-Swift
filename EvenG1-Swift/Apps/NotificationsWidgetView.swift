import SwiftUI
import EvenG1Core
import UserNotifications

/// Mirrors notifications onto the lens as an envelope, then reveals the message
/// when the wearer looks up.
///
/// iOS does not let an app read other apps' Notification Center content, so the
/// sources here are this app's own notifications: a direct hand-off for trying the
/// flow, and real local notifications delivered while the app is in front.
struct NotificationsWidgetView: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager
    @EnvironmentObject private var viewModel: NotificationMirrorViewModel

    @State private var title = "EvenG1 Swift"
    @State private var message = "This is a test notification."
    @State private var status = "Not sent"
    @State private var isSending = false
    @FocusState private var isFieldFocused: Bool

    private var isDisconnected: Bool {
        bluetoothManager.connectionState != .fullyConnected
    }

    private var hasMessageContent: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool {
        !isDisconnected && !isSending && hasMessageContent
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
                GlassesHUDPreviewCard(title: "On your glasses") {
                    lensPreview
                }
            } header: {
                Text("Preview")
            }

            mirrorSection
            messageSection
            simulationSection
            vendorSection
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isFieldFocused = false }
            }
        }
        .task {
            await viewModel.refreshAuthorizationStatus()
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var lensPreview: some View {
        if let previewText = viewModel.previewText {
            GlassesHUDPreview(text: previewText)
                .accessibilityIdentifier("notifications.lensTextPreview")
        } else if let icon = viewModel.previewIcon {
            Image(uiImage: icon)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.cyan.opacity(0.35), lineWidth: 1)
                )
                .accessibilityIdentifier("notifications.lensIconPreview")
        } else {
            GlassesHUDPreview(lines: [], placeholder: "Nothing on the lens")
        }
    }

    // MARK: - Mirror

    private var mirrorSection: some View {
        Section {
            Toggle("Mirror notifications to the lens", isOn: Binding(
                get: { viewModel.isEnabled },
                set: { viewModel.setEnabled($0) }
            ))
            .accessibilityIdentifier("notifications.mirrorToggle")

            Text(viewModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("notifications.mirrorStatus")

            if viewModel.pendingCount > 0 || viewModel.isReading {
                Button(role: .destructive) {
                    viewModel.dismissAll()
                } label: {
                    Label("Clear the lens", systemImage: "xmark.circle")
                }
                .accessibilityIdentifier("notifications.dismissButton")
            }
        } header: {
            Text("Tilt to read")
        } footer: {
            Text("An envelope appears on the lens when a notification arrives. Tilt your head up to acknowledge it and read the newest message; look back down to dismiss it.")
        }
    }

    private var messageSection: some View {
        Section("Message") {
            TextField("Title", text: $title)
                .focused($isFieldFocused)
                .accessibilityIdentifier("notifications.titleField")

            TextField("Body", text: $message, axis: .vertical)
                .lineLimit(2...4)
                .focused($isFieldFocused)
                .accessibilityIdentifier("notifications.messageField")
        }
    }

    // MARK: - Simulation sources

    private var simulationSection: some View {
        Section {
            Button {
                isFieldFocused = false
                viewModel.post(title: title, body: message)
            } label: {
                Label("Simulate incoming notification", systemImage: "bell.badge.waveform")
            }
            .accessibilityIdentifier("notifications.simulateButton")
            .disabled(!viewModel.isEnabled || !hasMessageContent)

            Button {
                isFieldFocused = false
                Task { await viewModel.scheduleLocalNotification(title: title, body: message) }
            } label: {
                Label("Schedule a real notification in 2s", systemImage: "clock.badge")
            }
            .accessibilityIdentifier("notifications.scheduleLocalButton")
            .disabled(!viewModel.isEnabled || !hasMessageContent || viewModel.authorizationStatus != .authorized)

            permissionRow
        } header: {
            Text("Try it")
        } footer: {
            Text("Simulating hands the message straight to the mirror. Scheduling posts a real notification, which reaches the lens when it is delivered with the app in front, or when you open it.")
        }
    }

    @ViewBuilder
    private var permissionRow: some View {
        switch viewModel.authorizationStatus {
        case .notDetermined:
            Button {
                Task { await viewModel.requestAuthorization() }
            } label: {
                Label("Allow notifications", systemImage: "bell")
            }
            .accessibilityIdentifier("notifications.requestPermissionButton")
        case .denied:
            VStack(alignment: .leading, spacing: 4) {
                Label("Notifications are turned off", systemImage: "bell.slash")
                    .foregroundStyle(.orange)
                Text("Simulating still works. Enable notifications in Settings to test real delivery.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("notifications.permissionStatus")
        default:
            Label("Notifications allowed", systemImage: "bell.badge")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("notifications.permissionStatus")
        }
    }

    // MARK: - Vendor protocol

    private var vendorSection: some View {
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
                    Label("Send as a vendor notification", systemImage: "bell.badge")
                }
            }
            .accessibilityIdentifier("notifications.sendButton")
            .disabled(!canSend)

            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("notifications.status")
        } header: {
            Text("Vendor protocol")
        } footer: {
            Text("A separate path that hands the message to the glasses' own notification feature instead of the tilt-to-read flow. The glasses must accept this app onto their notification list first, which happens automatically the first time you send.")
        }
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
