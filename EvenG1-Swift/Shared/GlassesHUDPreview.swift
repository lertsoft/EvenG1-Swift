import SwiftUI
import EvenG1Core

/// On-screen stand-in for the G1's 576×135 monochrome display.
///
/// Line breaks come from `G1TextHelper.wrapText`, the same call the text
/// transport makes, so the preview splits and drops lines exactly where the
/// glasses will. Character size is fitted to those lines rather than taken from
/// the vendor glyph table, whose widths are not calibrated to the height the
/// display actually renders at — sizing from the table would truncate text the
/// transport treats as fitting.
struct GlassesHUDPreview: View {
    private static let textHelper = G1TextHelper()

    /// Monospaced advance width as a fraction of point size, with headroom.
    private static let advanceRatio: CGFloat = 0.64
    private static let maximumFontSize: CGFloat = 24
    private static let minimumFontSize: CGFloat = 9

    let lines: [String]
    var placeholder: String = "Nothing on the display"

    init(lines: [String], placeholder: String = "Nothing on the display") {
        self.lines = lines
        self.placeholder = placeholder
    }

    /// Wraps free-form text exactly the way the text transport does.
    init(text: String, placeholder: String = "Nothing on the display") {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrapped = trimmed.isEmpty
            ? []
            : Array(Self.textHelper.wrapText(trimmed).prefix(G1TextHelper.maxLines))
        self.init(lines: wrapped, placeholder: placeholder)
    }

    var body: some View {
        GlassesHUDFrame {
            if visibleLines.isEmpty {
                Text(placeholder)
                    .font(.system(size: Self.maximumFontSize, design: .monospaced))
                    .foregroundStyle(Even.Palette.phosphor.opacity(0.4))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: fontSize, design: .monospaced))
                            .foregroundStyle(Even.Palette.phosphor)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var visibleLines: [String] {
        Array(lines.prefix(G1TextHelper.maxLines))
    }

    /// One size for every line, chosen so the longest line still fits the display
    /// width. A shared size keeps the preview readable as typography instead of
    /// making each line a different scale.
    private var fontSize: CGFloat {
        let longest = visibleLines.map(\.count).max() ?? 0
        guard longest > 0 else { return Self.maximumFontSize }

        let fitted = CGFloat(G1TextHelper.displayWidth) / (Self.advanceRatio * CGFloat(longest))
        return min(Self.maximumFontSize, max(Self.minimumFontSize, fitted))
    }
}

/// Scales any 576×135 content into the available width and dresses it up as a
/// lens so previews across the app read as "this is the glasses display".
struct GlassesHUDFrame<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let width = CGFloat(G1TextHelper.displayWidth)
        let height = CGFloat(G1TextHelper.displayHeight)

        GeometryReader { proxy in
            let scale = proxy.size.width / width

            content
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(width: width, height: height, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: proxy.size.width, height: height * scale, alignment: .topLeading)
        }
        .aspectRatio(width / height, contentMode: .fit)
        .background(Even.Palette.hud)
        .clipShape(RoundedRectangle(cornerRadius: Even.Radius.hud))
        .overlay(
            RoundedRectangle(cornerRadius: Even.Radius.hud)
                .stroke(Even.Palette.border, lineWidth: 1)
        )
    }
}

/// Card wrapper that labels a HUD preview and explains when the glasses are not
/// connected, so the preview is never mistaken for live hardware output.
struct GlassesHUDPreviewCard<Content: View>: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager

    var title: String = "Glasses preview"
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "eyeglasses")
                Text(title)
                Spacer()
                if bluetoothManager.connectionState != .fullyConnected {
                    Text("Not connected")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            content
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        GlassesHUDPreview(text: "In 120m | Turn right onto Bedford Avenue | Rem 1400m | ETA 18:42")
        GlassesHUDPreview(text: "Pick up oat milk")
        GlassesHUDPreview(lines: [])
    }
    .padding()
    .background(Color(.systemBackground))
}
