import SwiftUI
import MapKit
import UIKit
import EvenG1Core

struct NavigateTab: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager
    @EnvironmentObject private var glassesEvents: G1GlassesEventNotifier
    @EnvironmentObject private var appActionRouter: AppActionRouter
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
        case .navigating, .rerouting, .arrived:
            return true
        case .idle, .searching, .routePreview, .error:
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
                    Even.Palette.base
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
            .background(Even.Palette.base)
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
            .onChange(of: appActionRouter.favoriteNavigationRevision) { _, _ in
                guard let name = appActionRouter.favoriteNavigationRequest else { return }
                Task { await viewModel.startNavigationToFavorite(named: name) }
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
                    .stroke(Even.Palette.phosphor.opacity(0.9), lineWidth: 6)
            }

            if let destination = viewModel.destinationCoordinate {
                Annotation("Destination", coordinate: destination) {
                    ZStack {
                        Circle()
                            .fill(Even.Palette.base.opacity(0.85))
                            .frame(width: 30, height: 30)
                            .overlay(Circle().stroke(Even.Palette.phosphor, lineWidth: 1.5))
                        Circle()
                            .fill(Even.Palette.phosphor)
                            .frame(width: 12, height: 12)
                    }
                    .shadow(color: Even.Palette.phosphor.opacity(0.5), radius: 6)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
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
                colors: [Even.Palette.base.opacity(0.65), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 200)
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
        .padding(.horizontal, Even.Space.margin)
        .padding(.top, 12)
    }

    private var idleHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Even Realities / Wayfinding").evenEyebrow()
            Text("Navigate")
                .font(.evenScreenTitle)
                .foregroundStyle(Even.Palette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tripHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isTripActive ? "Even Realities / Trip" : "Even Realities / Wayfinding").evenEyebrow()
                Text(isTripActive ? viewModel.destinationTitle : "Navigate")
                    .font(.system(.title2, design: .default).weight(.semibold))
                    .foregroundStyle(Even.Palette.textPrimary)
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.evenSubtitle)
                    .foregroundStyle(Even.Palette.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if isTripActive {
                Button {
                    isConfirmingStop = true
                } label: {
                    Text("End")
                        .font(.evenTileTitle)
                        .foregroundStyle(Even.Palette.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: Even.Radius.chip, style: .continuous)
                                .fill(Even.Palette.destructive.opacity(0.9))
                        )
                }
                .accessibilityIdentifier("navigation.endTripButton")
            }

            Button {
                isHUDPreviewVisible.toggle()
            } label: {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(isHUDPreviewVisible ? Even.Palette.phosphor : Even.Palette.textPrimary)
                    .frame(width: 40, height: 40)
                    .glassCircle()
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
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(viewModel.isFollowingUser ? Even.Palette.phosphor : Even.Palette.textPrimary)
                        .frame(width: 44, height: 44)
                        .glassCircle()
                }
                .accessibilityLabel("Center on my location")
                .accessibilityIdentifier("navigation.locateUserButton")

                Spacer()
            }
            .padding(.leading, Even.Space.margin)
            .padding(.bottom, Even.Space.margin)
        }
    }

    private var locationPermissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "location.slash.fill")
                .foregroundStyle(Even.Palette.caution)

            Text("Location access needed to center the map")
                .font(.evenSubtitle)
                .foregroundStyle(Even.Palette.textPrimary)
                .lineLimit(2)

            Spacer(minLength: 0)

            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                Link("Settings", destination: settingsURL)
                    .font(.evenTileTitle)
                    .foregroundStyle(Even.Palette.phosphor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassPanel(radius: 14)
        .padding(.horizontal, 10)
        .accessibilityIdentifier("navigation.locationPermissionBanner")
    }

    private var hudPreviewPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("On the lens").evenSectionHeader()
                if bluetoothManager.connectionState != .fullyConnected {
                    Text("· offline")
                        .font(.evenMicro)
                        .foregroundStyle(Even.Palette.caution)
                }
                Spacer()
                Text(viewModel.glassesDisplayDetailLabel)
                    .font(.evenMicro)
                    .foregroundStyle(Even.Palette.textSecondary)
                Text("·").foregroundStyle(Even.Palette.textTertiary)
                Text(viewModel.transportModeLabel)
                    .font(.evenMicro)
                    .foregroundStyle(Even.Palette.textSecondary)
            }

            if let image = viewModel.currentNavVisualImage {
                EvenLensDisplay {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                }
            } else {
                EvenLensDisplay {
                    Text(viewModel.hudInstructionText.isEmpty
                        ? "Pick a destination to preview guidance"
                        : viewModel.hudInstructionText)
                        .font(.evenHUD(15))
                        .foregroundStyle(viewModel.hudInstructionText.isEmpty
                            ? Even.Palette.phosphor.opacity(0.4)
                            : Even.Palette.phosphor)
                }
            }
        }
        .padding(12)
        .glassPanel(radius: Even.Radius.sheet)
        .accessibilityIdentifier("navigation.hudPreviewPanel")
    }

    private var searchField: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Even.Palette.textSecondary)

                TextField(
                    viewModel.showsNavigationControls ? "Search destination" : "Search",
                    text: $viewModel.searchQuery
                )
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .foregroundStyle(Even.Palette.textPrimary)
                .tint(Even.Palette.phosphor)
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
                            .foregroundStyle(Even.Palette.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .glassPanel(radius: 14)

            if viewModel.showsNavigationControls {
                modePicker
            }
        }
    }

    private var modePicker: some View {
        HStack(spacing: Even.Space.gap) {
            ForEach(G1NavigationMode.allCases, id: \.self) { mode in
                let isSelected = viewModel.selectedMode == mode
                Button {
                    viewModel.selectedMode = mode
                    if let destination = viewModel.destinationCoordinate {
                        let item = MKMapItem(placemark: MKPlacemark(coordinate: destination))
                        item.name = viewModel.destinationTitle
                        Task { await viewModel.previewRoute(to: item) }
                    }
                } label: {
                    Text(mode.displayName)
                        .font(.evenMicro)
                        .tracking(0.5)
                        .foregroundStyle(isSelected ? Even.Palette.base : Even.Palette.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: Even.Radius.chip, style: .continuous)
                                .fill(isSelected ? Even.Palette.phosphor : Color.white.opacity(0.1))
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
                                .font(.evenTileTitle)
                                .foregroundStyle(Even.Palette.textPrimary)
                                .lineLimit(1)
                            if !suggestion.displaySubtitle.isEmpty {
                                Text(suggestion.displaySubtitle)
                                    .font(.evenSubtitle)
                                    .foregroundStyle(Even.Palette.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    if suggestion.id != viewModel.suggestions.prefix(5).last?.id {
                        Divider().overlay(Even.Palette.border)
                    }
                }
            }
            .glassPanel(radius: 14)
        }
    }

    private var maneuverBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(viewModel.activeInstructionTitle)
                    .font(.system(.headline, design: .default))
                    .foregroundStyle(Even.Palette.textPrimary)
                    .lineLimit(2)

                Spacer()

                stateChip
            }

            Text(viewModel.activeInstructionSubtitle)
                .font(.evenSubtitle)
                .foregroundStyle(Even.Palette.textSecondary)
                .lineLimit(1)

            if isTripActive {
                ProgressView(value: viewModel.progressFraction)
                    .tint(Even.Palette.phosphor)
                    .background(Color.white.opacity(0.1))
            }
        }
        .padding(12)
        .glassPanel(radius: Even.Radius.sheet)
    }

    private var stateChip: some View {
        Text(stateLabel)
            .font(.evenMicro)
            .tracking(1)
            .textCase(.uppercase)
            .foregroundStyle(isTripActive ? Even.Palette.phosphor : Even.Palette.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Even.Radius.chip, style: .continuous)
                    .fill(Color.white.opacity(0.1))
            )
    }

    private var stateLabel: String {
        switch viewModel.state {
        case .idle: return "Idle"
        case .searching: return "Search"
        case .routePreview: return "Preview"
        case .navigating: return "Live"
        case .rerouting: return "Rerouting"
        case .arrived: return "Arrived"
        case .error: return "Error"
        }
    }

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Favorites").evenSectionHeader()

                Spacer()

                Button {
                    Task { await viewModel.addCustomFavorite() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Even.Palette.phosphor)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Even.Palette.phosphorDim))
                }
                .accessibilityLabel("Add favorite location")
                .accessibilityIdentifier("navigation.addFavoriteButton")

                primaryAction
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Even.Space.gap) {
                    ForEach(viewModel.favorites) { favorite in
                        favoriteCard(favorite)
                    }

                    addLocationCard
                }
                .padding(.bottom, 2)
            }
        }
        .padding(.horizontal, Even.Space.margin)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .glassPanel(radius: Even.Radius.sheet)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var primaryAction: some View {
        Group {
            switch viewModel.state {
            case .routePreview where viewModel.routePolyline != nil:
                EvenPrimaryButton(
                    title: viewModel.canStartTurnByTurn ? "Start" : "ETA Only",
                    systemImage: viewModel.canStartTurnByTurn ? "location.north.line" : "tram"
                ) {
                    Task { await viewModel.startNavigation() }
                }
                .frame(maxWidth: 140)
                .opacity(viewModel.canStartTurnByTurn ? 1 : 0.5)
                .disabled(!viewModel.canStartTurnByTurn)

            case .arrived:
                EvenPrimaryButton(title: "Done", systemImage: "checkmark") {
                    Task { await viewModel.stopNavigation() }
                }
                .frame(maxWidth: 120)

            case .navigating, .rerouting:
                EvenPrimaryButton(title: "End Trip", systemImage: "stop.circle", style: .secondary) {
                    isConfirmingStop = true
                }
                .frame(maxWidth: 140)

            case .idle, .searching, .routePreview, .error:
                EmptyView()
            }
        }
    }

    private func favoriteCard(_ favorite: NavigationFavorite) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: iconName(for: favorite.kind))
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Even.Palette.textPrimary)

                Spacer()

                if favorite.kind == .custom {
                    Button {
                        selectedFavoriteForRemoval = favorite
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(Even.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 12)

            Text(favorite.title)
                .font(.evenTileTitle)
                .tracking(-0.2)
                .foregroundStyle(Even.Palette.textPrimary)
                .lineLimit(1)

            Text(favorite.isConfigured ? favorite.subtitle : "Set Location")
                .font(.evenSubtitle)
                .foregroundStyle(Even.Palette.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 150, height: Even.tileMinHeight, alignment: .leading)
        .padding(Even.Space.tilePadding)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: Even.Radius.tile, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Even.Radius.tile, style: .continuous)
                .stroke(Even.Palette.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Even.Radius.tile, style: .continuous))
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
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Even.Palette.phosphor)
                Spacer(minLength: 12)
                Text("Add")
                    .font(.evenTileTitle)
                    .foregroundStyle(Even.Palette.textPrimary)
                Text("Location")
                    .font(.evenSubtitle)
                    .foregroundStyle(Even.Palette.textSecondary)
            }
            .frame(width: 120, height: Even.tileMinHeight, alignment: .leading)
            .padding(Even.Space.tilePadding)
            .background(Even.Palette.phosphorDim)
            .clipShape(RoundedRectangle(cornerRadius: Even.Radius.tile, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Even.Radius.tile, style: .continuous)
                    .stroke(Even.Palette.phosphor.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("navigation.addFavoriteCard")
    }

    private func iconName(for kind: NavigationFavoriteKind) -> String {
        switch kind {
        case .home: return "house"
        case .office: return "building.2"
        case .custom: return "mappin.and.ellipse"
        }
    }
}

// MARK: - Glass treatment

private extension View {
    /// Dark glass over the map: `ultraThinMaterial` with the spec's hairline
    /// white/10 stroke.
    func glassPanel(radius: CGFloat) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
            )
    }

    func glassCircle() -> some View {
        self
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 0.5))
    }
}
