import CoreGraphics
import EvenG1Core
import Foundation
import UIKit

enum DashboardBitmapRendererError: Error {
    case imageBuildFailed
    case bitmapPackFailed
}

/// Rasterizes a ``DashboardSnapshot`` for a given ``DashboardSettings`` into the
/// glasses' 576x135 monochrome frame, plus a matching preview image.
///
/// Modeled on `MTABitmapRenderer`: one CoreGraphics pass produces the in-app
/// preview and the wire frame from the same drawing, so the preview cannot drift
/// from what the glasses receive. The renderer only reads a snapshot; it never
/// touches a live service, which keeps head-up rendering off the network path.
struct DashboardBitmapRenderer: Sendable {
    struct Rendered: @unchecked Sendable {
        let image: UIImage
        let frame: G1BitmapFrame
    }

    func render(snapshot: DashboardSnapshot, settings: DashboardSettings) throws -> Rendered {
        let image = renderImage(snapshot: snapshot, settings: settings)

        guard let cgImage = image.cgImage else {
            throw DashboardBitmapRendererError.imageBuildFailed
        }
        guard let packed = G1MonochromeBitmapPacker.packBits(from: cgImage) else {
            throw DashboardBitmapRendererError.bitmapPackFailed
        }

        let frame = try G1BitmapFrame(
            width: G1BitmapFrame.defaultWidth,
            height: G1BitmapFrame.defaultHeight,
            bitPackedRows: packed
        )
        return Rendered(image: image, frame: frame)
    }

