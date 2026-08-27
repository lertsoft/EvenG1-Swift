import SwiftUI

/// The Even Realities visual language, expressed as tokens rather than scattered
/// literals. One accent (phosphor green) carries every live/active state; the
/// rest of the interface stays monochrome so the lens is the only thing that
/// glows. Sizes are mapped onto system text styles so they match the spec's
/// baseline point sizes *and* scale with Dynamic Type.
enum Even {
    // MARK: Palette

    enum Palette {
        /// Main app canvas.
        static let base = Color(hex: 0x0D0D0D)
        /// Bento tiles, control tiles, sheets.
        static let surface = Color(hex: 0x1A1A1A)
        /// Pressed / active tile state.
        static let surfaceActive = Color(hex: 0x242424)
        /// The lens-simulator background.
        static let hud = Color(hex: 0x141414)

        /// 1px card outlines — no heavy glow.
        static let border = Color.white.opacity(0.08)
        /// Slightly stronger hairline for glass sheets over the map.
        static let borderStrong = Color.white.opacity(0.12)

        static let textPrimary = Color(hex: 0xF5F5F7)
        /// Bumped from the spec's #86868B so 11–12pt passes WCAG AA on `surface`.
        static let textSecondary = Color(hex: 0xA1A1A6)
        static let textTertiary = Color(hex: 0x6E6E73)

        /// The one accent. Lens phosphor: vivid, not neon.
        static let phosphor = Color(hex: 0x4BE38A)
        /// Dimmed phosphor for the HUD grid texture and idle glows.
        static let phosphorDim = Color(hex: 0x4BE38A).opacity(0.16)

        /// Reserved strictly for irreversible actions (Disconnect). Not decoration.
        static let destructive = Color(hex: 0xFF453A)
        /// A cool amber for transient in-between states (scanning / partial link).
        static let caution = Color(hex: 0xFFB020)
    }

    // MARK: Geometry

    enum Radius {
        static let tile: CGFloat = 12
        static let control: CGFloat = 12
        static let sheet: CGFloat = 20
        static let hud: CGFloat = 12
        static let chip: CGFloat = 8
    }

    enum Space {
        /// Bento gap, horizontal and vertical.
        static let gap: CGFloat = 8
        /// Outer horizontal screen margins.
        static let margin: CGFloat = 16
        /// Internal tile padding.
        static let tilePadding: CGFloat = 14
        /// Vertical rhythm between stacked sections.
        static let section: CGFloat = 16
    }

    /// Standard bento tile height range from the spec.
    static let tileMinHeight: CGFloat = 116

    /// Motion is used sparingly — press feedback and the lens cursor only.
    enum Motion {
        static let press = Animation.easeOut(duration: 0.12)
    }
}

// MARK: - Hex color

extension Color {
    /// `Color(hex: 0x1A1A1A)` — opaque RRGGBB.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

// MARK: - Typography

extension Font {
    /// Instrument label / eyebrow. Monospaced, used with UPPERCASE + tracking.
    static let evenEyebrow = Font.system(.caption2, design: .monospaced).weight(.medium)
    /// Large screen title. Title Case.
    static let evenScreenTitle = Font.system(.largeTitle, design: .default).weight(.semibold)
    /// Section header above a group of controls/tiles. Monospaced UPPERCASE.
    static let evenSectionHeader = Font.system(.caption, design: .monospaced).weight(.medium)
    /// Bento tile title.
    static let evenTileTitle = Font.system(.subheadline, design: .default).weight(.medium)
    /// Secondary / helper text.
    static let evenSubtitle = Font.system(.caption, design: .default)
    /// Micro status, numeric readouts.
    static let evenMicro = Font.system(.caption2, design: .monospaced)
    /// Monospaced HUD body — the lens simulator only.
    static func evenHUD(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }
}

extension Text {
    /// Small monospaced instrument label, e.g. `EVEN REALITIES / G1`.
    func evenEyebrow() -> some View {
        self
            .font(.evenEyebrow)
            .tracking(1.4)
            .textCase(.uppercase)
            .foregroundStyle(Even.Palette.textSecondary)
    }

    /// Section header sitting above a bento group.
    func evenSectionHeader() -> some View {
        self
            .font(.evenSectionHeader)
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(Even.Palette.textSecondary)
    }
}

// MARK: - Pressable style

/// Quiet, tactile press feedback shared by every tile and glyph button, so the
/// whole app depresses the same way instead of each control inventing its own.
struct EvenPressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(Even.Motion.press, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == EvenPressableStyle {
    static var evenPressable: EvenPressableStyle { EvenPressableStyle() }
}

// MARK: - Surfaces

extension View {
    /// A standard tile surface: fill + 1px hairline at a shared radius.
    func evenTileSurface(
        radius: CGFloat = Even.Radius.tile,
        fill: Color = Even.Palette.surface
    ) -> some View {
        self
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Even.Palette.border, lineWidth: 1)
            )
    }
}
