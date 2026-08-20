import CoreLocation
import EvenG1Core
import Foundation
import MapKit
import UIKit

enum NavigationDisplayDetail: String, Sendable {
    /// Head level: the next stretch of the walk plus the streets around it.
    case minimal
    /// Head up: the whole remaining route on a wider surface.
    case detailed

    /// Distance of route to display ahead of the user. `nil` shows all of it.
    ///
    /// Head up deliberately stops short of the whole route: on a 3.4:1 canvas,
    /// fitting a 9 km leg vertically drags roughly 30 km of city onto the
    /// short axis, which reads as noise rather than as information.
    nonisolated var routeLookAheadMeters: CLLocationDistance? {
        self == .minimal ? 260 : 800
    }

    nonisolated var horizontalMargin: CGFloat {
        self == .minimal
            ? G1NavigationBitmapLayout.horizontalMargin
            : G1NavigationBitmapLayout.wideHorizontalMargin
    }

    nonisolated var routeLineWidth: CGFloat {
        self == .minimal ? 4 : 3
    }

    /// The head-level view carries the turn text; the overview keeps the space
    /// for map.
    nonisolated var showsInstructionLine: Bool {
        self == .minimal
    }
}

struct NavigationMapScene: Sendable {
    let detailLevel: NavigationDisplayDetail
    let userCoordinate: CLLocationCoordinate2D
    let destinationCoordinate: CLLocationCoordinate2D
    let routeCoordinates: [CLLocationCoordinate2D]
    let maneuverCoordinate: CLLocationCoordinate2D?
    let instructionText: String
    let distanceToManeuverMeters: Int
    let remainingDistanceMeters: Int
    let remainingMinutes: Int

    /// Fingerprint so identical frames are not re-uploaded to the glasses.
    ///
    /// The head-level window spans about 700 m across 576 pixels, so a pixel is
    /// roughly a metre of ground. The position must therefore be quantized in
    /// tens of metres; a coarser grid holds a stale frame on the glasses for
    /// entire blocks of walking.
    var uploadSignature: String {
        let latQuantum = Self.positionQuantumMeters / 111_320
        let lonQuantum = latQuantum / max(cos(userCoordinate.latitude * .pi / 180), 0.2)
        let latCell = (userCoordinate.latitude / latQuantum).rounded()
        let lonCell = (userCoordinate.longitude / lonQuantum).rounded()
        return [
            detailLevel.rawValue,
            instructionText,
            String(distanceToManeuverMeters / 20),
            String(remainingDistanceMeters / 50),
            String(remainingMinutes),
            String(format: "%.0f,%.0f", latCell, lonCell),
            String(routeCoordinates.count)
        ].joined(separator: "|")
    }

    private static let positionQuantumMeters = 12.0
}

enum NavigationBitmapRendererError: Error {
    case imageBuildFailed
    case bitmapPackFailed
}

