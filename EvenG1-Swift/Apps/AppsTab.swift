import SwiftUI
import EvenG1Core

/// Catalog of things the glasses can show. Each entry is a self-contained widget
/// with its own configuration, so adding Weather or Calendar later means adding
/// a row here rather than another section on a shared scroll view.
struct AppsTab: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager
    @EnvironmentObject private var appActionRouter: AppActionRouter
    @ObservedObject var transitViewModel: MTATrainViewModel
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 16) {
                    if bluetoothManager.connectionState != .fullyConnected {
                        DisconnectedNotice()
                    }

                    NavigationLink {
                        TransitWidgetView(viewModel: transitViewModel)
                    } label: {
                        HUDAppCard(
                            title: "Transit",
                            subtitle: transitSubtitle,
                            icon: "tram.fill",
                            tint: .cyan
                        )
                    }
                    .accessibilityIdentifier("apps.transitLink")

                    NavigationLink {
                        NotificationsWidgetView()
                    } label: {
                        HUDAppCard(
                            title: "Notifications",
                            subtitle: "Push a message to the lens",
                            icon: "bell.badge.fill",
                            tint: .orange
                        )
                    }
                    .accessibilityIdentifier("apps.notificationsLink")

                    NavigationLink(value: HeadsUpDestination.translate) {
                        HUDAppCard(
                            title: "Translate",
                            subtitle: "Live translated captions from the glasses mic",
                            icon: "translate",
                            tint: .green
                        )
                    }
                    .accessibilityIdentifier("apps.translateLink")

                    NavigationLink {
                        NotesWidgetView()
                    } label: {
                        HUDAppCard(
                            title: "Notes & Prompts",
                            subtitle: "Keep a line of text in view",
                            icon: "text.alignleft",
                            tint: .purple
                        )
                    }
                    .accessibilityIdentifier("apps.notesLink")
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Heads-Up")
            .navigationBarTitleDisplayMode(.large)
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
            transitViewModel.bind(bluetoothManager: bluetoothManager)
        }
        .onChange(of: appActionRouter.translationStartRevision) { _, _ in
            path = NavigationPath()
            path.append(HeadsUpDestination.translate)
        }
    }

    private var transitSubtitle: String {
        if let station = transitViewModel.selectedStation {
            return station.stationName
        }
        return "Next trains at your station"
    }
}

private enum HeadsUpDestination: Hashable {
    case translate
}

private struct DisconnectedNotice: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "eyeglasses")
                .font(.title3)
                .foregroundStyle(.orange)

            Text("Glasses are not connected. Widgets still work in the app and will mirror to the lens once you connect.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("apps.disconnectedNotice")
    }
}

private struct HUDAppCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .background(tint.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}
