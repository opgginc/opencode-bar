import XCTest
@testable import OpenCode_Bar

@MainActor
final class DetailSubmenuOpenCodeTests: XCTestCase {
    private var suiteName: String = ""
    private var suite: UserDefaults!
    private var controller: StatusBarController!

    override func setUp() {
        super.setUp()
        suiteName = "B17.test.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        controller = StatusBarController(options: .testing(userDefaults: suite))
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        controller = nil
        super.tearDown()
    }

    // MARK: - B17: .openCode / .tavilySearch / .braveSearch get explicit cases

    func testOpenCodeWithCreditsShowsLimitAndUsedRows() {
        let details = DetailedUsage(
            monthlyUsage: 12.34,
            limit: 100.0,
            limitRemaining: 87.66,
            mcpUsagePercent: 12.34
        )

        let submenu = controller.createDetailSubmenu(details, identifier: .openCode)

        let texts = collectAllLabelTexts(in: submenu)
        XCTAssertTrue(
            texts.contains(where: { $0.contains("Credits") && $0.contains("100") }),
            "openCode submenu should show the used/total credits row, got: \(texts)"
        )
        XCTAssertTrue(
            texts.contains(where: { $0 == "Used" }),
            "openCode submenu should show a 'Used' label from createUsageWindowRow, got: \(texts)"
        )
    }

    func testOpenCodeWithoutDetailsShowsFallbackNote() {
        let details = DetailedUsage()

        let submenu = controller.createDetailSubmenu(details, identifier: .openCode)

        let texts = collectAllLabelTexts(in: submenu)
        XCTAssertTrue(
            texts.contains(where: { $0.contains("OpenCode pay-as-you-go") || $0.contains("usage unavailable") }),
            "openCode submenu should show a fallback note when no usage details are available, got: \(texts)"
        )
    }

    func testTavilySearchShowsMonthlyUsageAndQuotaRows() {
        let details = DetailedUsage(
            monthlyUsage: 250.0,
            limit: 1000.0,
            limitRemaining: 750.0,
            mcpUsagePercent: 25.0
        )

        let submenu = controller.createDetailSubmenu(details, identifier: .tavilySearch)

        let texts = collectAllLabelTexts(in: submenu)
        XCTAssertTrue(
            texts.contains(where: { $0 == "Monthly" }),
            "tavilySearch submenu should show the Monthly label, got: \(texts)"
        )
        XCTAssertTrue(
            texts.contains(where: { $0.contains("Quota") && $0.contains("1,000") }),
            "tavilySearch submenu should show the Quota used/total row, got: \(texts)"
        )
        XCTAssertTrue(
            texts.contains(where: { $0.contains("剩余额度") }),
            "tavilySearch submenu should show the remaining credits row, got: \(texts)"
        )
    }

    func testBraveSearchShowsMonthlyUsageAndQuotaRows() {
        let details = DetailedUsage(
            monthlyUsage: 8000.0,
            limit: 20000.0,
            limitRemaining: 12000.0,
            mcpUsagePercent: 40.0
        )

        let submenu = controller.createDetailSubmenu(details, identifier: .braveSearch)

        let texts = collectAllLabelTexts(in: submenu)
        XCTAssertTrue(
            texts.contains(where: { $0 == "Monthly" }),
            "braveSearch submenu should show the Monthly label, got: \(texts)"
        )
        XCTAssertTrue(
            texts.contains(where: { $0.contains("Quota") && $0.contains("20,000") }),
            "braveSearch submenu should show the Quota used/total row with proper formatting, got: \(texts)"
        )
    }

    func testTavilySearchWithoutDetailsShowsFallbackNote() {
        let details = DetailedUsage()

        let submenu = controller.createDetailSubmenu(details, identifier: .tavilySearch)

        let texts = collectAllLabelTexts(in: submenu)
        XCTAssertTrue(
            texts.contains(where: { $0.lowercased().contains("usage data unavailable") }),
            "tavilySearch submenu should show a fallback note when no usage details are available, got: \(texts)"
        )
    }

    func testBraveSearchWithoutDetailsShowsFallbackNote() {
        let details = DetailedUsage()

        let submenu = controller.createDetailSubmenu(details, identifier: .braveSearch)

        let texts = collectAllLabelTexts(in: submenu)
        XCTAssertTrue(
            texts.contains(where: { $0.lowercased().contains("usage data unavailable") }),
            "braveSearch submenu should show a fallback note when no usage details are available, got: \(texts)"
        )
    }

    // MARK: - Helpers

    private func collectAllLabelTexts(in menu: NSMenu) -> [String] {
        var texts: [String] = []
        for item in menu.items {
            if let customView = item.view {
                texts.append(contentsOf: extractLabelTexts(from: customView))
            }
        }
        return texts
    }

    private func extractLabelTexts(from view: NSView) -> [String] {
        var texts: [String] = []
        if let label = view as? NSTextField {
            let value = label.stringValue
            if !value.isEmpty {
                texts.append(value)
            }
        }
        for sub in view.subviews {
            texts.append(contentsOf: extractLabelTexts(from: sub))
        }
        return texts
    }
}
