import CoreGraphics
import Foundation

/// Shared layout constants for navigation bitmaps rendered to the G1 glasses.
///
/// The glasses expose one 576×135 logical canvas to both arms. Keeping important
/// route geometry inside a centered safe region reduces binocular ghosting when
/// dense full-bleed map imagery would otherwise overlap across the waveguides.
public enum G1NavigationBitmapLayout {
    public static let canvasWidth = G1BitmapFrame.defaultWidth
    public static let canvasHeight = G1BitmapFrame.defaultHeight

    /// Horizontal inset applied on both sides of the canvas.
    public static let horizontalMargin: CGFloat = 48

    /// Reduced inset used by the head-up overview, which trades a little
    /// binocular safety for the wider surface the overview needs.
    public static let wideHorizontalMargin: CGFloat = 24

    /// Width reserved on the left of the content area for the stats column.
    public static let statsColumnWidth: CGFloat = 74

    /// Gap between the stats column and the map surface.
    public static let statsColumnGutter: CGFloat = 10

    /// Overlay glyphs and the pre-binarized street layer are drawn in pure
    /// black or white, so the packing threshold only needs to survive glyph
    /// antialiasing.
    public static let monochromeThreshold: UInt8 = 96

    public static var contentRect: CGRect {
        contentRect(horizontalMargin: horizontalMargin)
    }

    public static func contentRect(horizontalMargin margin: CGFloat) -> CGRect {
        CGRect(
            x: margin,
            y: 0,
            width: CGFloat(canvasWidth) - (margin * 2),
            height: CGFloat(canvasHeight)
        )
    }

    /// Map surface for a given content area, leaving room for the stats column.
    public static func mapRect(in content: CGRect, topInset: CGFloat) -> CGRect {
        let originX = content.minX + statsColumnWidth + statsColumnGutter
        return CGRect(
            x: originX,
            y: content.minY + topInset,
            width: max(1, content.maxX - originX),
            height: max(1, content.height - topInset - 2)
        )
    }

    public static func statsColumnRect(in content: CGRect) -> CGRect {
        CGRect(x: content.minX, y: content.minY, width: statsColumnWidth, height: content.height)
    }

    public static func centeredPanelRect(width panelWidth: CGFloat, height: CGFloat = 34) -> CGRect {
        let clampedWidth = min(panelWidth, contentRect.width - 8)
        return CGRect(
            x: contentRect.midX - (clampedWidth / 2),
            y: 4,
            width: clampedWidth,
            height: height
        )
    }

    public static func validatesCanvasDimensions(width: Int, height: Int) -> Bool {
        width == canvasWidth && height == canvasHeight
    }

    /// Grayscale cut-off that keeps at most `maximumInkRatio` of the pixels lit.
    public static func inkBudgetThreshold(histogram: [Int], maximumInkRatio: Double) -> UInt8 {
        let total = histogram.reduce(0, +)
        guard histogram.count == 256, total > 0 else { return monochromeThreshold }

        let allowed = Int((Double(total) * max(0, min(1, maximumInkRatio))).rounded())
        var lit = 0
        var threshold = 255
        for level in stride(from: 255, through: 1, by: -1) {
            lit += histogram[level]
            if lit > allowed {
                break
            }
            threshold = level
        }
        return UInt8(max(1, min(255, threshold)))
    }

    /// Otsu's split between the two dominant tones, plus the distance between
    /// their means. A small separation means the tiles carry no usable
    /// structure (open water, a failed tile fetch) rather than a road network.
    public static func otsuSplit(histogram: [Int]) -> (threshold: UInt8, separation: Int)? {
        let total = histogram.reduce(0, +)
        guard histogram.count == 256, total > 0 else { return nil }

        let weightedSum = histogram.indices.reduce(0.0) { $0 + Double($1 * histogram[$1]) }
        var backgroundSum = 0.0
        var backgroundCount = 0
        var bestVariance = 0.0
        var bestThreshold = 0
        var bestSeparation = 0.0

        for level in 0..<256 {
            backgroundCount += histogram[level]
            guard backgroundCount > 0 else { continue }
            let foregroundCount = total - backgroundCount
            guard foregroundCount > 0 else { break }

            backgroundSum += Double(level * histogram[level])
            let backgroundMean = backgroundSum / Double(backgroundCount)
            let foregroundMean = (weightedSum - backgroundSum) / Double(foregroundCount)
            let delta = foregroundMean - backgroundMean
            let variance = Double(backgroundCount) * Double(foregroundCount) * delta * delta
            if variance > bestVariance {
                bestVariance = variance
                bestThreshold = level
                bestSeparation = delta
            }
        }

        guard bestVariance > 0 else { return nil }
        return (UInt8(max(1, min(255, bestThreshold))), Int(bestSeparation.rounded()))
    }

    /// Cut-off that isolates road surfaces in a MapKit tile snapshot.
    ///
    /// MapKit has no fixed palette, so a constant threshold either erases the
    /// streets or floods the one-bit display with land and block fills. Otsu's
    /// split separates road surfaces from the blocks around them, and the ink
    /// budget keeps a low-contrast tile from lighting up half the display.
    /// Returns `nil` when the tiles hold no road structure worth drawing.
    public static func streetMaskThreshold(histogram: [Int],
                                           maximumInkRatio: Double,
                                           minimumClassSeparation: Int = 8) -> UInt8? {
        guard let split = otsuSplit(histogram: histogram),
              split.separation >= minimumClassSeparation else {
            return nil
        }
        return max(split.threshold, inkBudgetThreshold(histogram: histogram, maximumInkRatio: maximumInkRatio))
    }
}
