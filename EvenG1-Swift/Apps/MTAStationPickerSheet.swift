import SwiftUI
import CoreLocation
import EvenG1Core

/// Searchable station list, sorted with the closest stations first and recent
/// picks pinned to the top.
struct MTAStationPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    @ObservedObject var pickerViewModel: MTAStationPickerViewModel
    let userCoordinate: CLLocationCoordinate2D?
    let onSelect: (MTAStationSelection) -> Void

    var body: some View {
        NavigationStack {
            List {
                if pickerViewModel.isLoading {
                    ProgressView("Loading stations...")
                }

                if let errorMessage = pickerViewModel.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.orange)
                }

                if !pickerViewModel.recentStations.isEmpty {
                    Section("Recent") {
                        ForEach(filteredRecentStations) { station in
                            stationButton(station)
                        }
                    }
                }

                Section("Stations") {
                    ForEach(pickerViewModel.filteredStations) { station in
                        stationButton(station)
                    }
                }
            }
            .searchable(text: $pickerViewModel.query)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task(id: userCoordinate?.latitude ?? 0) {
                await pickerViewModel.reloadStations(userCoordinate: userCoordinate)
            }
        }
    }

    private var filteredRecentStations: [MTAStationSelection] {
        let query = pickerViewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return pickerViewModel.recentStations
        }

        return pickerViewModel.recentStations.filter { station in
            station.stationName.lowercased().contains(query) ||
            station.stationID.lowercased().contains(query)
        }
    }

    private func stationButton(_ station: MTAStationSelection) -> some View {
        Button {
            pickerViewModel.markRecent(station)
            onSelect(station)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(station.stationName)
                    .font(.body)
                Text(stationDetailText(station))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func stationDetailText(_ station: MTAStationSelection) -> String {
        if let distance = station.distanceMeters {
            return "\(Int(distance))m away"
        }
        return station.stationID
    }
}
