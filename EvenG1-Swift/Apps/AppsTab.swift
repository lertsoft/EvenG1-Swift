import SwiftUI
import EvenG1Core

/// Catalog of things the glasses can show. A live lens preview sits up top as the
/// hero, with the modules below in a bento grid. Adding Weather or Calendar later
/// means adding one tile here rather than another list row.
struct AppsTab: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager
    @EnvironmentObject private var appActionRouter: AppActionRouter

    let transitSubtitle: String
    @ObservedObject var transitViewModel: MTATrainViewModel
    @ObservedObject var dashboardViewModel: DashboardViewModel
    @State private var path = NavigationPath()
    @State private var transitWidgetEnabled = true
    @State private var notificationsWidgetEnabled = true
    @State private var translateWidgetEnabled = true
    @State private var notesWidgetEnabled = true
    @State private var dashboardWidgetEnabled = true

    private var isLinked: Bool {
        bluetoothManager.connectionState == .fullyConnected
    }

    private var moduleCount: Int {
        [dashboardWidgetEnabled, transitWidgetEnabled, notificationsWidgetEnabled,
         translateWidgetEnabled, notesWidgetEnabled].filter { $0 }.count
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Even.Space.section) {
                    EvenScreenHeader(eyebrow: "Even Realities / G1", title: "Heads-Up") {
                        EvenStatusIndicator(isLive: isLinked)
                    }

                    EvenLensPreview(isLinked: isLinked) {
                        EvenLensDashboardContent(
                            isLinked: isLinked,
                            statusHeadline: isLinked ? "On the lens" : "Not linked",
                            statusDetail: isLinked
                                ? "Look up to wake the dashboard"
                                : "Connect on the Device tab"
                        )
                    }

                    if !isLinked {
                        EvenDisconnectedNotice()
                    }

                    VStack(alignment: .leading, spacing: Even.Space.gap + 2) {
                        EvenSectionHeader(title: "Lens Modules", trailing: "\(moduleCount) Available")

                        LazyVGrid(columns: EvenBento.columns, spacing: Even.Space.gap) {
                            if dashboardWidgetEnabled {
                                NavigationLink {
                                    DashboardWidgetView(viewModel: dashboardViewModel)
                                } label: {
                                    EvenBentoTile(title: "Dashboard", systemImage: "square.grid.2x2")
                                }
                                .buttonStyle(.evenPressable)
                                .accessibilityIdentifier("apps.dashboardLink")
                            }

                            if transitWidgetEnabled {
                                NavigationLink {
                                    TransitWidgetView(viewModel: transitViewModel)
                                } label: {
                                    EvenBentoTile(
                                        title: "Transit",
                                        systemImage: "tram",
                                        secondary: transitSubtitle
                                    )
                                }
                                .buttonStyle(.evenPressable)
                                .accessibilityIdentifier("apps.transitLink")
                            }

                            if notificationsWidgetEnabled {
                                NavigationLink {
                                    NotificationsWidgetView()
                                } label: {
                                    EvenBentoTile(title: "Notifications", systemImage: "bell")
                                }
                                .buttonStyle(.evenPressable)
                                .accessibilityIdentifier("apps.notificationsLink")
                            }

                            if translateWidgetEnabled {
                                NavigationLink(value: HeadsUpDestination.translate) {
                                    EvenBentoTile(title: "Translate", systemImage: "translate")
                                }
                                .buttonStyle(.evenPressable)
                                .accessibilityIdentifier("apps.translateLink")
                            }

                            if notesWidgetEnabled {
                                NavigationLink {
                                    NotesWidgetView()
                                } label: {
                                    EvenBentoTile(title: "Notes", systemImage: "text.alignleft")
                                }
                                .buttonStyle(.evenPressable)
                                .accessibilityIdentifier("apps.notesLink")
                            }
                        }
                    }
                }
                .padding(.horizontal, Even.Space.margin)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(Even.Palette.base.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: HeadsUpDestination.self) { destination in
                switch destination {
                case .translate:
                    if #available(iOS 18.0, *) {
                        TranslateWidgetView()
                    } else {
                        ContentUnavailableView(
                            "Translation Requires iOS 18",
                            systemImage: "translate",
                            description: Text("Update iOS to use Apple's on-device Translation framework.")
                        )
                    }
                }
            }
        }
        .onAppear {
            loadFeatureFlags()
            transitViewModel.bind(bluetoothManager: bluetoothManager)
        }
        .onChange(of: appActionRouter.translationStartRevision) { _, _ in
            path = NavigationPath()
            path.append(HeadsUpDestination.translate)
        }
        .onReceive(NotificationCenter.default.publisher(for: .evenG1FeatureFlagsDidBecomeReady)) { _ in
            loadFeatureFlags()
        }
    }

    private func loadFeatureFlags() {
        transitWidgetEnabled = FeatureFlagManager.shared.boolValue(
            forKey: EvenG1FeatureFlagKey.transitWidgetEnabled,
            defaultValue: true
        )
        notificationsWidgetEnabled = FeatureFlagManager.shared.boolValue(
            forKey: EvenG1FeatureFlagKey.notificationsWidgetEnabled,
            defaultValue: true
        )
        translateWidgetEnabled = FeatureFlagManager.shared.boolValue(
            forKey: EvenG1FeatureFlagKey.translateWidgetEnabled,
            defaultValue: true
        )
        notesWidgetEnabled = FeatureFlagManager.shared.boolValue(
            forKey: EvenG1FeatureFlagKey.notesWidgetEnabled,
            defaultValue: true
        )
        dashboardWidgetEnabled = FeatureFlagManager.shared.boolValue(
            forKey: EvenG1FeatureFlagKey.dashboardWidgetEnabled,
            defaultValue: true
        )
    }
}

private enum HeadsUpDestination: Hashable {
    case translate
}
