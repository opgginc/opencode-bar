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
}
