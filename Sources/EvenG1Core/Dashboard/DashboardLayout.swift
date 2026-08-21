import CoreGraphics

/// Pure geometry for composing the dashboard onto the 576x135 surface.
///
/// Kept free of UIKit so it can be unit tested in `EvenG1Core`. The renderer in
/// the app target reads these rects to place each zone; tests assert the zones
/// stay inside the canvas and do not overlap.
public enum DashboardLayout {
    public static let width = CGFloat(G1BitmapFrame.defaultWidth)
    public static let height = CGFloat(G1BitmapFrame.defaultHeight)

    /// Outer padding kept clear of content on every edge.
    public static let margin: CGFloat = 8

    /// Width of the left status column in Full/Dual layouts.
    public static let statusColumnWidth: CGFloat = 224

    /// Gap between the status column and the widget panel, where the divider sits.
    public static let columnGap: CGFloat = 16

    /// Height reserved for the calendar row at the bottom of the status column
    /// in Full layout.
    public static let calendarRowHeight: CGFloat = 34

    /// The zones a given layout mode occupies. Any zone may be `nil` when the
    /// mode does not use it.
    public struct Zones: Equatable, Sendable {
        public var status: CGRect
        public var calendar: CGRect?
        public var widget: CGRect?
        public var dividerX: CGFloat?
        public var pageIndicator: CGRect?
    }

    private static var canvas: CGRect {
        CGRect(x: 0, y: 0, width: width, height: height)
    }

    private static var contentRect: CGRect {
        canvas.insetBy(dx: margin, dy: margin)
    }

    public static func zones(for mode: DashboardLayoutMode) -> Zones {
        let content = contentRect

        switch mode {
        case .minimal:
            return Zones(
                status: content,
                calendar: nil,
                widget: nil,
                dividerX: nil,
                pageIndicator: nil
            )

        case .dual:
            let statusRect = CGRect(
                x: content.minX,
                y: content.minY,
                width: statusColumnWidth,
                height: content.height
            )
            let dividerX = statusRect.maxX + columnGap / 2
            let widgetX = statusRect.maxX + columnGap
            let widgetRect = CGRect(
                x: widgetX,
                y: content.minY,
                width: content.maxX - widgetX,
                height: content.height
            )
            return Zones(
                status: statusRect,
                calendar: nil,
                widget: widgetRect,
                dividerX: dividerX,
                pageIndicator: nil
            )

        case .full:
            let calendarRect = CGRect(
                x: content.minX,
                y: content.maxY - calendarRowHeight,
                width: statusColumnWidth,
                height: calendarRowHeight
            )
            let statusRect = CGRect(
                x: content.minX,
                y: content.minY,
                width: statusColumnWidth,
                height: content.height - calendarRowHeight
            )
            let dividerX = statusRect.maxX + columnGap / 2
            let widgetX = statusRect.maxX + columnGap
            let widgetRect = CGRect(
                x: widgetX,
                y: content.minY,
                width: content.maxX - widgetX,
                height: content.height
            )
            let indicatorRect = CGRect(
                x: content.maxX - 48,
                y: content.minY,
                width: 48,
                height: 16
            )
            return Zones(
                status: statusRect,
                calendar: calendarRect,
                widget: widgetRect,
                dividerX: dividerX,
                pageIndicator: indicatorRect
            )
        }
    }
}
