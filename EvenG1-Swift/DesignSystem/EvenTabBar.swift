import SwiftUI

struct EvenTabItem: Identifiable {
    let tag: Int
    let title: String
    let systemImage: String
    var id: Int { tag }
}

/// Custom bottom bar replacing the native pill. Three destinations, monospaced
/// UPPERCASE labels, and a single phosphor active state boxed on the current
/// item — matching the hardware's own instrument styling.
struct EvenTabBar: View {
    let items: [EvenTabItem]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items) { item in
                let isSelected = selection == item.tag
                Button {
                    selection = item.tag
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 20, weight: .regular))
                        Text(item.title)
                            .font(.evenMicro)
                            .tracking(1.1)
                            .textCase(.uppercase)
                    }
                    .foregroundStyle(isSelected ? Even.Palette.phosphor : Even.Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? Even.Palette.phosphorDim : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab.\(item.tag)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(
            Even.Palette.base
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Even.Palette.border)
                        .frame(height: 1)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }
}
