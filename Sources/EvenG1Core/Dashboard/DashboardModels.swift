import Foundation

/// How much of the dashboard is composed onto the 576x135 surface.
///
/// The three modes mirror the reference design: a rich layout, a two-zone
/// layout, and a stripped-back status-only layout.
public enum DashboardLayoutMode: String, CaseIterable, Codable, Sendable {
    /// Status column + calendar row + widget panel with a page indicator.
    case full
    /// Status column + widget panel.
    case dual
    /// Status only, rendered large.
    case minimal

    public var displayName: String {
        switch self {
        case .full: return "Full"
        case .dual: return "Dual"
        case .minimal: return "Minimal"
        }
    }
}

/// The single widget shown in the dashboard's widget panel. Only one is visible
/// at a time; the reference UI lets the user pick which.
public enum DashboardWidgetKind: String, CaseIterable, Codable, Sendable {
    case quickNote
    case stocks
    case news
    case map

    public var displayName: String {
        switch self {
        case .quickNote: return "QuickNote"
        case .stocks: return "Stocks"
        case .news: return "News"
        case .map: return "Map"
        }
    }

    /// Whether the widget can render entirely from on-device data today. Sources
    /// that require external APIs or entitlements are gated off by default until
    /// their provider is validated (see the plan's provider phase).
    public var isAvailableOffline: Bool {
        switch self {
        case .quickNote: return true
        case .stocks, .news, .map: return false
        }
    }
}

public enum DashboardTimeFormat: String, CaseIterable, Codable, Sendable {
    case twelveHour
    case twentyFourHour

    public var displayName: String {
        switch self {
        case .twelveHour: return "12-Hour Time"
        case .twentyFourHour: return "24-Hour Time"
        }
    }
}

public enum DashboardTemperatureUnit: String, CaseIterable, Codable, Sendable {
    case celsius
    case fahrenheit

    public var displayName: String {
        switch self {
        case .celsius: return "Celsius"
        case .fahrenheit: return "Fahrenheit"
        }
    }

    public var suffix: String {
        switch self {
        case .celsius: return "C"
        case .fahrenheit: return "F"
        }
    }
}

/// Persisted dashboard configuration. Codable so it can round-trip through
/// `UserDefaults` behind a versioned key, matching the store pattern used
/// elsewhere in the app.
public struct DashboardSettings: Codable, Sendable, Equatable {
    /// Whether the dashboard participates in head-up display at all.
    public var isEnabled: Bool
    public var layout: DashboardLayoutMode
    public var selectedWidget: DashboardWidgetKind
    public var timeFormat: DashboardTimeFormat
    public var temperatureUnit: DashboardTemperatureUnit

    /// Opt-in flags per sensitive source. Off by default so no data is read or
    /// projected onto the glasses until the user explicitly enables it.
    public var calendarEnabled: Bool
    public var remindersEnabled: Bool
    public var weatherEnabled: Bool

    /// When set, only counts/aggregates are rendered rather than titles/text.
    public var redactSensitiveContent: Bool

    /// User-authored QuickNote text. Rendered directly into the bitmap.
    public var quickNote: String

    /// Ticker symbols for the stocks widget (kept even while the provider is
    /// disabled so the user's choice is preserved).
    public var stockSymbols: [String]

    /// RSS feed URL for the news widget.
    public var newsFeedURL: String

    public init(
        isEnabled: Bool = false,
        layout: DashboardLayoutMode = .full,
        selectedWidget: DashboardWidgetKind = .quickNote,
        timeFormat: DashboardTimeFormat = .twentyFourHour,
        temperatureUnit: DashboardTemperatureUnit = .celsius,
        calendarEnabled: Bool = false,
        remindersEnabled: Bool = false,
        weatherEnabled: Bool = false,
        redactSensitiveContent: Bool = false,
        quickNote: String = "",
        stockSymbols: [String] = [],
        newsFeedURL: String = ""
    ) {
        self.isEnabled = isEnabled
        self.layout = layout
        self.selectedWidget = selectedWidget
        self.timeFormat = timeFormat
        self.temperatureUnit = temperatureUnit
        self.calendarEnabled = calendarEnabled
        self.remindersEnabled = remindersEnabled
        self.weatherEnabled = weatherEnabled
        self.redactSensitiveContent = redactSensitiveContent
        self.quickNote = quickNote
        self.stockSymbols = stockSymbols
        self.newsFeedURL = newsFeedURL
    }

