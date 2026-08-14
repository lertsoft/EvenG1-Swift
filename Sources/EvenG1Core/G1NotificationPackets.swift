import Foundation

/// An application entry accepted by the G1 notification whitelist command.
public struct G1NotificationApp: Equatable, Sendable {
    public var identifier: String
    public var displayName: String

    public init(identifier: String, displayName: String) {
        self.identifier = identifier
        self.displayName = displayName
    }
}

/// Vendor notification categories and applications to enable on the glasses.
public struct G1NotificationWhitelist: Equatable, Sendable {
    public var apps: [G1NotificationApp]
    public var appNotificationsEnabled: Bool
    public var calendarEnabled: Bool
    public var callsEnabled: Bool
    public var messagesEnabled: Bool
    public var iOSMailEnabled: Bool

    public init(
        apps: [G1NotificationApp],
        appNotificationsEnabled: Bool = true,
        calendarEnabled: Bool = false,
        callsEnabled: Bool = false,
        messagesEnabled: Bool = false,
        iOSMailEnabled: Bool = false
    ) {
        self.apps = apps
        self.appNotificationsEnabled = appNotificationsEnabled
        self.calendarEnabled = calendarEnabled
        self.callsEnabled = callsEnabled
        self.messagesEnabled = messagesEnabled
        self.iOSMailEnabled = iOSMailEnabled
    }
}

/// A notification encoded in the JSON shape used by the vendor demo.
public struct G1Notification: Equatable, Sendable {
    public var messageID: Int64
    public var appIdentifier: String
    public var title: String
    public var subtitle: String
    public var message: String
    public var timestampMilliseconds: Int64
    public var displayName: String

    public init(
        messageID: Int64,
        appIdentifier: String,
        title: String,
        subtitle: String = "",
        message: String,
        timestampMilliseconds: Int64,
        displayName: String
    ) {
        self.messageID = messageID
        self.appIdentifier = appIdentifier
        self.title = title
        self.subtitle = subtitle
        self.message = message
        self.timestampMilliseconds = timestampMilliseconds
        self.displayName = displayName
    }
}

public enum G1NotificationPacketError: Error, Equatable, Sendable {
    case payloadTooLarge(packetCount: Int)
}

/// Builds the official demo's `0x04` whitelist and `0x4B` notification packets.
public struct G1NotificationPacketBuilder: Sendable {
    public static let maximumPacketCount = Int(UInt8.max)
    public static let whitelistPayloadBytesPerPacket = 177
    public static let notificationPayloadBytesPerPacket = 176

    public init() {}

    public func buildWhitelistPackets(for whitelist: G1NotificationWhitelist) throws -> [Data] {
        let payload = WhitelistPayload(
            calendarEnabled: whitelist.calendarEnabled,
            callsEnabled: whitelist.callsEnabled,
            messagesEnabled: whitelist.messagesEnabled,
            iOSMailEnabled: whitelist.iOSMailEnabled,
            app: .init(
                list: whitelist.apps.map {
                    .init(identifier: $0.identifier, name: $0.displayName)
                },
                enabled: whitelist.appNotificationsEnabled
            )
        )

        return try packetize(
            command: G1Command.WHITELIST.rawValue,
            prefix: [],
            payload: try encode(payload),
            payloadBytesPerPacket: Self.whitelistPayloadBytesPerPacket
        )
    }

    public func buildNotificationPackets(
        for notification: G1Notification,
        transportID: UInt8
    ) throws -> [Data] {
        let payload = NotificationEnvelope(
            notification: .init(
                messageID: notification.messageID,
                appIdentifier: notification.appIdentifier,
                title: notification.title,
                subtitle: notification.subtitle,
                message: notification.message,
                timestampMilliseconds: notification.timestampMilliseconds,
                displayName: notification.displayName
            )
        )

        return try packetize(
            command: G1Command.NOTIFICATION.rawValue,
            prefix: [transportID],
            payload: try encode(payload),
            payloadBytesPerPacket: Self.notificationPayloadBytesPerPacket
        )
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func packetize(
        command: UInt8,
        prefix: [UInt8],
        payload: Data,
        payloadBytesPerPacket: Int
    ) throws -> [Data] {
        let packetCount = max(1, (payload.count + payloadBytesPerPacket - 1) / payloadBytesPerPacket)
        guard packetCount <= Self.maximumPacketCount else {
            throw G1NotificationPacketError.payloadTooLarge(packetCount: packetCount)
        }

        var packets: [Data] = []
        packets.reserveCapacity(packetCount)

        for packetIndex in 0..<packetCount {
            let start = packetIndex * payloadBytesPerPacket
            let end = min(start + payloadBytesPerPacket, payload.count)

            var packet = Data([command] + prefix + [UInt8(packetCount), UInt8(packetIndex)])
            if start < end {
                packet.append(payload[start..<end])
            }
            packets.append(packet)
        }

        return packets
    }
}

private extension G1NotificationPacketBuilder {
    struct WhitelistPayload: Encodable {
        let calendarEnabled: Bool
        let callsEnabled: Bool
        let messagesEnabled: Bool
        let iOSMailEnabled: Bool
        let app: AppConfiguration

        enum CodingKeys: String, CodingKey {
            case calendarEnabled = "calendar_enable"
            case callsEnabled = "call_enable"
            case messagesEnabled = "msg_enable"
            case iOSMailEnabled = "ios_mail_enable"
            case app
        }
    }

    struct AppConfiguration: Encodable {
        let list: [AppEntry]
        let enabled: Bool

        enum CodingKeys: String, CodingKey {
            case list
            case enabled = "enable"
        }
    }

    struct AppEntry: Encodable {
        let identifier: String
        let name: String

        enum CodingKeys: String, CodingKey {
            case identifier = "id"
            case name
        }
    }

    struct NotificationEnvelope: Encodable {
        let notification: NotificationPayload

        enum CodingKeys: String, CodingKey {
            case notification = "ncs_notification"
        }
    }

    struct NotificationPayload: Encodable {
        let messageID: Int64
        let appIdentifier: String
        let title: String
        let subtitle: String
        let message: String
        let timestampMilliseconds: Int64
        let displayName: String

        enum CodingKeys: String, CodingKey {
            case messageID = "msg_id"
            case appIdentifier = "app_identifier"
            case title
            case subtitle
            case message
            case timestampMilliseconds = "time_s"
            case displayName = "display_name"
        }
    }
}
