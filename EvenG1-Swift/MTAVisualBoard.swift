import CoreLocation
import EvenG1Core
import Foundation
import UIKit

enum MTAVisualPageLayout: Hashable {
    case summaryDual
    case summarySingle
    case list
}

struct MTAVisualRow: Equatable, Hashable {
    let routeID: String
    let directionLabel: String
    let minutesAway: Int
}

struct MTAVisualPage: Equatable, Identifiable, Hashable {
    let title: String
    let subtitle: String
    let layout: MTAVisualPageLayout
    let rows: [MTAVisualRow]
    let alertLine: String?
    let hintLine: String
    let pageIndex: Int
    let totalPages: Int

    /// Stable identity from page content so SwiftUI can reuse rendered images.
    var id: String {
        var hasher = Hasher()
        hasher.combine(title)
        hasher.combine(subtitle)
        hasher.combine(layout)
        hasher.combine(rows)
        hasher.combine(alertLine)
        hasher.combine(hintLine)
        hasher.combine(pageIndex)
        hasher.combine(totalPages)
        return "mta-page-\(hasher.finalize())"
    }
}

struct MTAVisualBoardBuilder {
    static func buildPages(station: MTAStationSelection?,
                           userCoordinate: CLLocationCoordinate2D?,
                           trains: [MTANextTrainResult],
                           alerts: [MTAServiceAlert],
                           directionMode: MTADirectionPreferenceMode) -> [MTAVisualPage] {
        guard let station else {
            return []
        }

        let hint = "Tap left stem for next, right stem for prev"
        let alertLine = alerts.first.map { summarizeAlert($0) }
        let title = stationTitle(station: station, userCoordinate: userCoordinate)

        var uptown = trains.filter { mtaDirectionBucket(for: $0.direction) == .uptown }
        var downtown = trains.filter { mtaDirectionBucket(for: $0.direction) == .downtown }
        let other = trains.filter { mtaDirectionBucket(for: $0.direction) == .other }

        uptown.sort { $0.arrivalTime < $1.arrivalTime }
        downtown.sort { $0.arrivalTime < $1.arrivalTime }

        var pages: [MTAVisualPage] = []

        switch directionMode {
        case .uptownOnly, .downtownOnly:
            let source = directionMode == .uptownOnly ? uptown : downtown
            let label = directionMode == .uptownOnly ? "Uptown/Northbound" : "Downtown/Southbound"
            let summaryRows = Array(source.prefix(8)).map(rowFromTrain)
            if !summaryRows.isEmpty {
                pages.append(
                    MTAVisualPage(
                        title: title,
                        subtitle: "\(label) Summary",
                        layout: .summarySingle,
                        rows: summaryRows,
                        alertLine: alertLine,
                        hintLine: hint,
                        pageIndex: 0,
                        totalPages: 0
                    )
                )
            }

            let overflowRows = Array(source.dropFirst(summaryRows.count)).map(rowFromTrain)
            appendOverflowPages(
                to: &pages,
                title: title,
                subtitlePrefix: "\(label) Overflow",
                rows: overflowRows,
                alertLine: alertLine,
                hintLine: hint
            )

        case .both:
            let summary = buildDualSummary(uptown: uptown, downtown: downtown)
            pages.append(
                MTAVisualPage(
                    title: title,
                    subtitle: "Uptown/Northbound + Downtown/Southbound",
                    layout: .summaryDual,
                    rows: summary.rows.map(rowFromTrain),
                    alertLine: alertLine,
                    hintLine: hint,
                    pageIndex: 0,
                    totalPages: 0
                )
            )

            let uptownOverflow = Array(uptown.dropFirst(summary.uptownUsed)).map(rowFromTrain)
            let downtownOverflow = Array(downtown.dropFirst(summary.downtownUsed)).map(rowFromTrain)
            appendOverflowPages(
                to: &pages,
                title: title,
                subtitlePrefix: "Uptown/Northbound Overflow",
                rows: uptownOverflow,
                alertLine: alertLine,
                hintLine: hint
            )
            appendOverflowPages(
                to: &pages,
                title: title,
                subtitlePrefix: "Downtown/Southbound Overflow",
                rows: downtownOverflow,
                alertLine: alertLine,
                hintLine: hint
            )

            if !other.isEmpty {
                appendOverflowPages(
                    to: &pages,
                    title: title,
                    subtitlePrefix: "Other Direction Overflow",
                    rows: other.map(rowFromTrain),
                    alertLine: alertLine,
                    hintLine: hint
                )
            }
        }

        if pages.isEmpty {
            pages = [
                MTAVisualPage(
                    title: title,
                    subtitle: "No arrivals in next 30 minutes",
                    layout: .list,
                    rows: [],
                    alertLine: alertLine,
                    hintLine: hint,
                    pageIndex: 0,
                    totalPages: 0
                )
            ]
        }

        let count = pages.count
        return pages.enumerated().map { index, page in
            MTAVisualPage(
                title: page.title,
                subtitle: page.subtitle,
                layout: page.layout,
                rows: page.rows,
                alertLine: page.alertLine,
                hintLine: page.hintLine,
                pageIndex: index,
                totalPages: count
            )
        }
    }

