import SwiftUI
import MapKit
import UIKit
import EvenG1Core

struct NavigateTab: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager
    @EnvironmentObject private var glassesEvents: G1GlassesEventNotifier
    @Environment(\.scenePhase) private var scenePhase

    let isActive: Bool

    @StateObject private var viewModel = NavigationViewModel()
    @State private var selectedFavoriteForRemoval: NavigationFavorite?
    @State private var isConfirmingStop = false
    @State private var isHUDPreviewVisible = false
    @State private var hasReportedMapReady = false
    @State private var showFavoriteActionAlert = false

    private var isTripActive: Bool {
        switch viewModel.state {
        case .navigating, .rerouting:
            return true
        case .idle, .searching, .routePreview, .arrived, .error:
            return false
        }
    }

    private var removeFavoriteAlertPresented: Binding<Bool> {
        Binding(
            get: { selectedFavoriteForRemoval != nil },
            set: { isPresented in
                if !isPresented {
                    selectedFavoriteForRemoval = nil
                }
            }
        )
    }

    private var stopConfirmationTitle: String {
        let destination = viewModel.destinationTitle.isEmpty
            ? "this destination"
            : viewModel.destinationTitle
        return "End navigation to \(destination)?"
    }

    var body: some View {
        navigationContent
            .onAppear {
                viewModel.setAppActive(scenePhase == .active)
            }
            .onChange(of: scenePhase) { _, newValue in
                viewModel.setAppActive(newValue == .active)
            }
    }

    private var navigationContent: some View {
        NavigationStack {
            ZStack {
                if isActive {
                    mapLayer
                        .ignoresSafeArea()
                } else {
                    Color.black
                        .ignoresSafeArea()
                }

                VStack(spacing: 0) {
                    topOverlay
                    Spacer()
                }

                locateButtonOverlay
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 10) {
                    if viewModel.needsLocationPermission {
                        locationPermissionBanner
                    }
                    bottomPanel
                }
            }
            .background(Color.black)
            .navigationBarHidden(true)
            .confirmationDialog(
                stopConfirmationTitle,
                isPresented: $isConfirmingStop,
                titleVisibility: .visible
            ) {
                Button("End Navigation", role: .destructive) {
                    Task { await viewModel.stopNavigation() }
                }
                Button("Keep Going", role: .cancel) {}
            }
            .onAppear {
                viewModel.bind(bluetoothManager: bluetoothManager)
                viewModel.setNavigateTabActive(isActive)
            }
            .onChange(of: isActive) { _, newValue in
                viewModel.setNavigateTabActive(newValue)
                if newValue {
                    hasReportedMapReady = false
                }
            }
            .onChange(of: glassesEvents.revision) { _, _ in
                guard let latest = glassesEvents.latestEvent else {
                    return
                }
                Task {
                    await viewModel.handleGlassesEvent(latest)
                }
            }
            .onChange(of: viewModel.favoriteActionMessage) { _, message in
                showFavoriteActionAlert = message != nil
            }
            .alert("Favorites", isPresented: $showFavoriteActionAlert) {
                Button("OK") {
                    viewModel.clearFavoriteActionMessage()
                }
            } message: {
                Text(viewModel.favoriteActionMessage ?? "")
            }
            .alert("Remove Favorite", isPresented: removeFavoriteAlertPresented) {
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
        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
        .colorScheme(.dark)
        .onMapCameraChange(frequency: .onEnd) { _ in
            viewModel.userDidMoveMap()
        }
        .onAppear {
            guard !hasReportedMapReady else { return }
            hasReportedMapReady = true
            DatadogTelemetryService.shared.trackTiming(name: "map_ready")
        }
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

    private var topOverlay: some View {
        VStack(spacing: 12) {
            if viewModel.showsNavigationControls {
                tripHeader
            } else {
                idleHeader
            }

            searchField
            suggestionsPanel

            if viewModel.showsNavigationControls {
                if viewModel.isOverlayVisible {
                    maneuverBanner
                }
                if isHUDPreviewVisible {
                    hudPreviewPanel
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var idleHeader: some View {
        Text("Navigate")
            .font(.title2.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
    }

    private var tripHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isTripActive ? viewModel.destinationTitle : "Navigate")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isTripActive {
                Button {
                    isConfirmingStop = true
                } label: {
                    Text("End")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.red.opacity(0.85)))
                }
                .accessibilityIdentifier("navigation.endTripButton")
            }

            Button {
                isHUDPreviewVisible.toggle()
            } label: {
                Label("Glasses preview", systemImage: "eyeglasses")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(isHUDPreviewVisible ? Color.cyan : .white.opacity(0.85))
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityIdentifier("navigation.hudPreviewButton")
        }
    }

    private var headerSubtitle: String {
        switch viewModel.state {
        case .idle:
            return "Search or pick a favorite"
        case .searching:
            return "Searching…"
        case .routePreview:
            return viewModel.activeInstructionSubtitle
        case .navigating:
            return "Guidance on your glasses"
        case .rerouting:
            return "Finding a new route…"
        case .arrived:
            return "You have arrived"
        case .error(let message):
            return message
        }
    }

    private var locateButtonOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Button {
                    Task { await viewModel.centerOnUser() }
                } label: {
                    Image(systemName: "location.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(viewModel.isFollowingUser ? Color.cyan : .white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                }
                .accessibilityLabel("Center on my location")
                .accessibilityIdentifier("navigation.locateUserButton")

                Spacer()
            }
            .padding(.leading, 16)
            .padding(.bottom, 16)
        }
    }

    private var locationPermissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "location.slash.fill")
                .foregroundStyle(.orange)

            Text("Location access needed to center the map")
                .font(.footnote)
                .foregroundStyle(.white)
                .lineLimit(2)

            Spacer(minLength: 0)

            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                Link("Settings", destination: settingsURL)
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                )
        )
        .padding(.horizontal, 10)
        .accessibilityIdentifier("navigation.locationPermissionBanner")
    }

    private var hudPreviewPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("On your glasses")
                if bluetoothManager.connectionState != .fullyConnected {
                    Text("· not connected")
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(viewModel.glassesDisplayDetailLabel)
                Text("·")
                Text(viewModel.transportModeLabel)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let image = viewModel.currentNavVisualImage {
                GlassesHUDFrame {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                }
            } else {
                GlassesHUDPreview(
                    text: viewModel.hudInstructionText,
                    placeholder: "Pick a destination to preview guidance"
                )
            }
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
        .accessibilityIdentifier("navigation.hudPreviewPanel")
    }

    private var searchField: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField(
                    viewModel.showsNavigationControls ? "Search destination" : "Search",
                    text: $viewModel.searchQuery
                )
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .foregroundStyle(.white)
                .submitLabel(.search)
                .onSubmit {
                    Task { await viewModel.submitSearchQuery() }
                }
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

            if viewModel.showsNavigationControls {
                modePicker
            }
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

            if isTripActive {
                ProgressView(value: viewModel.progressFraction)
                    .tint(.green)
                    .background(.white.opacity(0.1))
            }
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

                Button {
                    Task { await viewModel.addCustomFavorite() }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.cyan)
                }
                .accessibilityLabel("Add favorite location")
                .accessibilityIdentifier("navigation.addFavoriteButton")

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
        .padding(.bottom, 10)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.black.opacity(0.64))
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var primaryAction: some View {
        Group {
            switch viewModel.state {
            case .routePreview where viewModel.routePolyline != nil, .arrived:
                Button {
                    Task { await viewModel.startNavigation() }
                } label: {
                    Label("Start", systemImage: "arrow.triangle.turn.up.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)

            case .navigating, .rerouting:
                Button {
                    isConfirmingStop = true
                } label: {
                    Label("End trip", systemImage: "stop.circle")
                }
                .buttonStyle(.bordered)

            case .idle, .searching, .routePreview, .error:
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
                    await viewModel.saveFavorite(kind: favorite.kind)
                }
            }
        }
    }

    private var addLocationCard: some View {
        Button {
            Task { await viewModel.addCustomFavorite() }
        } label: {
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
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("navigation.addFavoriteCard")
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
