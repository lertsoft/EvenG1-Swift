import SwiftUI
import MapKit
import EvenG1Core
import UniformTypeIdentifiers

struct NavigateTab: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager

    let isActive: Bool

    @StateObject private var viewModel = NavigationViewModel()
    @State private var selectedFavoriteForRemoval: NavigationFavorite?
    @State private var isDiagnosticsPresented = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                mapLayer

                VStack(spacing: 12) {
                    header
                    searchField
                    suggestionsPanel
                    if viewModel.isOverlayVisible {
                        maneuverBanner
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                VStack {
                    Spacer()
                    bottomPanel
                }
            }
            .background(Color.black)
            .ignoresSafeArea(edges: .bottom)
            .navigationBarHidden(true)
            .sheet(isPresented: $isDiagnosticsPresented) {
                NavigationDiagnosticsView()
                    .environmentObject(bluetoothManager)
            }
            .onAppear {
                viewModel.bind(bluetoothManager: bluetoothManager)
                viewModel.setNavigateTabActive(isActive)
            }
            .onChange(of: isActive) { _, newValue in
                viewModel.setNavigateTabActive(newValue)
            }
            .onChange(of: bluetoothManager.eventRevision) { _, _ in
                guard let latest = bluetoothManager.events.first else {
                    return
                }
                Task {
                    await viewModel.handleGlassesEvent(latest)
                }
            }
            .alert("Remove Favorite", isPresented: Binding(
                get: { selectedFavoriteForRemoval != nil },
                set: { if !$0 { selectedFavoriteForRemoval = nil } }
            )) {
                Button("Remove", role: .destructive) {
                    if let favorite = selectedFavoriteForRemoval {
                        viewModel.removeFavorite(id: favorite.id)
                    }
                    selectedFavoriteForRemoval = nil
                }
                Button("Cancel", role: .cancel) {
                    selectedFavoriteForRemoval = nil
                }
            } message: {
                Text("Delete this custom location from favorites?")
            }
        }
    }

    private var mapLayer: some View {
        Map(position: $viewModel.cameraPosition) {
            UserAnnotation()

            if let route = viewModel.routePolyline {
                MapPolyline(route)
                    .stroke(.cyan.opacity(0.85), lineWidth: 6)
            }

            if let destination = viewModel.destinationCoordinate {
                Annotation("Destination", coordinate: destination) {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.75))
                            .frame(width: 34, height: 34)
                        Image(systemName: "mappin.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.cyan)
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic, emphasis: .muted))
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 180)
            .allowsHitTesting(false)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Navigate")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                Text(viewModel.transportModeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                isDiagnosticsPresented = true
            } label: {
                Label("Diagnostics", systemImage: "waveform.path.ecg")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityIdentifier("navigationDiagnosticsButton")

            Button {
                Task { await viewModel.stopNavigation() }
            } label: {
                Label("Stop", systemImage: "xmark.circle")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
    }

    private var searchField: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search destination", text: $viewModel.searchQuery)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .foregroundStyle(.white)
                    .onChange(of: viewModel.searchQuery) { _, newValue in
                        viewModel.updateSearchQuery(newValue)
                    }

                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.searchQuery = ""
                        viewModel.updateSearchQuery("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.45))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )

            modePicker
        }
    }

    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(G1NavigationMode.allCases, id: \.self) { mode in
                Button {
                    viewModel.selectedMode = mode
                    if let destination = viewModel.destinationCoordinate {
                        let item = MKMapItem(placemark: MKPlacemark(coordinate: destination))
                        item.name = viewModel.destinationTitle
                        Task { await viewModel.previewRoute(to: item) }
                    }
                } label: {
                    Text(mode.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(viewModel.selectedMode == mode ? Color.black : Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(viewModel.selectedMode == mode ? Color.cyan : Color.white.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var suggestionsPanel: some View {
        if !viewModel.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.suggestions.prefix(5).enumerated()), id: \.offset) { _, suggestion in
                    Button {
                        Task {
                            await viewModel.selectSuggestion(suggestion)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if !suggestion.displaySubtitle.isEmpty {
                                Text(suggestion.displaySubtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    if suggestion.id != viewModel.suggestions.prefix(5).last?.id {
                        Divider().background(Color.white.opacity(0.12))
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.62))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private var maneuverBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(viewModel.activeInstructionTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Spacer()

                stateChip
            }

            Text(viewModel.activeInstructionSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            ProgressView(value: viewModel.progressFraction)
                .tint(.green)
                .background(.white.opacity(0.1))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.62))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    private var stateChip: some View {
        Text(stateLabel)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.12)))
    }

    private var stateLabel: String {
        switch viewModel.state {
        case .idle:
            return "Idle"
        case .searching:
            return "Search"
        case .routePreview:
            return "Preview"
        case .navigating:
            return "Live"
        case .rerouting:
            return "Rerouting"
        case .arrived:
            return "Arrived"
        case .error(_):
            return "Error"
        }
    }

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Favorite")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                Spacer()

                primaryAction
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(viewModel.favorites) { favorite in
                        favoriteCard(favorite)
                    }

                    addLocationCard
                }
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 22)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.black.opacity(0.64))
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
        .padding(.horizontal, 10)
    }

    private var primaryAction: some View {
        Group {
            switch viewModel.state {
            case .routePreview, .arrived:
                Button {
                    Task { await viewModel.startNavigation() }
                } label: {
                    Label("Start", systemImage: "arrow.triangle.turn.up.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)

            case .navigating, .rerouting:
                Button {
                    Task { await viewModel.stopNavigation() }
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .buttonStyle(.bordered)

            case .idle, .searching, .error:
                EmptyView()
            }
        }
    }

    private func favoriteCard(_ favorite: NavigationFavorite) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: iconName(for: favorite.kind))
                    .font(.title2)
                    .foregroundStyle(.white)

                Spacer()

                if favorite.kind == .custom {
                    Button {
                        selectedFavoriteForRemoval = favorite
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(favorite.title)
                .font(.title3.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text(favorite.isConfigured ? favorite.subtitle : "Set Location")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(width: 150, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.07))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            Task {
                if favorite.isConfigured {
                    await viewModel.previewFavorite(favorite)
                } else if favorite.kind == .home || favorite.kind == .office {
                    viewModel.setFavorite(kind: favorite.kind)
                }
            }
        }
    }

    private var addLocationCard: some View {
        VStack(alignment: .center, spacing: 10) {
            Image(systemName: "plus")
                .font(.largeTitle.weight(.light))
                .foregroundStyle(.white)

            Text("Add")
                .font(.title3.weight(.medium))
                .foregroundStyle(.white)

            Text("Location")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(width: 120)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.07))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            viewModel.addCurrentAsCustomFavorite()
        }
    }

    private func iconName(for kind: NavigationFavoriteKind) -> String {
        switch kind {
        case .home:
            return "house"
        case .office:
            return "building.2"
        case .custom:
            return "mappin.and.ellipse"
        }
    }
}

