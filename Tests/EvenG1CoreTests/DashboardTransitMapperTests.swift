import XCTest
@testable import EvenG1Core

final class DashboardTransitMapperTests: XCTestCase {
    func testMapsRowsWithShortDirections() {
        let trains = [
            MTANextTrainResult(
                stationID: "R01",
                stationName: "Times Sq",
                distanceMeters: 100,
                routeID: "N",
                direction: "Northbound",
                arrivalTime: Date(),
                minutesAway: 3
            ),
            MTANextTrainResult(
                stationID: "R01",
                stationName: "Times Sq",
                distanceMeters: 100,
                routeID: "Q",
                direction: "Southbound",
                arrivalTime: Date(),
                minutesAway: 0
            )
        ]

        let rows = DashboardTransitMapper.rows(from: trains)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].routeID, "N")
        XCTAssertEqual(rows[0].direction, "N")
        XCTAssertEqual(rows[0].minutesAway, 3)
        XCTAssertEqual(rows[1].direction, "S")
    }

    func testShortDirectionLabels() {
        XCTAssertEqual(DashboardTransitMapper.shortDirection("Northbound"), "N")
        XCTAssertEqual(DashboardTransitMapper.shortDirection("Eastbound"), "E")
    }
}