    public static let `default` = DashboardSettings()

    // Tolerate older persisted payloads that predate newer fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DashboardSettings.default
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        layout = try container.decodeIfPresent(DashboardLayoutMode.self, forKey: .layout) ?? defaults.layout
        selectedWidget = try container.decodeIfPresent(DashboardWidgetKind.self, forKey: .selectedWidget) ?? defaults.selectedWidget
        timeFormat = try container.decodeIfPresent(DashboardTimeFormat.self, forKey: .timeFormat) ?? defaults.timeFormat
        temperatureUnit = try container.decodeIfPresent(DashboardTemperatureUnit.self, forKey: .temperatureUnit) ?? defaults.temperatureUnit
        calendarEnabled = try container.decodeIfPresent(Bool.self, forKey: .calendarEnabled) ?? defaults.calendarEnabled
        remindersEnabled = try container.decodeIfPresent(Bool.self, forKey: .remindersEnabled) ?? defaults.remindersEnabled
        weatherEnabled = try container.decodeIfPresent(Bool.self, forKey: .weatherEnabled) ?? defaults.weatherEnabled
        redactSensitiveContent = try container.decodeIfPresent(Bool.self, forKey: .redactSensitiveContent) ?? defaults.redactSensitiveContent
        quickNote = try container.decodeIfPresent(String.self, forKey: .quickNote) ?? defaults.quickNote
        stockSymbols = try container.decodeIfPresent([String].self, forKey: .stockSymbols) ?? defaults.stockSymbols
        newsFeedURL = try container.decodeIfPresent(String.self, forKey: .newsFeedURL) ?? defaults.newsFeedURL
    }
}

/// A single upcoming calendar entry, already reduced to what the HUD shows.
public struct DashboardCalendarEvent: Sendable, Equatable {
    public var title: String
    public var startTime: Date
    public var endTime: Date?

    public init(title: String, startTime: Date, endTime: Date? = nil) {
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// A temperature reading tagged with the unit it was captured in.
public struct DashboardTemperature: Sendable, Equatable {
    public var value: Double
    public var unit: DashboardTemperatureUnit

    public init(value: Double, unit: DashboardTemperatureUnit) {
        self.value = value
        self.unit = unit
    }
}

/// Widget-panel content, resolved to a small display-ready payload. Each case is
/// what the renderer draws for the currently selected widget.
public enum DashboardWidgetContent: Sendable, Equatable {
    case quickNote(String)
    case news(source: String, headline: String)
    case stocks([DashboardStockQuote])
    case map
    /// The widget is selected but its data source is unavailable/disabled.
    case unavailable(reason: String)
}

public struct DashboardStockQuote: Sendable, Equatable {
    public var symbol: String
    public var price: Double
    public var changePercent: Double

    public init(symbol: String, price: Double, changePercent: Double) {
        self.symbol = symbol
        self.price = price
        self.changePercent = changePercent
    }
}

/// An immutable, timestamped view of everything the dashboard can display.
///
/// The renderer only ever reads a snapshot; it never touches a live service.
/// Fields are optional so an unavailable provider degrades independently
/// instead of blocking the whole frame. `capturedAt` lets callers decide
/// whether a cached snapshot is too stale to reuse.
public struct DashboardSnapshot: Sendable, Equatable {
    public var capturedAt: Date
    public var referenceDate: Date
    public var reminderCount: Int?
    public var temperature: DashboardTemperature?
    public var nextEvent: DashboardCalendarEvent?
    public var widget: DashboardWidgetContent

    public init(
        capturedAt: Date = Date(),
        referenceDate: Date = Date(),
        reminderCount: Int? = nil,
        temperature: DashboardTemperature? = nil,
        nextEvent: DashboardCalendarEvent? = nil,
        widget: DashboardWidgetContent = .unavailable(reason: "No widget")
    ) {
        self.capturedAt = capturedAt
        self.referenceDate = referenceDate
        self.reminderCount = reminderCount
        self.temperature = temperature
        self.nextEvent = nextEvent
        self.widget = widget
    }
}
