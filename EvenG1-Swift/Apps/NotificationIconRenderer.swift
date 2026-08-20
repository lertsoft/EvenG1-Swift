import EvenG1Core
import Foundation
import UIKit

enum NotificationIconRendererError: Error {
    case imageBuildFailed
    case bitmapPackFailed
}

/// Draws the "you have mail, look up to read it" glyph for the lens.
///
/// The envelope is stroked geometry rather than an SF Symbol because the display
/// is one bit deep: a hand-drawn outline stays crisp after thresholding, while a
/// filled symbol either blooms into a solid block or loses its edges.
struct NotificationIconRenderer: Sendable {
    struct RenderedIcon: @unchecked Sendable {
        let image: UIImage
        let frame: G1BitmapFrame
    }

    nonisolated private static let strokeWidth: CGFloat = 5
    nonisolated private static let envelopeSize = CGSize(width: 104, height: 70)
    nonisolated private static let countGap: CGFloat = 22

    nonisolated func render(pendingCount: Int) throws -> RenderedIcon {
        let image = renderImage(pendingCount: pendingCount)

        guard let cgImage = image.cgImage else {
            throw NotificationIconRendererError.imageBuildFailed
        }
        guard let packed = G1MonochromeBitmapPacker.packBits(from: cgImage) else {
            throw NotificationIconRendererError.bitmapPackFailed
        }

        return RenderedIcon(
            image: image,
            frame: try G1BitmapFrame(
                width: G1BitmapFrame.defaultWidth,
                height: G1BitmapFrame.defaultHeight,
                bitPackedRows: packed
            )
        )
    }

    /// Renders at true display resolution so the in-app preview cannot drift from
    /// what the glasses receive.
    nonisolated func renderImage(pendingCount: Int) -> UIImage {
        let size = CGSize(width: G1BitmapFrame.defaultWidth, height: G1BitmapFrame.defaultHeight)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { rendererContext in
            UIColor.black.setFill()
            rendererContext.fill(CGRect(origin: .zero, size: size))

            let countText = pendingCount > 1 ? "\(pendingCount)" : nil
            let countAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 44, weight: .semibold),
                .foregroundColor: UIColor.white
            ]

            var countSize: CGSize = .zero
            if let countText {
                countSize = NSString(string: countText).size(withAttributes: countAttributes)
            }

            let groupWidth = Self.envelopeSize.width + (countText == nil ? 0 : Self.countGap + countSize.width)
            let envelopeOrigin = CGPoint(
                x: ((size.width - groupWidth) / 2).rounded(),
                y: ((size.height - Self.envelopeSize.height) / 2).rounded()
            )
            let envelopeRect = CGRect(origin: envelopeOrigin, size: Self.envelopeSize)

            Self.drawEnvelope(in: envelopeRect, context: rendererContext.cgContext)

            if let countText {
                let countOrigin = CGPoint(
                    x: envelopeRect.maxX + Self.countGap,
                    y: (size.height - countSize.height) / 2
                )
                NSString(string: countText).draw(at: countOrigin, withAttributes: countAttributes)
            }
        }
    }

    nonisolated private static func drawEnvelope(in rect: CGRect, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(strokeWidth)
        context.setLineJoin(.miter)
        context.setLineCap(.square)

        // Keep the stroke fully inside the rect so nothing clips at the edges.
        let inset = strokeWidth / 2
        let body = rect.insetBy(dx: inset, dy: inset)
        context.stroke(body)

        // Flap: a V from the top corners down to the middle of the body, which
        // reads as an envelope at a glance far better than a plain rectangle.
        let flapDepth = body.height * 0.52
        context.move(to: CGPoint(x: body.minX, y: body.minY))
        context.addLine(to: CGPoint(x: body.midX, y: body.minY + flapDepth))
        context.addLine(to: CGPoint(x: body.maxX, y: body.minY))
        context.strokePath()
    }
}
