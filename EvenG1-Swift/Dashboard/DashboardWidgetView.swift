import EvenG1Core
import SwiftUI

/// Configuration surface for the default dashboard, mirroring the reference
/// design: layout mode, widget selection, per-source settings, and status
/// formatting, with a live HUD preview of the exact bitmap the glasses receive.
struct DashboardWidgetView: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject private var settingsStore: DashboardSettingsStore

    @State private var isSending = false
    @StateObject private var stationPickerViewModel = MTAStationPickerViewModel()
    @State private var isStationPickerPresented = false

    init(viewModel: DashboardViewModel) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _settingsStore = ObservedObject(wrappedValue: viewModel.settingsStore)
    }

    private var settings: Binding<DashboardSettings> {
        $settingsStore.settings
    }

    private var isDisconnected: Bool {
        bluetoothManager.connectionState != .fullyConnected
    }

    var body: some View {
        Form {
            previewSection
            enableSection
            layoutSection
            widgetSelectionSection
            widgetOrderSection
            widgetDisplaySection
            widgetSettingsSection
            statusSettingsSection
        }
        .navigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .onAppear {
            viewModel.bind(bluetoothManager: bluetoothManager)
            Task { await viewModel.refreshData() }
        }
        .sheet(isPresented: $isStationPickerPresented) {
            MTAStationPickerSheet(
                title: "Pin Transit Station",
                pickerViewModel: stationPickerViewModel,
                userCoordinate: nil,
                onSelect: { station in
                    viewModel.stationLockStore.setLock(station: station)
                    Task { await viewModel.refreshData() }
                }
            )
        }
    }

    // MARK: - Sections

    private var previewSection: some View {
        Section {
            DashboardHUDPreview(image: viewModel.previewImage)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

            Button {
                Task {
                    isSending = true
                    await viewModel.sendNow()
                    isSending = false
                }
            } label: {
                HStack {
                    Label("Send to glasses", systemImage: "paperplane")
                    if isSending || viewModel.isRefreshingData {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isDisconnected || isSending)
            .accessibilityIdentifier("dashboard.sendButton")

            Button {
                Task { await viewModel.refreshData() }
            } label: {
                Label("Refresh data", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isRefreshingData)
        } header: {
            Text("Preview")
        } footer: {
            if isDisconnected {
                Text("Connect glasses to send. The preview shows exactly what the lens will display.")
            } else {
                Text("Refresh pulls calendar, weather, news, and transit into the preview.")
            }
        }
    }

    private var enableSection: some View {
        Section {
            Toggle("Show on look up", isOn: settings.isEnabled)
                .accessibilityIdentifier("dashboard.enableToggle")
        } footer: {
            Text("When on, tilting your head up shows the dashboard while EvenG1 is running. It never overrides live navigation or an open widget.")
        }
    }

    private var layoutSection: some View {
        Section("Layout") {
            Picker("Layout", selection: settings.layout) {
                ForEach(DashboardLayoutMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("dashboard.layoutPicker")
        }
    }

    private var widgetSelectionSection: some View {
        Section {
            ForEach(DashboardWidgetKind.allCases, id: \.self) { kind in
                Toggle(kind.displayName, isOn: widgetEnabledBinding(for: kind))
                    .accessibilityIdentifier("dashboard.widget.\(kind.rawValue)")
            }
        } header: {
            Text("Widget Selection")
        } footer: {
            Text("Enable one or more widgets for the dashboard panel.")
        }
    }

    @ViewBuilder
    private var widgetOrderSection: some View {
        if settings.selectedWidgets.wrappedValue.count > 1 {
            Section {
                ForEach(settings.selectedWidgets.wrappedValue, id: \.self) { kind in
                    Text(kind.displayName)
                }
                .onMove(perform: moveWidget)
            } header: {
                Text("Widget Order")
            } footer: {
                Text("Drag to reorder. Order applies to swipe, rotate, and stacked layouts.")
            }
        }
    }

    private var widgetDisplaySection: some View {
        Section("Display Mode") {
            Picker("Mode", selection: settings.widgetDisplayMode) {
                ForEach(DashboardWidgetDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("dashboard.displayModePicker")

            if settings.widgetDisplayMode.wrappedValue == .autoRotate {
                Stepper(
                    "Rotate every \(settings.autoRotateSeconds.wrappedValue)s",
                    value: settings.autoRotateSeconds,
                    in: 3...60
                )
            }

            if settings.widgetDisplayMode.wrappedValue == .paged,
               settings.selectedWidgets.wrappedValue.count > 1 {
                Label("Swipe the stem to page between widgets on the glasses.", systemImage: "hand.draw")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var widgetSettingsSection: some View {
        Section("Widget Settings") {
            NavigationLink("Calendar") {
                CalendarSettingsView(settings: settings)
            }
            NavigationLink("QuickNote") {
                QuickNoteSettingsView(text: settings.quickNote)
            }
            NavigationLink("Stocks") {
                StocksSettingsView(symbols: settings.stockSymbols)
            }
            NavigationLink("News") {
                NewsSettingsView(feedURL: settings.newsFeedURL)
            }
            NavigationLink("Weather") {
                WeatherSettingsView(enabled: settings.weatherEnabled)
            }
            NavigationLink("Transit") {
                TransitDashboardSettingsView(
                    enabled: settings.transitEnabled,
                    horizonMinutes: settings.transitHorizonMinutes,
                    stationLockStore: viewModel.stationLockStore,
                    onPinStation: { isStationPickerPresented = true },
                    onUseNearest: {
                        viewModel.stationLockStore.clearLock()
                        Task { await viewModel.refreshData() }
                    }
                )
            }
        }
    }

    private var statusSettingsSection: some View {
        Section("Status Settings") {
            Picker("Time Format", selection: settings.timeFormat) {
                ForEach(DashboardTimeFormat.allCases, id: \.self) { format in
                    Text(format.displayName).tag(format)
                }
            }
            Picker("Temp Unit", selection: settings.temperatureUnit) {
                ForEach(DashboardTemperatureUnit.allCases, id: \.self) { unit in
                    Text(unit.displayName).tag(unit)
                }
            }
            Toggle("Redact sensitive content", isOn: settings.redactSensitiveContent)
        }
    }

    // MARK: - Widget selection helpers

    private func widgetEnabledBinding(for kind: DashboardWidgetKind) -> Binding<Bool> {
        Binding(
            get: { settingsStore.settings.selectedWidgets.contains(kind) },
            set: { enabled in
                var widgets = settingsStore.settings.selectedWidgets
                if enabled {
                    if !widgets.contains(kind) {
                        widgets.append(kind)
                    }
                } else {
                    widgets.removeAll { $0 == kind }
                }
                if widgets.isEmpty {
                    widgets = [.quickNote]
                }
                settingsStore.settings.selectedWidgets = widgets
            }
        )
    }

    private func moveWidget(from source: IndexSet, to destination: Int) {
        var widgets = settingsStore.settings.selectedWidgets
        widgets.move(fromOffsets: source, toOffset: destination)
        settingsStore.settings.selectedWidgets = widgets
    }
}

/// Black HUD frame that draws the rendered dashboard bitmap at the display's
/// aspect ratio, so the preview matches the transmitted frame pixel for pixel.
private struct DashboardHUDPreview: View {
    let image: UIImage?

    var body: some View {
        let aspect = CGFloat(G1BitmapFrame.defaultWidth) / CGFloat(G1BitmapFrame.defaultHeight)
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(aspect, contentMode: .fit)
            } else {
                Text("Nothing to preview")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.cyan.opacity(0.35), lineWidth: 1)
        )
        .padding(16)
    }
}

// MARK: - Detail settings screens

private struct CalendarSettingsView: View {
    @Binding var settings: DashboardSettings

    var body: some View {
        Form {
            Section {
                Toggle("Show next event", isOn: $settings.calendarEnabled)
                Toggle("Show reminders count", isOn: $settings.remindersEnabled)
            } footer: {
                Text("Requires Calendar and Reminders access. You'll be asked the first time the dashboard reads them.")
            }
        }
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct QuickNoteSettingsView: View {
    @Binding var text: String

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 120)
                    .accessibilityIdentifier("dashboard.quickNoteEditor")
            } header: {
                Text("QuickNote")
            } footer: {
                Text("Shown in the widget panel. Anything here is displayed on the glasses.")
            }
        }
        .navigationTitle("QuickNote")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StocksSettingsView: View {
    @Binding var symbols: [String]
    @State private var text: String = ""

    var body: some View {
        Form {
            Section {
                TextField("AAPL, MSFT, GOOG", text: $text)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onAppear { text = symbols.joined(separator: ", ") }
                    .onChange(of: text) { _, newValue in
                        symbols = newValue
                            .split(whereSeparator: { $0 == "," || $0 == " " })
                            .map { $0.uppercased() }
                            .filter { !$0.isEmpty }
                    }
            } header: {
                Text("Symbols")
            } footer: {
                Text("A validated quote provider is not enabled yet, so this widget shows a placeholder for now.")
            }
        }
        .navigationTitle("Stocks")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NewsSettingsView: View {
    @Binding var feedURL: String

    var body: some View {
        Form {
            Section {
                TextField("https://feeds.example.com/rss", text: $feedURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            } header: {
                Text("RSS Feed")
            } footer: {
                Text("Enter a public RSS or Atom feed URL. The top headline appears in the widget panel.")
            }
        }
        .navigationTitle("News")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WeatherSettingsView: View {
    @Binding var enabled: Bool

    var body: some View {
        Form {
            Section {
                Toggle("Show temperature", isOn: $enabled)
            } footer: {
                Text("Uses Apple Weather. Requires the WeatherKit entitlement and shows Apple's required attribution.")
            }
        }
        .navigationTitle("Weather")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TransitDashboardSettingsView: View {
    @Binding var enabled: Bool
    @Binding var horizonMinutes: Int
    @ObservedObject var stationLockStore: MTAManualStationLockStore
    let onPinStation: () -> Void
    let onUseNearest: () -> Void

    var body: some View {
        Form {
            Section {
                Toggle("Show nearest arrivals", isOn: $enabled)
                Stepper("Look ahead \(horizonMinutes) min", value: $horizonMinutes, in: 5...60, step: 5)
            } footer: {
                Text("Uses the NYC MTA subway realtime feed and your location to find nearby stations.")
            }

            Section("Station") {
                if let lockedStation = stationLockStore.lockedStation {
                    LabeledContent("Pinned", value: lockedStation.stationName)
                } else {
                    LabeledContent("Mode", value: "Nearest station")
                }

                Button {
                    onPinStation()
                } label: {
                    Label("Pin a station", systemImage: "pin")
                }

                Button {
                    onUseNearest()
                } label: {
                    Label("Use nearest", systemImage: "location")
                }
                .disabled(stationLockStore.lockedStation == nil)
            }
        }
        .navigationTitle("Transit")
        .navigationBarTitleDisplayMode(.inline)
    }
}
