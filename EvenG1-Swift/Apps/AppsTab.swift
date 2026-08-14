import SwiftUI
import EvenG1Core

/// Catalog of things the glasses can show. Each entry is a self-contained widget
/// with its own configuration, so adding Weather or Calendar later means adding
/// a row here rather than another section on a shared scroll view.
struct AppsTab: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager
    @ObservedObject var transitViewModel: MTATrainViewModel

    var body: some View {
        NavigationStack {
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
        }
        .onAppear {
            transitViewModel.bind(bluetoothManager: bluetoothManager)
        }
    }

    private var transitSubtitle: String {
        if let station = transitViewModel.selectedStation {
            return station.stationName
        }
        return "Next trains at your station"
    }
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
