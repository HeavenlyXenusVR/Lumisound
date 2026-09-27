import XCTest
@testable import Lumisound

final class HomeHubLayoutStoreTests: XCTestCase {

    func testDefaultOrderListsEveryCaseOnce() {
        let order = HubSectionKind.defaultOrder
        XCTAssertEqual(order.count, HubSectionKind.allCases.count)
        XCTAssertEqual(Set(order), Set(HubSectionKind.allCases))
    }

    func testDefaultOrderKeepsEachZoneTogether() {
        // Zone headings on Home only show while every zone is one unbroken
        // run, so the default must satisfy that.
        let zones = HubSectionKind.defaultOrder.map(\.zone)
        var seen: [HubZone] = []
        for zone in zones where seen.last != zone {
            XCTAssertFalse(seen.contains(zone), "\(zone) is split in defaultOrder")
            seen.append(zone)
        }
        XCTAssertEqual(seen, HubZone.allCases)
    }

    func testEmptyStorageDecodesToDefaultOrder() {
        XCTAssertEqual(HomeHubLayoutStore.decodeOrder(""), HubSectionKind.defaultOrder)
        XCTAssertEqual(HomeHubLayoutStore.decodeOrder("not json"), HubSectionKind.defaultOrder)
    }

    func testSavedOrderRoundTrips() {
        let custom = HubSectionKind.defaultOrder.reversed().map { $0 }
        let json = HomeHubLayoutStore.encodeOrder(custom)
        XCTAssertEqual(HomeHubLayoutStore.decodeOrder(json), custom)
    }

    func testMissingCaseIsInsertedAfterItsDefaultPredecessor() {
        // A layout saved before `stations` existed: it should land right
        // after Aria's Daily Pick, not at the end of the list.
        var legacy = HubSectionKind.defaultOrder.filter { $0 != .stations }
        legacy.swapAt(0, legacy.count - 1)
        let decoded = HomeHubLayoutStore.decodeOrder(HomeHubLayoutStore.encodeOrder(legacy))

        let aria = try XCTUnwrap(decoded.firstIndex(of: .ariaDailyPick))
        XCTAssertEqual(decoded[aria + 1], .stations)
        XCTAssertEqual(decoded.count, HubSectionKind.allCases.count)
    }

    func testMissingFirstCaseGoesToTheTop() {
        let legacy = HubSectionKind.defaultOrder.filter { $0 != .jumpBackIn }
        let decoded = HomeHubLayoutStore.decodeOrder(HomeHubLayoutStore.encodeOrder(legacy))
        XCTAssertEqual(decoded.first, .jumpBackIn)
    }

    func testUnknownAndDuplicateValuesAreDropped() {
        let json = #"["speedDial","removedSection","speedDial"]"#
        let decoded = HomeHubLayoutStore.decodeOrder(json)
        XCTAssertEqual(decoded.filter { $0 == .speedDial }.count, 1)
        XCTAssertEqual(Set(decoded), Set(HubSectionKind.allCases))
    }

    func testTimeOfDayOrdersKeepEveryCaseAndZoneRuns() {
        for hour in 0..<24 {
            let order = HomeHubLayoutStore.defaultOrder(forHour: hour)
            XCTAssertEqual(order.count, HubSectionKind.allCases.count, "hour \(hour)")
            XCTAssertEqual(Set(order), Set(HubSectionKind.allCases), "hour \(hour)")
            var seen: [HubZone] = []
            for zone in order.map(\.zone) where seen.last != zone {
                XCTAssertFalse(seen.contains(zone), "\(zone) is split at hour \(hour)")
                seen.append(zone)
            }
        }
    }

    func testMorningLeadsWithMadeForYou() {
        XCTAssertEqual(HomeHubLayoutStore.defaultOrder(forHour: 8).first?.zone, .forYou)
        XCTAssertEqual(HomeHubLayoutStore.defaultOrder(forHour: 14), HubSectionKind.defaultOrder)
    }

    func testNightLeadsLibraryWithMoods() {
        let order = HomeHubLayoutStore.defaultOrder(forHour: 23)
        XCTAssertEqual(order.first { $0.zone == .library }, .moods)
    }

    func testSavedOrderIgnoresTimeOfDay() {
        let json = HomeHubLayoutStore.encodeOrder(HubSectionKind.defaultOrder)
        XCTAssertEqual(HomeHubLayoutStore.resolvedOrder(json, hour: 8), HubSectionKind.defaultOrder)
    }
}
