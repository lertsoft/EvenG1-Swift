import SwiftUI
import CoreLocation
import EvenG1Core

/// Next-train widget: arrivals for the nearest or pinned station, mirrored to the
/// glasses as a bitmap page that stem swipes can page through.
struct TransitWidgetView: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager
    @EnvironmentObject private var developerSettings: DeveloperSettings

    @ObservedObject var viewModel: MTATrainViewModel

    @StateObject private var stationPickerViewModel = MTAStationPickerViewModel()
    @State private var isStationPickerPresented = false
    @State private var isConfiguring = false

    private let bitmapRenderer = MTABitmapRenderer()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                stationHeader
                hudPreview
                arrivalsCard
                alertsCard
                controlsCard

                if developerSettings.isDeveloperModeEnabled {
                    developerFooter
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Transit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isConfiguring = true
                } label: {
                    Label("Configure", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("transit.configureButton")
            }
        }
        .onAppear {
            viewModel.bind(bluetoothManager: bluetoothManager)
            viewModel.setWidgetActive(true)
        }
        .onDisappear {
            viewModel.setWidgetActive(false)
        }
        .task {
            if viewModel.selectedStation == nil, !viewModel.isRefreshing {
                await viewModel.refreshNow(trigger: .manualButton)
            }
        }
        .sheet(isPresented: $isConfiguring) {
            TransitConfigurationSheet(
                viewModel: viewModel,
                stationPickerViewModel: stationPickerViewModel
            )
        }
        .sheet(isPresented: $isStationPickerPresented) {
            MTAStationPickerSheet(
                title: "Choose Station",
                pickerViewModel: stationPickerViewModel,
                userCoordinate: viewModel.currentUserCoordinate(),
                onSelect: { station in
                    viewModel.lockToStation(station)
                    Task { await viewModel.refreshNow(trigger: .manualButton) }
                }
            )
        }
    }

    // MARK: - Sections

    private var stationHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(viewModel.nearestStationName)
                .font(.title3.bold())
                .accessibilityIdentifier("mta.statusLabel")

            HStack(spacing: 8) {
                Label(
                    viewModel.lockedStation == nil ? "Nearest station" : "Pinned station",
                    systemImage: viewModel.lockedStation == nil ? "location.fill" : "pin.fill"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

                if let lastUpdatedAt = viewModel.lastUpdatedAt {
                    Text("· Updated \(lastUpdatedAt.formatted(.dateTime.hour().minute()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(viewModel.statusDetail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("mta.statusDetailLabel")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var hudPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassesHUDPreviewCard(title: "On your glasses") {
                if let page = viewModel.currentVisualPage {
                    Image(uiImage: bitmapRenderer.renderImage(page: page))
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.cyan.opacity(0.35), lineWidth: 1)
                        )
                        .accessibilityIdentifier("transit.hudPreview")
                } else {
                    GlassesHUDPreview(lines: [], placeholder: "Refresh to build a page")
                }
            }

            if viewModel.currentVisualPage != nil {
                Text("\(viewModel.visualPageIndexText) · swipe the stem to page, double-tap to refresh")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var arrivalsCard: some View {
        VStack(spacing: 0) {
            if viewModel.upcomingTrains.isEmpty {
                HStack {
                    if viewModel.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityIdentifier("mta.loadingIndicator")
                        Text("Checking arrivals…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No arrivals in the next 30 minutes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
            } else {
                ForEach(Array(viewModel.upcomingTrains.enumerated()), id: \.element.id) { index, train in
                    if index > 0 {
                        Divider().padding(.leading, 56)
                    }
                    ArrivalRow(train: train)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var alertsCard: some View {
        if let topAlertSummary = viewModel.topAlertSummary {
            VStack(alignment: .leading, spacing: 6) {
                Label(topAlertSummary, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("mta.alertSummaryLabel")

                if viewModel.additionalAlertCount > 0 {
                    Text("+\(viewModel.additionalAlertCount) more active alerts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("mta.alertCountLabel")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18))
        } else if viewModel.alertsUnavailable {
            Text("Service alerts are temporarily unavailable. Train arrival data is still live.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .accessibilityIdentifier("mta.alertUnavailableLabel")
        }
    }

    private var controlsCard: some View {
        VStack(spacing: 12) {
            Button {
                Task { await viewModel.refreshNow(trigger: .manualButton) }
            } label: {
                Label("Refresh arrivals", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("mta.refreshButton")
            .disabled(viewModel.isRefreshing)

            Toggle("Keep updating every 30s", isOn: autoRefreshBinding)
                .accessibilityIdentifier("mta.autoRefreshToggle")
                .disabled(viewModel.isRefreshing)

            Divider()

            Picker("Directions", selection: directionModeBinding) {
                ForEach(MTADirectionPreferenceMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.selectedStation == nil)
            .accessibilityIdentifier("transit.directionPicker")

            HStack(spacing: 10) {
                Button {
                    isStationPickerPresented = true
                } label: {
                    Label("Pin a station", systemImage: "pin")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("transit.pinStationButton")

                Button {
                    viewModel.clearManualLock()
                    Task { await viewModel.refreshNow(trigger: .manualButton) }
                } label: {
                    Label("Use nearest", systemImage: "location")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.lockedStation == nil)
                .accessibilityIdentifier("transit.useNearestButton")
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var developerFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Developer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(viewModel.visualPageIndexText) · \(viewModel.bitmapDeliveryStatus)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Text(viewModel.lockStatusText)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - Bindings

    private var autoRefreshBinding: Binding<Bool> {
        Binding(
            get: { viewModel.autoRefreshEnabled },
            set: { viewModel.setAutoRefreshEnabled($0) }
        )
    }

    private var directionModeBinding: Binding<MTADirectionPreferenceMode> {
        Binding(
            get: { viewModel.currentStationPreferenceMode },
            set: { mode in
                Task { await viewModel.setCurrentStationPreferenceMode(mode) }
            }
        )
    }
}

private struct ArrivalRow: View {
    let train: MTANextTrainResult

    var body: some View {
        HStack(spacing: 14) {
            Text(train.routeID)
                .font(.headline.monospaced())
                .foregroundStyle(.black)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.cyan))

            VStack(alignment: .leading, spacing: 2) {
                Text(mtaDirectionDualLabel(for: train.direction))
                    .font(.subheadline.weight(.medium))
                Text(train.arrivalTime.formatted(.dateTime.hour().minute()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(train.minutesAway <= 0 ? "Now" : "\(train.minutesAway) min")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Saved per-station direction preferences. Rarely touched, so it lives behind
/// the configure button instead of on the main widget.
private struct TransitConfigurationSheet: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var viewModel: MTATrainViewModel
    @ObservedObject var stationPickerViewModel: MTAStationPickerViewModel

    @State private var pendingMode: MTADirectionPreferenceMode = .both
    @State private var isStationPickerPresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Directions to save", selection: $pendingMode) {
                        ForEach(MTADirectionPreferenceMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Button {
                        isStationPickerPresented = true
                    } label: {
                        Label("Choose station", systemImage: "magnifyingglass")
                    }
                } header: {
                    Text("Add a station preference")
                } footer: {
                    Text("Pick which directions matter at a specific station. The widget uses the saved choice whenever you are there.")
                }

                if viewModel.savedDirectionPreferences.isEmpty {
                    Section {
                        Text("No saved stations yet.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Saved stations") {
                        ForEach(viewModel.savedDirectionPreferences) { preference in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preference.stationName)
                                Text(preference.mode.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { offsets in
                            for offset in offsets {
                                viewModel.removePreference(id: viewModel.savedDirectionPreferences[offset].id)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Transit Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $isStationPickerPresented) {
                MTAStationPickerSheet(
                    title: "Choose Station",
                    pickerViewModel: stationPickerViewModel,
                    userCoordinate: viewModel.currentUserCoordinate(),
                    onSelect: { station in
                        viewModel.setPreferenceMode(pendingMode, for: station)
                    }
                )
            }
        }
    }
}