private struct NavigationTraceDocument: FileDocument {
    // JSON Lines has no system UTType. Generic data preserves the explicit
    // `.jsonl` filename instead of allowing a `.txt` suffix to be appended.
    static var readableContentTypes: [UTType] { [.data] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private struct NavigationDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager

    @State private var exportDocument = NavigationTraceDocument(text: "")
    @State private var isExporting = false
    @State private var isConfirmingClear = false
    @State private var exportStatus: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Session") {
                    LabeledContent("Connection", value: bluetoothManager.connectionState.displayString)
                    LabeledContent("State", value: bluetoothManager.navigationSessionState.rawValue.capitalized)
                    LabeledContent("Transport", value: bluetoothManager.navigationTransportMode.displayName)
                    LabeledContent("Trace entries", value: "\(bluetoothManager.navigationTraceEntries.count)")
                }

                Section {
                    Button {
                        exportDocument = NavigationTraceDocument(
                            text: bluetoothManager.exportNavigationTraceJSONL()
                        )
                        exportStatus = nil
                        isExporting = true
                    } label: {
                        Label("Export chronological JSONL", systemImage: "square.and.arrow.up")
                    }
                    .disabled(bluetoothManager.navigationTraceEntries.isEmpty)
                    .accessibilityIdentifier("exportNavigationTraceButton")

                    Button(role: .destructive) {
                        isConfirmingClear = true
                    } label: {
                        Label("Clear trace", systemImage: "trash")
                    }
                    .disabled(bluetoothManager.navigationTraceEntries.isEmpty)

                    if let exportStatus {
                        Text(exportStatus)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Evidence")
                } footer: {
                    Text("Exports oldest-to-newest records with ISO 8601 timestamps. Attach the file to the hardware validation matrix with the glasses firmware version.")
                }

                Section("Recent records") {
                    if bluetoothManager.navigationTraceEntries.isEmpty {
                        Text("Start navigation to collect native and fallback transport evidence.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(bluetoothManager.navigationTraceEntries.prefix(20)) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(entry.direction.rawValue.uppercased())
                                        .font(.caption.weight(.semibold))
                                    Text(String(format: "0x%02X", entry.command))
                                        .font(.caption.monospaced())
                                    Spacer()
                                    Text(entry.transportMode.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let note = entry.note, !note.isEmpty {
                                    Text(note)
                                        .font(.footnote)
                                }
                                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Navigation Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Clear all navigation trace entries?",
                isPresented: $isConfirmingClear,
                titleVisibility: .visible
            ) {
                Button("Clear Trace", role: .destructive) {
                    bluetoothManager.clearNavigationTrace()
                    exportStatus = nil
                }
                Button("Cancel", role: .cancel) {}
            }
            .fileExporter(
                isPresented: $isExporting,
                document: exportDocument,
                contentType: .data,
                defaultFilename: "EvenG1-navigation-trace-\(Int(Date().timeIntervalSince1970)).jsonl"
            ) { result in
                switch result {
                case .success:
                    exportStatus = "Trace exported"
                case .failure(let error):
                    exportStatus = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