    func renderImage(snapshot: DashboardSnapshot, settings: DashboardSettings) -> UIImage {
        let size = CGSize(width: G1BitmapFrame.defaultWidth, height: G1BitmapFrame.defaultHeight)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        let zones = DashboardLayout.zones(for: settings.layout)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            if settings.layout == .minimal {
                drawMinimalStatus(in: zones.status, snapshot: snapshot, settings: settings)
            } else {
                drawStatus(in: zones.status, snapshot: snapshot, settings: settings)
            }

            if let calendarRect = zones.calendar {
                drawCalendar(in: calendarRect, event: snapshot.nextEvent, redact: settings.redactSensitiveContent)
            }

            if let dividerX = zones.dividerX {
                drawDivider(atX: dividerX)
            }

            if let widgetRect = zones.widget {
                drawWidget(in: widgetRect, content: snapshot.widget, redact: settings.redactSensitiveContent)
            }

            if let indicatorRect = zones.pageIndicator {
                draw("1/1", in: indicatorRect, font: Self.smallFont, alignment: .right)
            }
        }
    }

    // MARK: - Zones

    private func drawStatus(in rect: CGRect, snapshot: DashboardSnapshot, settings: DashboardSettings) {
        let time = Self.timeString(from: snapshot.referenceDate, format: settings.timeFormat)
        let date = Self.dateString(from: snapshot.referenceDate)

        draw(time, at: CGPoint(x: rect.minX, y: rect.minY), font: Self.timeFont)
        draw(date, at: CGPoint(x: rect.minX, y: rect.minY + 34), font: Self.bodyFont)

        var badges: [String] = []
        if let count = snapshot.reminderCount {
            badges.append("Reminders \(count)")
        }
        if let temperature = snapshot.temperature {
            badges.append(Self.temperatureString(temperature, unit: settings.temperatureUnit))
        }
        if !badges.isEmpty {
            draw(badges.joined(separator: "   "), at: CGPoint(x: rect.minX, y: rect.minY + 54), font: Self.bodyFont)
        }
    }

    private func drawMinimalStatus(in rect: CGRect, snapshot: DashboardSnapshot, settings: DashboardSettings) {
        let time = Self.timeString(from: snapshot.referenceDate, format: settings.timeFormat)
        let date = Self.dateString(from: snapshot.referenceDate)
        draw(time, at: CGPoint(x: rect.minX, y: rect.minY + 6), font: Self.bigTimeFont)
        var trailing = date
        if let temperature = snapshot.temperature {
            trailing += "   " + Self.temperatureString(temperature, unit: settings.temperatureUnit)
        }
        draw(trailing, at: CGPoint(x: rect.minX, y: rect.minY + 78), font: Self.subtitleFont)
    }

    private func drawCalendar(in rect: CGRect, event: DashboardCalendarEvent?, redact: Bool) {
        guard let event else {
            draw("No upcoming events", in: rect, font: Self.smallFont, alignment: .left)
            return
        }
        let title = redact ? "Upcoming event" : event.title
        draw(Self.truncate(title, max: 24), at: CGPoint(x: rect.minX, y: rect.minY), font: Self.bodyFont)
        draw(Self.eventTimeRange(event), at: CGPoint(x: rect.minX, y: rect.minY + 16), font: Self.smallFont)
    }

    private func drawWidget(in rect: CGRect, content: DashboardWidgetContent, redact: Bool) {
        switch content {
        case .quickNote(let text):
            drawWrapped(redact ? "QuickNote" : text, in: rect, font: Self.bodyFont)

        case .news(let source, let headline):
            draw(source, at: CGPoint(x: rect.minX, y: rect.minY), font: Self.smallFont)
            drawWrapped(headline, in: rect.offsetBy(dx: 0, dy: 18), font: Self.bodyFont)

        case .stocks(let quotes):
            for (index, quote) in quotes.prefix(4).enumerated() {
                let sign = quote.changePercent >= 0 ? "+" : ""
                let line = "\(quote.symbol)  \(String(format: "%.2f", quote.price))  \(sign)\(String(format: "%.1f", quote.changePercent))%"
                draw(line, at: CGPoint(x: rect.minX, y: rect.minY + CGFloat(index) * 18), font: Self.bodyFont)
            }

        case .map:
            draw("Map unavailable", in: rect, font: Self.bodyFont, alignment: .left)

        case .unavailable(let reason):
            draw(reason, in: rect, font: Self.smallFont, alignment: .left)
        }
    }

    private func drawDivider(atX x: CGFloat) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: x, y: DashboardLayout.margin))
        path.addLine(to: CGPoint(x: x, y: DashboardLayout.height - DashboardLayout.margin))
        UIColor.white.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    // MARK: - Text helpers

    private static let bigTimeFont = UIFont.monospacedSystemFont(ofSize: 56, weight: .bold)
    private static let timeFont = UIFont.monospacedSystemFont(ofSize: 30, weight: .bold)
    private static let subtitleFont = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    private static let bodyFont = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private static let smallFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    private func attributes(for font: UIFont) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: UIColor.white]
    }

    private func draw(_ text: String, at point: CGPoint, font: UIFont) {
        NSString(string: text).draw(at: point, withAttributes: attributes(for: font))
    }

    private func draw(_ text: String, in rect: CGRect, font: UIFont, alignment: NSTextAlignment) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        var attrs = attributes(for: font)
        attrs[.paragraphStyle] = paragraph
        NSString(string: text).draw(in: rect, withAttributes: attrs)
    }

    private func drawWrapped(_ text: String, in rect: CGRect, font: UIFont) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        var attrs = attributes(for: font)
        attrs[.paragraphStyle] = paragraph
        NSString(string: text).draw(in: rect, withAttributes: attrs)
    }

    // MARK: - Formatting

    static func timeString(from date: Date, format: DashboardTimeFormat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format == .twentyFourHour ? "HH:mm" : "h:mm a"
        return formatter.string(from: date)
    }

    static func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, MM/dd"
        return formatter.string(from: date)
    }

    static func temperatureString(_ temperature: DashboardTemperature, unit: DashboardTemperatureUnit) -> String {
        let value = convert(temperature, to: unit)
        return "\(Int(value.rounded()))\u{00B0}\(unit.suffix)"
    }

    static func convert(_ temperature: DashboardTemperature, to unit: DashboardTemperatureUnit) -> Double {
        guard temperature.unit != unit else { return temperature.value }
        switch unit {
        case .celsius:
            return (temperature.value - 32) * 5 / 9
        case .fahrenheit:
            return temperature.value * 9 / 5 + 32
        }
    }

    static func eventTimeRange(_ event: DashboardCalendarEvent) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        let start = formatter.string(from: event.startTime)
        guard let end = event.endTime else { return start }
        return "\(start)-\(formatter.string(from: end))"
    }

    static func truncate(_ value: String, max: Int) -> String {
        guard value.count > max else { return value }
        guard max > 3 else { return String(value.prefix(max)) }
        return String(value.prefix(max - 3)) + "..."
    }
}
