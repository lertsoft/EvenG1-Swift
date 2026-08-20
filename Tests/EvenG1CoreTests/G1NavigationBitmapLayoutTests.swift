import XCTest
@testable import EvenG1Core

final class G1NavigationBitmapLayoutTests: XCTestCase {
    func testCanvasDimensionsMatchG1BitmapFrame() {
        XCTAssertEqual(G1NavigationBitmapLayout.canvasWidth, G1BitmapFrame.defaultWidth)
        XCTAssertEqual(G1NavigationBitmapLayout.canvasHeight, G1BitmapFrame.defaultHeight)
    }

    func testContentRectIsCenteredWithHorizontalMargins() {
        let rect = G1NavigationBitmapLayout.contentRect

        XCTAssertEqual(rect.minX, G1NavigationBitmapLayout.horizontalMargin)
        XCTAssertEqual(rect.width, CGFloat(G1NavigationBitmapLayout.canvasWidth) - (G1NavigationBitmapLayout.horizontalMargin * 2))
        XCTAssertEqual(rect.height, CGFloat(G1NavigationBitmapLayout.canvasHeight))
    }

    func testCenteredPanelRectIsInsideContentRect() {
        let panel = G1NavigationBitmapLayout.centeredPanelRect(width: 300)

        XCTAssertTrue(G1NavigationBitmapLayout.contentRect.contains(panel))
        XCTAssertEqual(panel.midX, G1NavigationBitmapLayout.contentRect.midX, accuracy: 0.5)
    }

    func testDetailedOverviewGetsAWiderMapSurfaceThanHeadLevel() {
        let headLevel = G1NavigationBitmapLayout.mapRect(
            in: G1NavigationBitmapLayout.contentRect(horizontalMargin: G1NavigationBitmapLayout.horizontalMargin),
            topInset: 17
        )
        let overview = G1NavigationBitmapLayout.mapRect(
            in: G1NavigationBitmapLayout.contentRect(horizontalMargin: G1NavigationBitmapLayout.wideHorizontalMargin),
            topInset: 2
        )

        XCTAssertGreaterThan(overview.width, headLevel.width)
        XCTAssertGreaterThan(overview.height, headLevel.height)
        XCTAssertGreaterThanOrEqual(overview.minX, G1NavigationBitmapLayout.wideHorizontalMargin)
        XCTAssertLessThanOrEqual(overview.maxX, CGFloat(G1NavigationBitmapLayout.canvasWidth))
    }

    func testMapRectLeavesRoomForTheStatsColumn() {
        let content = G1NavigationBitmapLayout.contentRect
        let map = G1NavigationBitmapLayout.mapRect(in: content, topInset: 17)
        let stats = G1NavigationBitmapLayout.statsColumnRect(in: content)

        XCTAssertFalse(map.intersects(stats))
        XCTAssertEqual(map.minX, stats.maxX + G1NavigationBitmapLayout.statsColumnGutter)
    }

    func testStreetMaskThresholdSeparatesRoadsFromBlockFills() {
        // Blocks at level 52 dominate; roads at 74 are the lit minority.
        var histogram = [Int](repeating: 0, count: 256)
        histogram[44] = 500
        histogram[52] = 400
        histogram[74] = 100

        let threshold = G1NavigationBitmapLayout.streetMaskThreshold(histogram: histogram, maximumInkRatio: 0.35)

        XCTAssertNotNil(threshold)
        XCTAssertGreaterThanOrEqual(threshold ?? 0, 52)
        XCTAssertLessThan(threshold ?? 255, 74)
    }

    func testStreetMaskThresholdCapsInkOnLowContrastTiles() {
        // A split that would light up most of the canvas is pulled back to the
        // ink budget so the display does not flood.
        var histogram = [Int](repeating: 0, count: 256)
        histogram[40] = 300
        histogram[80] = 700

        let threshold = G1NavigationBitmapLayout.streetMaskThreshold(histogram: histogram, maximumInkRatio: 0.35)

        XCTAssertNotNil(threshold)
        XCTAssertGreaterThanOrEqual(threshold ?? 0, 80)
    }

