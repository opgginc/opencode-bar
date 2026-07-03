import XCTest
@testable import OpenCode_Bar

final class StatusBarControllerTests: XCTestCase {
    @MainActor
    func testTopLevelMenuContainsOnlyRefreshAndSettings() {
        UserDefaults.standard.set(true, forKey: "githubStarPromptDismissed")

        let controller = StatusBarController()
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
        UserDefaults.standard.set(true, forKey: "githubStarPromptDismissed")

        let controller = StatusBarController()
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
        UserDefaults.standard.set(true, forKey: "githubStarPromptDismissed")

        let controller = StatusBarController()
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
        UserDefaults.standard.set(true, forKey: "githubStarPromptDismissed")

        let controller = StatusBarController()
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
