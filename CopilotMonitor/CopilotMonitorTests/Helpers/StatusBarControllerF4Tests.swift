import XCTest
import AppKit
@testable import OpenCode_Bar

/// F4: "全局统计" submenu renders today / week / month token totals + quota reference.
@MainActor
final class StatusBarControllerF4Tests: XCTestCase {

    func testF4SubmenuRendersTodayWeekMonth() {
        let submenu = StatusBarController.createGlobalStatsSubmenu(
            snapshot: TokenStatsAggregator.Snapshot(
                todayTotal: TokenBreakdown(input: 1500),
                weekTotal: TokenBreakdown(input: 12000),
                monthTotal: TokenBreakdown(input: 50_000, output: 20_000)
            )
        )
        let texts = extractText(from: submenu)
        XCTAssertTrue(texts.contains(where: { $0.contains("Token 用量汇总") }), "Token 用量汇总 header missing in \(texts)")
        XCTAssertTrue(texts.contains(where: { $0.contains("今日：") }), "今日 row missing in \(texts)")
        XCTAssertTrue(texts.contains(where: { $0.contains("本周：") }), "本周 row missing in \(texts)")
        XCTAssertTrue(texts.contains(where: { $0.contains("本月：") }), "本月 row missing in \(texts)")
    }

    func testF4SubmenuContainsQuotaSection() {
        let submenu = StatusBarController.createGlobalStatsSubmenu(
            snapshot: TokenStatsAggregator.Snapshot(
                todayTotal: TokenBreakdown.zero,
                weekTotal: TokenBreakdown.zero,
                monthTotal: TokenBreakdown.zero
            )
        )
        let texts = extractText(from: submenu)
        XCTAssertTrue(texts.contains(where: { $0.contains("额度状态") }), "额度状态 header missing in \(texts)")
    }

    func testF4SubmenuStructure() {
        // Expected structure: 1 token header + 3 token rows + 1 separator + 1 quota header + 1 quota row = 7 items
        let submenu = StatusBarController.createGlobalStatsSubmenu(
            snapshot: TokenStatsAggregator.Snapshot(
                todayTotal: TokenBreakdown.zero,
                weekTotal: TokenBreakdown.zero,
                monthTotal: TokenBreakdown.zero
            )
        )
        XCTAssertEqual(submenu.items.count, 7, "Expected 7 items; got \(submenu.items.count)")
    }

    private func extractText(from menu: NSMenu) -> [String] {
        var results: [String] = []
        for item in menu.items {
            if let view = item.view {
                results.append(contentsOf: extractStrings(from: view))
            }
        }
        return results
    }

    private func extractStrings(from view: NSView) -> [String] {
        var results = [String]()
        if let textField = view as? NSTextField {
            results.append(textField.stringValue)
        }
        for subview in view.subviews {
            results.append(contentsOf: extractStrings(from: subview))
        }
        return results
    }
}