    func testStreetMaskThresholdRejectsTilesWithoutStructure() {
        // Open water or a failed tile fetch has a single tone and must not be
        // amplified into noise.
        var histogram = [Int](repeating: 0, count: 256)
        histogram[44] = 1_000
        histogram[45] = 40

        XCTAssertNil(G1NavigationBitmapLayout.streetMaskThreshold(histogram: histogram, maximumInkRatio: 0.35))
    }

    func testInkBudgetThresholdKeepsOnlyTheBrightestShareOfPixels() {
        var histogram = [Int](repeating: 0, count: 256)
        histogram[30] = 900
        histogram[120] = 100

        let threshold = G1NavigationBitmapLayout.inkBudgetThreshold(histogram: histogram, maximumInkRatio: 0.12)

        XCTAssertGreaterThan(threshold, 30)
        XCTAssertLessThanOrEqual(threshold, 120)
    }

    func testValidatesExactCanvasDimensions() {
        XCTAssertTrue(G1NavigationBitmapLayout.validatesCanvasDimensions(
            width: G1NavigationBitmapLayout.canvasWidth,
            height: G1NavigationBitmapLayout.canvasHeight
        ))
        XCTAssertFalse(G1NavigationBitmapLayout.validatesCanvasDimensions(width: 575, height: 135))
        XCTAssertFalse(G1NavigationBitmapLayout.validatesCanvasDimensions(width: 576, height: 134))
    }
}

final class G1BitmapTransferTests: XCTestCase {
    func testAckSendOrderPrefersLeftThenRightForBroadcast() {
        XCTAssertEqual(G1BluetoothManager.ackSendOrder(for: nil), [.left, .right])
    }

    func testFullNavigationFrameProducesFiftyOneChunks() throws {
        let packedBytesPerRow = (G1BitmapFrame.defaultWidth + 7) / 8
        let payload = Data(repeating: 0x00, count: packedBytesPerRow * G1BitmapFrame.defaultHeight)
        let frame = try G1BitmapFrame(
            width: G1BitmapFrame.defaultWidth,
            height: G1BitmapFrame.defaultHeight,
            bitPackedRows: payload
        )

        let envelope = try G1BitmapPacketBuilder().buildPackets(for: frame)
        XCTAssertEqual(envelope.dataPackets.count, 51)
    }

    func testCenterLineGoldenFrameEncodesVerticalMarker() throws {
        let width = G1BitmapFrame.defaultWidth
        let height = G1BitmapFrame.defaultHeight
        let packedBytesPerRow = (width + 7) / 8
        var rows = Data(repeating: 0x00, count: packedBytesPerRow * height)

        let centerX = width / 2
        let centerByte = centerX / 8
        let centerBit = UInt8(0x80 >> (centerX % 8))
        for row in 0..<height {
            rows[(row * packedBytesPerRow) + centerByte] = centerBit
        }

        let frame = try G1BitmapFrame(width: width, height: height, bitPackedRows: rows)
        let envelope = try G1BitmapPacketBuilder().buildPackets(for: frame)

        XCTAssertEqual(envelope.dataPackets.first?.prefix(2), Data([G1Command.BMP_DATA.rawValue, 0x00]))
        XCTAssertEqual(envelope.endPacket, Data([G1Command.BMP_END.rawValue, 0x0D, 0x0E]))
    }
}

final class G1LatestValueCoalescerTests: XCTestCase {
    func testCoalescerRetainsOnlyLatestPendingValue() {
        var coalescer = G1LatestValueCoalescer<Int>()
        XCTAssertTrue(coalescer.beginDrain())

        coalescer.submit(1)
        coalescer.submit(2)
        coalescer.submit(3)

        XCTAssertEqual(coalescer.nextPending(), 3)
        XCTAssertNil(coalescer.nextPending())

        coalescer.finishDrain()
        XCTAssertFalse(coalescer.isDraining)
    }

    func testConcurrentSubmissionsDoNotStartSecondDrain() {
        var coalescer = G1LatestValueCoalescer<String>()
        XCTAssertTrue(coalescer.beginDrain())
        XCTAssertFalse(coalescer.beginDrain())

        coalescer.submit("latest")
        coalescer.finishDrain()

        XCTAssertTrue(coalescer.beginDrain())
        XCTAssertEqual(coalescer.nextPending(), "latest")
    }
}