    nonisolated private static func rowFromTrain(_ train: MTANextTrainResult) -> MTAVisualRow {
        MTAVisualRow(
            routeID: train.routeID,
            directionLabel: mtaDirectionDualLabel(for: train.direction),
            minutesAway: train.minutesAway
        )
    }

    nonisolated private static func appendOverflowPages(to pages: inout [MTAVisualPage],
                                                        title: String,
                                                        subtitlePrefix: String,
                                                        rows: [MTAVisualRow],
                                                        alertLine: String?,
                                                        hintLine: String) {
        guard !rows.isEmpty else {
            return
        }

        let pageSize = 6
        var start = 0
        var index = 1
        while start < rows.count {
            let end = min(start + pageSize, rows.count)
            let chunk = Array(rows[start..<end])
            pages.append(
                MTAVisualPage(
                    title: title,
                    subtitle: "\(subtitlePrefix) \(index)",
                    layout: .list,
                    rows: chunk,
                    alertLine: alertLine,
                    hintLine: hintLine,
                    pageIndex: 0,
                    totalPages: 0
                )
            )
            start = end
            index += 1
        }
    }

    nonisolated private static func buildDualSummary(uptown: [MTANextTrainResult],
                                                     downtown: [MTANextTrainResult]) -> (rows: [MTANextTrainResult], uptownUsed: Int, downtownUsed: Int) {
        var uptownRows = Array(uptown.prefix(4))
        var downtownRows = Array(downtown.prefix(4))
        var uptownUsed = uptownRows.count
        var downtownUsed = downtownRows.count

        if uptownRows.count < 4 {
            let needed = 4 - uptownRows.count
            let borrowed = Array(downtown.dropFirst(downtownUsed).prefix(needed))
            uptownRows.append(contentsOf: borrowed)
            downtownUsed += borrowed.count
        }

        if downtownRows.count < 4 {
            let needed = 4 - downtownRows.count
            let borrowed = Array(uptown.dropFirst(uptownUsed).prefix(needed))
            downtownRows.append(contentsOf: borrowed)
            uptownUsed += borrowed.count
        }

        return (rows: uptownRows + downtownRows, uptownUsed: uptownUsed, downtownUsed: downtownUsed)
    }

    nonisolated private static func summarizeAlert(_ alert: MTAServiceAlert) -> String {
        let header = alert.header.trimmingCharacters(in: .whitespacesAndNewlines)
        if !header.isEmpty {
            return "\(alert.effect): \(header)"
        }

        if let description = alert.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            return "\(alert.effect): \(description)"
        }

        return alert.effect
    }

    nonisolated private static func stationTitle(station: MTAStationSelection,
                                                 userCoordinate: CLLocationCoordinate2D?) -> String {
        let distance: Int
        if let userCoordinate {
            let user = CLLocation(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude)
            let location = CLLocation(latitude: station.latitude, longitude: station.longitude)
            distance = Int(user.distance(from: location))
        } else {
            distance = Int(station.distanceMeters ?? 0)
        }

        let stationCoordinate = CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude)
        let arrow = bearingArrow(userCoordinate: userCoordinate, stationCoordinate: stationCoordinate)
        return "\(station.stationName) \(arrow) \(distance)m"
    }

    nonisolated private static func bearingArrow(userCoordinate: CLLocationCoordinate2D?,
                                                 stationCoordinate: CLLocationCoordinate2D) -> String {
        guard let userCoordinate else {
            return "*"
        }

        let lat1 = userCoordinate.latitude * .pi / 180
        let lon1 = userCoordinate.longitude * .pi / 180
        let lat2 = stationCoordinate.latitude * .pi / 180
        let lon2 = stationCoordinate.longitude * .pi / 180

        let y = sin(lon2 - lon1) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(lon2 - lon1)
        var bearing = atan2(y, x) * 180 / .pi
        if bearing < 0 {
            bearing += 360
        }

        switch bearing {
        case 337.5...360, 0..<22.5:
            return "N"
        case 22.5..<67.5:
            return "NE"
        case 67.5..<112.5:
            return "E"
        case 112.5..<157.5:
            return "SE"
        case 157.5..<202.5:
            return "S"
        case 202.5..<247.5:
            return "SW"
        case 247.5..<292.5:
            return "W"
        default:
            return "NW"
        }
    }
}

