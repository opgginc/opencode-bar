import XCTest
@testable import OpenCode_Bar

final class MenuBarDisplayModeTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(MenuBarDisplayMode.defaultMode.rawValue, 0)
        XCTAssertEqual(MenuBarDisplayMode.iconOnly.rawValue, 1)
        XCTAssertEqual(MenuBarDisplayMode.totalCost.rawValue, 2)
        XCTAssertEqual(MenuBarDisplayMode.singleProvider.rawValue, 3)
    }

    func testTitles() {
        XCTAssertEqual(MenuBarDisplayMode.defaultMode.title, "Default")
        XCTAssertEqual(MenuBarDisplayMode.iconOnly.title, "Icon Only")
        XCTAssertEqual(MenuBarDisplayMode.totalCost.title, "Total Cost")
        XCTAssertEqual(MenuBarDisplayMode.singleProvider.title, "Single Provider")
    }

    func testAllCasesCount() {
        XCTAssertEqual(MenuBarDisplayMode.allCases.count, 4)
    }

    func testDefaultMode() {
        XCTAssertEqual(MenuBarDisplayMode.defaultMode_, .defaultMode)
    }

    func testInitFromRawValue() {
        XCTAssertEqual(MenuBarDisplayMode(rawValue: 0), .defaultMode)
        XCTAssertEqual(MenuBarDisplayMode(rawValue: 1), .iconOnly)
        XCTAssertEqual(MenuBarDisplayMode(rawValue: 2), .totalCost)
        XCTAssertEqual(MenuBarDisplayMode(rawValue: 3), .singleProvider)
        XCTAssertNil(MenuBarDisplayMode(rawValue: 99))
    }

    func testUserDefaultsKeys() {
        XCTAssertEqual(MenuBarDisplayMode.userDefaultsKey, "menuBarDisplayMode")
        XCTAssertEqual(MenuBarDisplayMode.providerKey, "menuBarDisplayProvider")
    }
}