actor NavigationBitmapRenderer {
    struct RenderedScene: @unchecked Sendable {
        let image: UIImage
        let frame: G1BitmapFrame
    }

    private struct Layout {
        let content: CGRect
        let map: CGRect
        let stats: CGRect
    }

    /// Renders route geometry without redistributing Apple Maps imagery.
    ///
    /// MapKit remains the source for route planning and the attributed phone
    /// map, while the external one-bit lens receives only app-authored vectors.
    func render(scene: NavigationMapScene) throws -> RenderedScene {
        let image = renderImage(scene: scene)
        return try makeRenderedScene(from: image)
    }

    private func makeRenderedScene(from image: UIImage) throws -> RenderedScene {
        guard let cgImage = image.cgImage else {
            throw NavigationBitmapRendererError.imageBuildFailed
        }

        guard G1NavigationBitmapLayout.validatesCanvasDimensions(
            width: cgImage.width,
            height: cgImage.height
        ) else {
            throw NavigationBitmapRendererError.imageBuildFailed
        }

        guard let packed = Self.packMonochromeBits(from: cgImage) else {
            throw NavigationBitmapRendererError.bitmapPackFailed
        }

        let frame = try G1BitmapFrame(
            width: G1NavigationBitmapLayout.canvasWidth,
            height: G1NavigationBitmapLayout.canvasHeight,
            bitPackedRows: packed
        )
        return RenderedScene(image: image, frame: frame)
    }

    // MARK: - Drawing

    private func renderImage(scene: NavigationMapScene) -> UIImage {
        let size = CGSize(
            width: G1NavigationBitmapLayout.canvasWidth,
            height: G1NavigationBitmapLayout.canvasHeight
        )
        let layout = Self.layout(for: scene.detailLevel)
        let window = Self.routeWindow(for: scene)
        let displayUser = Self.displayUserCoordinate(
            scene.userCoordinate,
            route: window,
            snapDistanceMeters: 75
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let ctx = context.cgContext
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            let projector = Self.projector(
                layout: layout,
                coordinates: window + [displayUser]
            )

            ctx.saveGState()
            ctx.clip(to: layout.map)
            drawRoute(
                scene: scene,
                window: window,
                displayUser: displayUser,
                projector: projector,
                mapRect: layout.map,
                in: ctx
            )
            ctx.restoreGState()

            drawStatsColumn(scene: scene, layout: layout, in: ctx)

            if scene.detailLevel.showsInstructionLine {
                drawInstructionLine(scene: scene, layout: layout, in: ctx)
            }
        }
    }

    private func drawRoute(scene: NavigationMapScene,
                           window: [CLLocationCoordinate2D],
                           displayUser: CLLocationCoordinate2D,
                           projector: (CLLocationCoordinate2D) -> CGPoint,
                           mapRect: CGRect,
                           in ctx: CGContext) {
        var points = window.map(projector)
        let userPoint = projector(displayUser)
        if let first = points.first, hypot(first.x - userPoint.x, first.y - userPoint.y) > 2 {
            points.insert(userPoint, at: 0)
        }

        if points.count >= 2 {
            // A black casing separates the route from the street wireframe once
            // both are reduced to one bit.
            ctx.saveGState()
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.addLines(between: points)
            ctx.setStrokeColor(UIColor.black.cgColor)
            ctx.setLineWidth(scene.detailLevel.routeLineWidth + 6)
            ctx.strokePath()
            ctx.addLines(between: points)
            ctx.setStrokeColor(UIColor.white.cgColor)
            ctx.setLineWidth(scene.detailLevel.routeLineWidth)
            ctx.strokePath()
            ctx.restoreGState()
        }

        drawMarker(at: userPoint, radius: 4, filled: true, in: ctx)

        if let maneuver = scene.maneuverCoordinate {
            let maneuverPoint = projector(maneuver)
            if mapRect.insetBy(dx: 4, dy: 4).contains(maneuverPoint) {
                drawMarker(at: maneuverPoint, radius: 3, filled: true, in: ctx)
            }
        }

        let destinationPoint = projector(scene.destinationCoordinate)
        if mapRect.insetBy(dx: 5, dy: 5).contains(destinationPoint) {
            drawMarker(at: destinationPoint, radius: 5, filled: false, in: ctx)
        }
    }

    private func drawMarker(at point: CGPoint, radius: CGFloat, filled: Bool, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fillEllipse(in: CGRect(
            x: point.x - radius - 2,
            y: point.y - radius - 2,
            width: (radius + 2) * 2,
            height: (radius + 2) * 2
        ))

        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        if filled {
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillEllipse(in: rect)
        } else {
            ctx.setStrokeColor(UIColor.white.cgColor)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: rect)
        }
        ctx.restoreGState()
    }

    /// Compact readout mirroring the stock glasses overview: clock, distance to
    /// the next maneuver, remaining time, remaining distance.
    private func drawStatsColumn(scene: NavigationMapScene, layout: Layout, in ctx: CGContext) {
        let clockAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let rowAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: UIColor.white
        ]

        let x = layout.stats.minX
        drawLabel(Self.clockText(), at: CGPoint(x: x, y: 8), attributes: clockAttributes, in: ctx)

        let rows = [
            Self.formattedDistance(scene.distanceToManeuverMeters),
            "\(max(0, scene.remainingMinutes)) min",
            Self.formattedDistance(scene.remainingDistanceMeters)
        ]
        for (index, row) in rows.enumerated() {
            drawLabel(
                row,
                at: CGPoint(x: x, y: 62 + CGFloat(index) * 22),
                attributes: rowAttributes,
                in: ctx
            )
        }
    }

    private func drawInstructionLine(scene: NavigationMapScene, layout: Layout, in ctx: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let maxCharacters = Int(layout.map.width / 7)
        drawLabel(
            truncated(scene.instructionText, maxLength: max(8, maxCharacters)),
            at: CGPoint(x: layout.map.minX, y: 1),
            attributes: attributes,
            in: ctx
        )
    }

    /// Draws text over a black plate so glyphs stay readable where they overlap
    /// the street wireframe.
    private func drawLabel(_ text: String,
                           at origin: CGPoint,
                           attributes: [NSAttributedString.Key: Any],
                           in ctx: CGContext) {
        let string = NSString(string: text)
        let size = string.size(withAttributes: attributes)
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(
            x: origin.x - 2,
            y: origin.y - 1,
            width: size.width + 4,
            height: size.height + 2
        ))
        string.draw(at: origin, withAttributes: attributes)
    }

    // MARK: - Geometry

    private static func layout(for detail: NavigationDisplayDetail) -> Layout {
        let content = G1NavigationBitmapLayout.contentRect(horizontalMargin: detail.horizontalMargin)
        return Layout(
            content: content,
            map: G1NavigationBitmapLayout.mapRect(
                in: content,
                topInset: detail.showsInstructionLine ? 17 : 2
            ),
            stats: G1NavigationBitmapLayout.statsColumnRect(in: content)
        )
    }

    /// Route geometry the frame should cover: the next stretch at head level,
    /// the entire remaining route on head up.
    nonisolated static func routeWindow(for scene: NavigationMapScene) -> [CLLocationCoordinate2D] {
        guard !scene.routeCoordinates.isEmpty else {
            return []
        }
        if let lookAhead = scene.detailLevel.routeLookAheadMeters {
            return visibleRouteCoordinates(
                scene.routeCoordinates,
                from: scene.userCoordinate,
                lookAheadMeters: lookAhead
            )
        }
        return decimate(scene.routeCoordinates, maxPoints: 140)
    }

    private static func projector(layout: Layout,
                                  coordinates: [CLLocationCoordinate2D]) -> (CLLocationCoordinate2D) -> CGPoint {
        guard let bounds = coordinateBounds(for: coordinates) else {
            let center = CGPoint(x: layout.map.midX, y: layout.map.midY)
            return { _ in center }
        }
        let rect = layout.map
        return { coordinate in
            project(coordinate: coordinate, bounds: bounds, into: rect, padding: 10)
        }
    }

    nonisolated private static func packMonochromeBits(from image: CGImage) -> Data? {
        G1MonochromeBitmapPacker.packBits(from: image)
    }

    // MARK: - Formatting

    nonisolated static func clockText(date: Date = Date()) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    nonisolated static func formattedDistance(_ meters: Int) -> String {
        let clamped = max(0, meters)
        if clamped >= 1_000 {
            return String(format: "%.1f km", Double(clamped) / 1_000)
        }
        return "\(clamped) m"
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

    // MARK: - Route helpers

    nonisolated static func remainingRouteCoordinates(route: MKRoute,
                                                        userLocation: CLLocation) -> [CLLocationCoordinate2D] {
        let all = coordinates(from: route.polyline)
        guard !all.isEmpty else {
            return []
        }

        let userPoint = MKMapPoint(userLocation.coordinate)
        var closestIndex = 0
        var closestDistance = CLLocationDistance.greatestFiniteMagnitude

        for index in all.indices {
            let mapPoint = MKMapPoint(all[index])
            let distance = userPoint.distance(to: mapPoint)
            if distance < closestDistance {
                closestDistance = distance
                closestIndex = index
            }
        }

        // Keep route geometry separate from the raw GPS coordinate. Rendering
        // can then snap small GPS errors to the route without mistaking the
        // inserted user point for part of the path.
        return Array(all[closestIndex...])
    }

    nonisolated static func decimate(_ coordinates: [CLLocationCoordinate2D], maxPoints: Int) -> [CLLocationCoordinate2D] {
        guard coordinates.count > maxPoints, maxPoints > 1 else {
            return coordinates
        }

        let step = Double(coordinates.count - 1) / Double(maxPoints - 1)
        return (0..<maxPoints).map { index in
            coordinates[min(coordinates.count - 1, Int(round(Double(index) * step)))]
        }
    }

    /// Keeps the glasses focused on the next part of the walk instead of
    /// compressing the entire remaining journey into a nearly straight line.
    nonisolated static func visibleRouteCoordinates(_ route: [CLLocationCoordinate2D],
                                                    from user: CLLocationCoordinate2D,
                                                    lookAheadMeters: CLLocationDistance) -> [CLLocationCoordinate2D] {
        guard !route.isEmpty else { return [] }

        let userLocation = CLLocation(latitude: user.latitude, longitude: user.longitude)
        let closestIndex = route.indices.min { lhs, rhs in
            let left = CLLocation(latitude: route[lhs].latitude, longitude: route[lhs].longitude)
            let right = CLLocation(latitude: route[rhs].latitude, longitude: route[rhs].longitude)
            return userLocation.distance(from: left) < userLocation.distance(from: right)
        } ?? route.startIndex

        var visible: [CLLocationCoordinate2D] = [route[closestIndex]]
        var travelled: CLLocationDistance = 0
        var previous = route[closestIndex]

        for coordinate in route.dropFirst(closestIndex + 1) {
            let segment = CLLocation(
                latitude: previous.latitude,
                longitude: previous.longitude
            ).distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))

            // Stop exactly at the look-ahead distance. Route vertices sit
            // hundreds of metres apart on long straight avenues, so appending
            // whole segments would overshoot far enough to push the user's own
            // position off the rendered frame.
            if travelled + segment >= lookAheadMeters {
                let remaining = lookAheadMeters - travelled
                let fraction = segment > 0 ? remaining / segment : 0
                visible.append(interpolate(from: previous, to: coordinate, fraction: fraction))
                break
            }

            travelled += segment
            visible.append(coordinate)
            previous = coordinate
        }

        return decimate(visible, maxPoints: 80)
    }

    nonisolated static func interpolate(from start: CLLocationCoordinate2D,
                                       to end: CLLocationCoordinate2D,
                                       fraction: Double) -> CLLocationCoordinate2D {
        let clamped = max(0, min(1, fraction))
        let startPoint = MKMapPoint(start)
        let endPoint = MKMapPoint(end)
        return MKMapPoint(
            x: startPoint.x + (endPoint.x - startPoint.x) * clamped,
            y: startPoint.y + (endPoint.y - startPoint.y) * clamped
        ).coordinate
    }

    /// GPS jitter can place the user dot beside the route even while they are
    /// walking on it. Snap only small errors; large offsets remain visible so a
    /// genuine off-route state is not hidden.
    nonisolated static func displayUserCoordinate(_ user: CLLocationCoordinate2D,
                                                  route: [CLLocationCoordinate2D],
                                                  snapDistanceMeters: CLLocationDistance) -> CLLocationCoordinate2D {
        guard let nearest = nearestCoordinate(on: route, to: user) else {
            return user
        }

        let distance = MKMapPoint(user).distance(to: MKMapPoint(nearest))
        return distance <= snapDistanceMeters ? nearest : user
    }

    nonisolated private static func nearestCoordinate(on route: [CLLocationCoordinate2D],
                                                      to user: CLLocationCoordinate2D) -> CLLocationCoordinate2D? {
        guard let first = route.first else { return nil }
        guard route.count > 1 else { return first }

        let target = MKMapPoint(user)
        var nearestPoint = MKMapPoint(first)
        var nearestDistance = target.distance(to: nearestPoint)

        for (startCoordinate, endCoordinate) in zip(route, route.dropFirst()) {
            let start = MKMapPoint(startCoordinate)
            let end = MKMapPoint(endCoordinate)
            let dx = end.x - start.x
            let dy = end.y - start.y
            let lengthSquared = dx * dx + dy * dy
            let fraction: Double
            if lengthSquared == 0 {
                fraction = 0
            } else {
                fraction = max(0, min(1, ((target.x - start.x) * dx + (target.y - start.y) * dy) / lengthSquared))
            }
            let projected = MKMapPoint(x: start.x + fraction * dx, y: start.y + fraction * dy)
            let distance = target.distance(to: projected)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestPoint = projected
            }
        }

        return nearestPoint.coordinate
    }

    nonisolated private static func project(coordinate: CLLocationCoordinate2D,
                                            bounds: CoordinateBounds,
                                            into rect: CGRect,
                                            padding: CGFloat) -> CGPoint {
        let usable = rect.insetBy(dx: padding, dy: padding)
        let xRatio: CGFloat
        if bounds.maxLon == bounds.minLon {
            xRatio = 0.5
        } else {
            xRatio = CGFloat((coordinate.longitude - bounds.minLon) / (bounds.maxLon - bounds.minLon))
        }

        let yRatio: CGFloat
        if bounds.maxLat == bounds.minLat {
            yRatio = 0.5
        } else {
            yRatio = CGFloat((coordinate.latitude - bounds.minLat) / (bounds.maxLat - bounds.minLat))
        }

        return CGPoint(
            x: usable.minX + xRatio * usable.width,
            y: usable.maxY - yRatio * usable.height
        )
    }

    nonisolated private static func coordinateBounds(for coordinates: [CLLocationCoordinate2D]) -> CoordinateBounds? {
        guard let first = coordinates.first else {
            return nil
        }

        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude

        for coordinate in coordinates.dropFirst() {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }

        let latPadding = max(0.0004, (maxLat - minLat) * 0.15)
        let lonPadding = max(0.0004, (maxLon - minLon) * 0.15)

        return CoordinateBounds(
            minLat: minLat - latPadding,
            maxLat: maxLat + latPadding,
            minLon: minLon - lonPadding,
            maxLon: maxLon + lonPadding
        )
    }

    nonisolated static func coordinates(from polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        guard polyline.pointCount > 0 else {
            return []
        }

        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
        coords.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress {
                polyline.getCoordinates(base, range: NSRange(location: 0, length: polyline.pointCount))
            }
        }
        return coords.filter { CLLocationCoordinate2DIsValid($0) }
    }

    nonisolated static func lastCoordinate(from polyline: MKPolyline) -> CLLocationCoordinate2D? {
        coordinates(from: polyline).last
    }
}

private struct CoordinateBounds {
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double
}
