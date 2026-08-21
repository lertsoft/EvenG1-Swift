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
            widgetSettingsSection
            statusSettingsSection
        }
        .navigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.bind(bluetoothManager: bluetoothManager)
            viewModel.refreshSnapshot()
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
                    if isSending {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isDisconnected || isSending)
            .accessibilityIdentifier("dashboard.sendButton")
        } header: {
            Text("Preview")
        } footer: {
            if isDisconnected {
                Text("Connect glasses to send. The preview shows exactly what the lens will display.")
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
        Section("Widget Selection") {
            Picker("Widget", selection: settings.selectedWidget) {
                ForEach(DashboardWidgetKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("dashboard.widgetPicker")

            if !settings.selectedWidget.wrappedValue.isAvailableOffline {
                Label("This widget's data source is not connected yet.", systemImage: "exclamationmark.triangle")
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
                Text("News rendering is disabled until a feed's terms and attribution are validated.")
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
