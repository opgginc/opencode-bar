import XCTest
@testable import OpenCode_Bar

final class StatusBarControllerTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!

    @MainActor
    override func setUp() {
        super.setUp()
        // B09: use the new injection seam so init() does not start
        // background tasks / GitHub star prompts / write UserDefaults.standard.
        suiteName = "StatusBarControllerTests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    override func tearDown() {
        // Defensive: drop the suite even if the test threw mid-flight.
        if let suite, let suiteName {
            suite.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    @MainActor
    func testTopLevelMenuContainsOnlyRefreshAndSettings() {
        let controller = StatusBarController(options: .testing(userDefaults: suite))
        guard let menu = controller.topMenuForTesting else {
            XCTFail("顶层菜单未创建")
            return
        }

        let titles = menu.items
            .filter { !$0.isSeparatorItem }
            .map { $0.title }

        XCTAssertEqual(titles, ["刷新", "设置"], "初始化后顶层菜单应只保留「刷新」和「设置」")
    }

    @MainActor
    func testUnconfiguredCopilotErrorAppearsInUnconfiguredSubmenu() {
        let controller = StatusBarController(options: .testing(userDefaults: suite))
        controller.injectProviderStateForTesting(
            results: [
                .synthetic: ProviderResult(
                    usage: .quotaBased(remaining: 100, entitlement: 100, overagePermitted: false),
                    details: nil
                )
            ],
            errors: [.copilot: "Authentication failed: GitHub Copilot token not found"],
            loading: []
        )

        guard let menu = controller.topMenuForTesting else {
            XCTFail("顶层菜单未创建")
            return
        }

        let unconfiguredItem = menu.items.first {
            $0.title.hasPrefix("尚未配置")
        }
        XCTAssertNotNil(unconfiguredItem, "应存在「尚未配置」子菜单")

        guard let submenu = unconfiguredItem?.submenu else {
            XCTFail("「尚未配置」项应有子菜单")
            return
        }

        let copilotItem = submenu.items.first {
            $0.title.contains("GitHub Copilot") && $0.title.contains("点击配置")
        }
        XCTAssertNotNil(copilotItem, "尚未配置子菜单中应包含 Copilot 的「点击配置」入口")
    }

    @MainActor
    func testUnconfiguredOpenCodeZenErrorAppearsInUnconfiguredSubmenu() {
        let controller = StatusBarController(options: .testing(userDefaults: suite))
        controller.injectProviderStateForTesting(
            results: [
                .synthetic: ProviderResult(
                    usage: .quotaBased(remaining: 100, entitlement: 100, overagePermitted: false),
                    details: nil
                )
            ],
            errors: [.openCodeZen: "Authentication failed: OpenCode CLI is not authenticated. Run `opencode login` first."],
            loading: []
        )

        guard let menu = controller.topMenuForTesting else {
            XCTFail("顶层菜单未创建")
            return
        }

        let unconfiguredItem = menu.items.first {
            $0.title.hasPrefix("尚未配置")
        }
        XCTAssertNotNil(unconfiguredItem, "应存在「尚未配置」子菜单")

        guard let submenu = unconfiguredItem?.submenu else {
            XCTFail("「尚未配置」项应有子菜单")
            return
        }

        let openCodeZenItem = submenu.items.first {
            $0.title.contains("OpenCode Zen") && $0.title.contains("点击配置")
        }
        XCTAssertNotNil(openCodeZenItem, "尚未配置子菜单中应包含 OpenCode Zen 的「点击配置」入口")
    }

    @MainActor
    func testOpenCodeZenCLIAuthHintAppearsInUnconfiguredSubmenuEvenWhenProviderError() {
        let controller = StatusBarController(options: .testing(userDefaults: suite))
        // Simulate the edge case where the CLI output reaches the UI as a providerError
        // but still contains an unmistakable auth/login hint.
        controller.injectProviderStateForTesting(
            results: [
                .synthetic: ProviderResult(
                    usage: .quotaBased(remaining: 100, entitlement: 100, overagePermitted: false),
                    details: nil
                )
            ],
            errors: [.openCodeZen: "Provider error: OpenCode CLI failed with exit code 1: Unauthorized. Run opencode login."],
            loading: []
        )

        guard let menu = controller.topMenuForTesting else {
            XCTFail("顶层菜单未创建")
            return
        }

        let unconfiguredItem = menu.items.first {
            $0.title.hasPrefix("尚未配置")
        }
        XCTAssertNotNil(unconfiguredItem, "应存在「尚未配置」子菜单")

        guard let submenu = unconfiguredItem?.submenu else {
            XCTFail("「尚未配置」项应有子菜单")
            return
        }

        let openCodeZenItem = submenu.items.first {
            $0.title.contains("OpenCode Zen") && $0.title.contains("点击配置")
        }
        XCTAssertNotNil(openCodeZenItem, "OpenCode Zen 的 auth hint 应被识别为未配置，显示在「尚未配置」子菜单")
    }

    // MARK: - F2b UI

    @MainActor
    private func makeController() -> StatusBarController {
        StatusBarController(options: .testing(userDefaults: suite))
    }

    private func sampleProviderResult() -> ProviderResult {
        ProviderResult(
            usage: .quotaBased(remaining: 10, entitlement: 100, overagePermitted: false),
            details: nil
        )
    }

    private func sampleMonthlyTotal(
        provider: String = "kimi",
        cost: Double = 12.345,
        hasUnknownPricing: Bool = false
    ) -> MonthlyTotal {
        MonthlyTotal(
            provider: provider,
            modelBreakdown: [],
            totalTokens: TokenBreakdown(input: 1000, output: 500),
            totalCostRMB: cost,
            hasUnknownPricing: hasUnknownPricing
        )
    }

    /// Header items render their text inside `item.view` instead of `item.title`.
    private func visibleStrings(in item: NSMenuItem) -> [String] {
        guard let view = item.view else { return [item.title] }
        return extractStrings(from: view)
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

    @MainActor
    func testMonthlyAggregatesSectionHiddenWhenCacheEmpty() {
        let controller = makeController()
        controller.injectProviderStateForTesting(results: [.synthetic: sampleProviderResult()])

        let allStrings = controller.topMenuForTesting?.items.flatMap(visibleStrings) ?? []
        XCTAssertFalse(allStrings.contains(where: { $0.contains("本月 API 折算") }), "缓存为空时不应显示 F2b 汇总标题")
    }

    @MainActor
    func testMonthlyAggregatesSectionShownWhenCacheHasData() {
        let controller = makeController()
        controller.injectProviderStateForTesting(results: [.synthetic: sampleProviderResult()])

        let totals = [
            sampleMonthlyTotal(provider: "kimi", cost: 12.345),
            sampleMonthlyTotal(provider: "claude", cost: 5.5)
        ]
        controller.injectMonthlyTotalsForTesting(totals)

        guard let menu = controller.topMenuForTesting else {
            XCTFail("顶层菜单未创建")
            return
        }

        let allStrings = menu.items.flatMap(visibleStrings)
        XCTAssertTrue(allStrings.contains(where: { $0.contains("本月 API 折算") }), "应显示 F2b 汇总标题")

        let aggregateRows = menu.items.filter { $0.title.contains("token") }
        XCTAssertEqual(aggregateRows.count, totals.count, "应显示与缓存数量相同的 provider 行")

        let kimis = aggregateRows.filter { $0.title.contains("Kimi") }
        XCTAssertEqual(kimis.count, 1, "应有一行 Kimi")
        XCTAssertTrue(kimis.first?.title.contains("¥12.35") ?? false, "Kimi 行应使用 CurrencyFormatter 显示 ¥12.35")
    }

    @MainActor
    func testMonthlyAggregatesUnknownPricingHint() {
        let controller = makeController()
        controller.injectProviderStateForTesting(results: [.synthetic: sampleProviderResult()])

        let total = sampleMonthlyTotal(provider: "kimi", cost: 10, hasUnknownPricing: true)
        controller.injectMonthlyTotalsForTesting([total])

        let item = controller.topMenuForTesting?.items.first {
            $0.title.contains("Kimi")
        }
        XCTAssertNotNil(item, "应显示 Kimi 行")
        XCTAssertTrue(item!.title.contains("*"), "未知定价时 title 应追加 *")
        XCTAssertEqual(item!.toolTip, "部分模型无公开定价，总额可能偏低", "应设置 tooltip 提示用户")
    }

    @MainActor
    func testShareSnapshotIncludesMonthlyAPIConversion() {
        let controller = makeController()
        controller.injectProviderStateForTesting(results: [.synthetic: sampleProviderResult()])

        let total = sampleMonthlyTotal(provider: "kimi", cost: 123.456)
        controller.injectMonthlyTotalsForTesting([total])

        guard let text = controller.buildUsageShareSnapshotTextForTesting() else {
            XCTFail("分享快照不应为空")
            return
        }
        XCTAssertTrue(text.contains("本月 API 折算：¥123.46"), "快照应包含 F2b 本月 API 折算行")
    }

    @MainActor
    func testF2bProviderMapping() {
        let controller = makeController()
        XCTAssertEqual(controller.f2bProviderRaw(for: .kimi), "kimi")
        XCTAssertEqual(controller.f2bProviderRaw(for: .kimiCN), "kimi")
        XCTAssertEqual(controller.f2bProviderRaw(for: .claude), "claude")
        XCTAssertEqual(controller.f2bProviderRaw(for: .codex), "codex")
        XCTAssertEqual(controller.f2bProviderRaw(for: .zaiCodingPlan), "zai")
        XCTAssertEqual(controller.f2bProviderRaw(for: .nanoGpt), "nanogpt")
        XCTAssertNil(controller.f2bProviderRaw(for: .openRouter))
        XCTAssertNil(controller.f2bProviderRaw(for: .copilot))
    }

    @MainActor
    func testCurrencyFormatterRMBFormatting() {
        let controller = makeController()
        XCTAssertEqual(controller.currencyFormatter.format(amount: 12.3, as: .rmb), "¥12.30")
        XCTAssertEqual(controller.currencyFormatter.format(amount: 0, as: .rmb), "¥0.00")
    }
}
