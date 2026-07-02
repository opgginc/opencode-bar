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
}
