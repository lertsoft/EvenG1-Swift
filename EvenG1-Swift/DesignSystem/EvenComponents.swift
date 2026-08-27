import SwiftUI

// MARK: - Screen scaffold

/// Every screen opens the same way: a monospaced instrument eyebrow over a large
/// Title-Case name, with an optional live status on the right. This is the one
/// place UPPERCASE is allowed — it reads as an instrument label, not shouting.
struct EvenScreenHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    @ViewBuilder var trailing: Trailing

    init(eyebrow: String, title: String, @ViewBuilder trailing: () -> Trailing) {
        self.eyebrow = eyebrow
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow).evenEyebrow()
                Text(title)
                    .font(.evenScreenTitle)
                    .foregroundStyle(Even.Palette.textPrimary)
            }
            Spacer(minLength: 12)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension EvenScreenHeader where Trailing == EmptyView {
    init(eyebrow: String, title: String) {
        self.init(eyebrow: eyebrow, title: title) { EmptyView() }
    }
}

/// A short group label (`LENS MODULES`, `DEVICE CONTROL`) sitting above a bento
/// group.
struct EvenSectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title).evenSectionHeader()
            Spacer()
            if let trailing {
                Text(trailing).evenSectionHeader()
                    .foregroundStyle(Even.Palette.phosphor)
            }
        }
    }
}

/// Phosphor dot + monospaced state word. The only element besides the lens that
/// is allowed to glow green.
struct EvenStatusIndicator: View {
    let isLive: Bool
    var liveLabel: String = "Linked"
    var idleLabel: String = "Offline"
    var isPending: Bool = false

    private var dotColor: Color {
        if isPending { return Even.Palette.caution }
        return isLive ? Even.Palette.phosphor : Even.Palette.textTertiary
    }

    private var textColor: Color {
        if isPending { return Even.Palette.caution }
        return isLive ? Even.Palette.phosphor : Even.Palette.textSecondary
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .shadow(color: isLive ? Even.Palette.phosphor.opacity(0.7) : .clear, radius: 4)
            Text(isPending ? "Linking" : (isLive ? liveLabel : idleLabel))
                .font(.evenMicro)
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(textColor)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Bento tile

/// The atom of the whole interface: a 20pt stroke icon top-left, a Title-Case
/// label bottom-left, and an optional single live line. No arrows, no textures.
struct EvenBentoTile: View {
    let title: String
    let systemImage: String
    var secondary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Even.Palette.textPrimary)
                .accessibilityHidden(true)

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.evenTileTitle)
                    .tracking(-0.2)
                    .foregroundStyle(Even.Palette.textPrimary)
                    .lineLimit(1)
                if let secondary, !secondary.isEmpty {
                    Text(secondary)
                        .font(.evenSubtitle)
                        .foregroundStyle(Even.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: Even.tileMinHeight, alignment: .leading)
        .padding(Even.Space.tilePadding)
        .evenTileSurface()
        // Keep the 2-up grid from collapsing at the largest accessibility sizes.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

/// Two equal columns with the spec's 8pt gap.
enum EvenBento {
    static let columns = [
        GridItem(.flexible(), spacing: Even.Space.gap),
        GridItem(.flexible(), spacing: Even.Space.gap)
    ]
}

// MARK: - Control tiles (Device)

/// A toggle rendered as a tile with an ON/OFF state chip instead of a native
/// switch, so hardware controls read as instrument buttons.
struct EvenToggleTile: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(isOn ? Even.Palette.phosphor : Even.Palette.textPrimary)
                    .frame(width: 24)
                Text(title)
                    .font(.evenTileTitle)
                    .foregroundStyle(Even.Palette.textPrimary)
                Spacer()
                StateChip(on: isOn)
            }
            .padding(.horizontal, Even.Space.tilePadding)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .evenTileSurface(fill: isOn ? Even.Palette.surfaceActive : Even.Palette.surface)
        }
        .buttonStyle(.evenPressable)
    }

    private struct StateChip: View {
        let on: Bool
        var body: some View {
            Text(on ? "On" : "Off")
                .font(.evenMicro)
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(on ? Even.Palette.base : Even.Palette.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: Even.Radius.chip, style: .continuous)
                        .fill(on ? Even.Palette.phosphor : Even.Palette.surfaceActive)
                )
        }
    }
}

/// A tappable tile (small bento) for one-shot actions like Clear HUD /
/// Disconnect. `role` tints only the truly destructive one.
struct EvenActionTile: View {
    enum Role { case normal, destructive }

    let title: String
    let systemImage: String
    var role: Role = .normal
    let action: () -> Void

    private var tint: Color {
        role == .destructive ? Even.Palette.destructive : Even.Palette.textPrimary
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(tint)
                Spacer(minLength: 14)
                Text(title)
                    .font(.evenTileTitle)
                    .tracking(-0.2)
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .padding(Even.Space.tilePadding)
            .evenTileSurface()
        }
        .buttonStyle(.evenPressable)
    }
}

/// Brightness as a full-width tile: label + live value on top, slider below, and
/// an inline auto-level toggle so the two related controls stay together.
struct EvenSliderTile: View {
    let title: String
    let systemImage: String
    let valueLabel: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var onEditingChanged: (Bool) -> Void = { _ in }

    var autoLabel: String?
    var autoIsOn: Binding<Bool>?

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Even.Palette.textPrimary)
                    .frame(width: 24)
                Text(title)
                    .font(.evenTileTitle)
                    .foregroundStyle(Even.Palette.textPrimary)
                Spacer()
                Text(valueLabel)
                    .font(.evenMicro)
                    .foregroundStyle(Even.Palette.phosphor)
            }

            Slider(value: $value, in: range, step: step, onEditingChanged: onEditingChanged)
                .tint(Even.Palette.phosphor)

            if let autoLabel, let autoIsOn {
                Divider().overlay(Even.Palette.border)
                Button {
                    autoIsOn.wrappedValue.toggle()
                } label: {
                    HStack {
                        Text(autoLabel)
                            .font(.evenSubtitle)
                            .foregroundStyle(Even.Palette.textSecondary)
                        Spacer()
                        Text(autoIsOn.wrappedValue ? "On" : "Off")
                            .font(.evenMicro)
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .foregroundStyle(autoIsOn.wrappedValue ? Even.Palette.phosphor : Even.Palette.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Even.Space.tilePadding)
        .frame(maxWidth: .infinity)
        .evenTileSurface()
    }
}

// MARK: - Disconnected notice

/// Quiet, in-voice notice when the lens isn't linked. No apology, just what
/// still works.
struct EvenDisconnectedNotice: View {
    var message: String = "Glasses aren't linked. Modules still run in the app and mirror to the lens once you connect."

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "eyeglasses")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Even.Palette.caution)
            Text(message)
                .font(.evenSubtitle)
                .foregroundStyle(Even.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Even.Space.tilePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .evenTileSurface()
    }
}
