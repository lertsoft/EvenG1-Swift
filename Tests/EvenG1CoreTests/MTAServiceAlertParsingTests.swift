import Foundation
import SwiftProtobuf
import XCTest
@testable import EvenG1Core

final class MTAServiceAlertParsingTests: XCTestCase {
    func testDecodesAlertEntityWithRouteEffectAndHeader() throws {
        let now = Int64(1_735_689_600)

        var selector = GTFSProto_EntitySelector()
        selector.routeID = "Q"
        selector.stopID = "R14N"

        var headerTranslation = GTFSProto_TranslatedString_Translation()
        headerTranslation.text = "Downtown delays"
        headerTranslation.language = "en"

        var headerText = GTFSProto_TranslatedString()
        headerText.translation = [headerTranslation]

        var activePeriod = GTFSProto_TimeRange()
        activePeriod.start = UInt64(now - 60)
        activePeriod.end = UInt64(now + 600)

        var alert = GTFSProto_Alert()
        alert.effect = .significantDelays
        alert.informedEntity = [selector]
        alert.headerText = headerText
        alert.activePeriod = [activePeriod]

        var entity = GTFSProto_FeedEntity()
        entity.id = "alert-1"
        entity.alert = alert

        var feed = GTFSProto_FeedMessage()
        feed.entity = [entity]

        let data = try feed.serializedData()
        let decoded = try TransitRealtime_FeedMessage.decode(from: data)

        XCTAssertEqual(decoded.entity.count, 1)
        XCTAssertEqual(decoded.entity.first?.id, "alert-1")
        XCTAssertEqual(decoded.entity.first?.alert?.effect, .significantDelays)
        XCTAssertEqual(decoded.entity.first?.alert?.headerText?.firstText, "Downtown delays")
        XCTAssertEqual(decoded.entity.first?.alert?.informedEntity.first?.routeID, "Q")
        XCTAssertEqual(decoded.entity.first?.alert?.informedEntity.first?.stopID, "R14N")
        XCTAssertEqual(decoded.entity.first?.alert?.activePeriod.first?.start, now - 60)
        XCTAssertEqual(decoded.entity.first?.alert?.activePeriod.first?.end, now + 600)
    }

    func testDecodesMissingHeaderAndDescriptionGracefully() throws {
        var selector = GTFSProto_EntitySelector()
        selector.routeID = "A"

        var alert = GTFSProto_Alert()
        alert.effect = .noService
        alert.informedEntity = [selector]
        alert.headerText = GTFSProto_TranslatedString()
        alert.descriptionText = GTFSProto_TranslatedString()

        var entity = GTFSProto_FeedEntity()
        entity.id = "alert-2"
        entity.alert = alert

        var feed = GTFSProto_FeedMessage()
        feed.entity = [entity]

        let data = try feed.serializedData()
        let decoded = try TransitRealtime_FeedMessage.decode(from: data)

        XCTAssertEqual(decoded.entity.first?.alert?.effect, .noService)
        XCTAssertNil(decoded.entity.first?.alert?.headerText)
        XCTAssertNil(decoded.entity.first?.alert?.descriptionText)
    }

    func testDecodesExpiredAlertActivePeriodForDownstreamFiltering() throws {
        let now = Int64(1_735_689_600)

        var activePeriod = GTFSProto_TimeRange()
        activePeriod.start = UInt64(now - 600)
        activePeriod.end = UInt64(now - 300)

        var alert = GTFSProto_Alert()
        alert.effect = .reducedService
        alert.activePeriod = [activePeriod]

        var entity = GTFSProto_FeedEntity()
        entity.id = "alert-3"
        entity.alert = alert

        var feed = GTFSProto_FeedMessage()
        feed.entity = [entity]

        let data = try feed.serializedData()
        let decoded = try TransitRealtime_FeedMessage.decode(from: data)

        XCTAssertEqual(decoded.entity.first?.alert?.activePeriod.first?.start, now - 600)
        XCTAssertEqual(decoded.entity.first?.alert?.activePeriod.first?.end, now - 300)
    }
}
