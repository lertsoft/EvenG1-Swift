import SwiftUI

/// The one bold element in the whole app: a simulator of the G1's green
/// monochrome lens. It is the only surface allowed the dot-matrix texture and
/// the phosphor glow — everything around it stays quiet so this reads as the
/// hero.
struct EvenLensPreview<Content: View>: View {
    var title: String = "Lens Preview"
    let isLinked: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).evenSectionHeader()
                Spacer()
                EvenStatusIndicator(isLive: isLinked, liveLabel: "Linked", idleLabel: "Offline")
            }

            EvenLensDisplay { content }
        }
    }
}

/// The lens surface itself: the `#141414` field, a faint dot grid, and whatever
/// phosphor content is layered on top.
struct EvenLensDisplay<Content: View>: View {
    var height: CGFloat = 140
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            Even.Palette.hud
            EvenDotGrid()
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: Even.Radius.hud, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Even.Radius.hud, style: .continuous)
                .stroke(Even.Palette.border, lineWidth: 1)
        )
    }
}

/// Faint regular dot matrix, drawn once as a Canvas so it costs nothing to
/// composite. Kept at ~15% so it textures the field without competing with text.
struct EvenDotGrid: View {
    var spacing: CGFloat = 9
    var dotRadius: CGFloat = 0.7

    var body: some View {
        Canvas { context, size in
            let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: dotRadius * 2, height: dotRadius * 2))
            var y: CGFloat = spacing / 2
            while y < size.height {
                var x: CGFloat = spacing / 2
                while x < size.width {
                    context.fill(
                        dot.offsetBy(dx: x - dotRadius, dy: y - dotRadius),
                        with: .color(Even.Palette.phosphor.opacity(0.14))
                    )
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

/// Default lens content mirroring the glasses' idle dashboard: a big phosphor
/// clock and date on the left, a hairline divider, and a live status column on
/// the right. Updates itself every few seconds via a timeline.
struct EvenLensDashboardContent: View {
    let isLinked: Bool
    var statusHeadline: String
    var statusDetail: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.time.string(from: context.date))
                        .font(.evenHUD(34))
                        .foregroundStyle(Even.Palette.phosphor)
                        .monospacedDigit()
                    Text(Self.date.string(from: context.date).uppercased())
                        .font(.evenHUD(12))
                        .foregroundStyle(Even.Palette.phosphor.opacity(0.7))
                }

                Rectangle()
                    .fill(Even.Palette.phosphor.opacity(0.35))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 4) {
                    Text(statusHeadline)
                        .font(.evenHUD(13))
                        .foregroundStyle(Even.Palette.phosphor)
                        .lineLimit(1)
                    Text(statusDetail)
                        .font(.evenHUD(11))
                        .foregroundStyle(Even.Palette.phosphor.opacity(0.6))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MM/dd"
        return f
    }()
}
