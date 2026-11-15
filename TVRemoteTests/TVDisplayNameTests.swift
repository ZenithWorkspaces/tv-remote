import XCTest
@testable import TVRemote

final class TVDisplayNameTests: XCTestCase {
    func testLGManufacturerNameBecomesLGTv() {
        XCTAssertEqual(
            TVDisplayName.suggestion(brand: .lg, discovered: "[LG] webOS TV UQ7590PUB"),
            "LG TV"
        )
    }

    func testRokuKeepsAHumanDeviceName() {
        XCTAssertEqual(TVDisplayName.suggestion(brand: .roku, discovered: "Living Room"), "Living Room")
        XCTAssertEqual(TVDisplayName.suggestion(brand: .roku, discovered: nil), "Roku TV")
        XCTAssertEqual(TVDisplayName.suggestion(brand: .roku, discovered: "Roku"), "Roku TV")
    }

    func testTechnicalDiscoveryStringsAreNotNames() {
        XCTAssertTrue(TVDisplayName.looksTechnical("amzn.dmgr:82ab"))
        XCTAssertEqual(TVDisplayName.suggestion(brand: .lg, discovered: "amzn.dmgr:82ab"), "LG TV")
        XCTAssertFalse(TVDisplayName.isPersonalName("urn:lge-com:service:webos-second-screen:1"))
    }

    func testDuplicatesGetANumber() {
        XCTAssertEqual(TVDisplayName.unique("LG TV", taken: ["LG TV"]), "LG TV 2")
        XCTAssertEqual(TVDisplayName.unique("LG TV", taken: ["LG TV", "LG TV 2"]), "LG TV 3")
    }

    func testShortcutOrderAndHiding() {
        let layout = ShortcutLayout.standard
            .moving("spotify", before: "netflix")
            .setting("hulu", hidden: true)
        XCTAssertEqual(layout.visibleShortcuts().first?.slug, "spotify")
        XCTAssertFalse(layout.visibleShortcuts().contains { $0.slug == "hulu" })
        XCTAssertEqual(layout.hiddenShortcuts().map(\.slug), ["hulu"])
        let shown = layout.setting("hulu", hidden: false)
        XCTAssertTrue(shown.visibleShortcuts().contains { $0.slug == "hulu" })
    }
}