enum MTABitmapRendererError: Error {
    case imageBuildFailed
    case bitmapPackFailed
}

struct MTABitmapRenderer: Sendable {
    /// Single rasterization pass producing both the in-app preview image and the glasses bitmap frame.
    struct RenderedPage: @unchecked Sendable {
        let image: UIImage
        let frame: G1BitmapFrame
    }

    nonisolated func render(page: MTAVisualPage) throws -> RenderedPage {
        let image = renderImage(page: page)

        guard let cgImage = image.cgImage else {
            throw MTABitmapRendererError.imageBuildFailed
        }

        guard let packed = Self.packMonochromeBits(from: cgImage) else {
            throw MTABitmapRendererError.bitmapPackFailed
        }

        let frame = try G1BitmapFrame(
            width: G1BitmapFrame.defaultWidth,
            height: G1BitmapFrame.defaultHeight,
            bitPackedRows: packed
        )
        return RenderedPage(image: image, frame: frame)
    }

    /// Renders the page at true display resolution. The in-app HUD preview draws
    /// this image directly so it cannot drift from what the glasses receive.
    nonisolated func renderImage(page: MTAVisualPage) -> UIImage {
        let width = G1BitmapFrame.defaultWidth
        let height = G1BitmapFrame.defaultHeight
        let size = CGSize(width: width, height: height)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let headerAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: UIColor.white
            ]
            let rowAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: UIColor.white
            ]

            NSString(string: page.title).draw(at: CGPoint(x: 8, y: 4), withAttributes: headerAttrs)
            NSString(string: page.subtitle).draw(at: CGPoint(x: 8, y: 20), withAttributes: subAttrs)
            NSString(string: "Page \(page.pageIndex + 1)/\(max(1, page.totalPages))").draw(
                at: CGPoint(x: 456, y: 4),
                withAttributes: subAttrs
            )

            let rowHeight: CGFloat = 14
            switch page.layout {
            case .summaryDual:
                let leftRows = Array(page.rows.prefix(4))
                let rightRows = Array(page.rows.dropFirst(4).prefix(4))
                for (index, row) in leftRows.enumerated() {
                    let line = rowLineText(row)
                    NSString(string: line).draw(
                        at: CGPoint(x: 8, y: 40 + CGFloat(index) * rowHeight),
                        withAttributes: rowAttrs
                    )
                }
                for (index, row) in rightRows.enumerated() {
                    let line = rowLineText(row)
                    NSString(string: line).draw(
                        at: CGPoint(x: 292, y: 40 + CGFloat(index) * rowHeight),
                        withAttributes: rowAttrs
                    )
                }

            case .summarySingle, .list:
                for (index, row) in page.rows.prefix(6).enumerated() {
                    let line = rowLineText(row)
                    NSString(string: line).draw(
                        at: CGPoint(x: 8, y: 40 + CGFloat(index) * rowHeight),
                        withAttributes: rowAttrs
                    )
                }
            }

            if let alertLine = page.alertLine, !alertLine.isEmpty {
                NSString(string: "Alert: \(truncated(alertLine, maxLength: 58))").draw(
                    at: CGPoint(x: 8, y: 112),
                    withAttributes: subAttrs
                )
            }

            NSString(string: page.hintLine).draw(
                at: CGPoint(x: 8, y: 124),
                withAttributes: subAttrs
            )
        }
    }

    nonisolated private func rowLineText(_ row: MTAVisualRow) -> String {
        let route = row.routeID.padding(toLength: 2, withPad: " ", startingAt: 0)
        return "\(route) \(truncated(row.directionLabel, maxLength: 19)) \(row.minutesAway)m"
    }

    nonisolated private func truncated(_ value: String, maxLength: Int) -> String {
        if value.count <= maxLength {
            return value
        }
        guard maxLength > 3 else {
            return String(value.prefix(maxLength))
        }
        return String(value.prefix(maxLength - 3)) + "..."
    }

    nonisolated private static func packMonochromeBits(from image: CGImage) -> Data? {
        G1MonochromeBitmapPacker.packBits(from: image)
    }
}
