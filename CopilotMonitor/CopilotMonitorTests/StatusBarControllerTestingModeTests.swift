import XCTest
@testable import OpenCode_Bar

@MainActor
final class StatusBarControllerTestingModeTests: XCTestCase {
    private let braveRefreshKey = "searchEngines.brave.refreshMode"
    private let githubStarDismissedKey = "githubStarPromptDismissed"

    // snapshot/restore pair for keys setUp() may need to mutate.
    // Without restore the test would corrupt the developer's real
    // UserDefaults.standard on `removeObject(...)`.
    private var savedBraveRefresh: Any?
    private var savedGithubStarDismissed: Any?
    private var savedBraveRefreshExists: Bool = false
    private var savedGithubStarDismissedExists: Bool = false

    override func setUp() {
        super.setUp()
        // Snapshot existing values so tearDown can restore exactly.
        if let v = UserDefaults.standard.object(forKey: braveRefreshKey) {
            savedBraveRefresh = v
            savedBraveRefreshExists = true
        }
        if let v = UserDefaults.standard.object(forKey: githubStarDismissedKey) {
            savedGithubStarDismissed = v
            savedGithubStarDismissedExists = true
        }
        // Clean slate: erase state that default init() would mutate so we can
        // detect production-style writes to UserDefaults.standard.
        UserDefaults.standard.removeObject(forKey: braveRefreshKey)
        UserDefaults.standard.removeObject(forKey: githubStarDismissedKey)
    }

    override func tearDown() {
        // Restore exactly to pre-test state.
        if savedBraveRefreshExists {
            UserDefaults.standard.set(savedBraveRefresh, forKey: braveRefreshKey)
        } else {
            UserDefaults.standard.removeObject(forKey: braveRefreshKey)
        }
        if savedGithubStarDismissedExists {
            UserDefaults.standard.set(savedGithubStarDismissed, forKey: githubStarDismissedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: githubStarDismissedKey)
        }
        super.tearDown()
    }

    // MARK: - Init with .testing does not pollute UserDefaults.standard

    func testInitWithTestingOptionsDoesNotWriteToUserDefaultsStandard() {
        // Known key that production init touches; expected absence in .standard
        // proves the testing path uses the injected suite instead.
        let suiteName = "B09.test.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        defer { suite.removePersistentDomain(forName: suiteName) }

        _ = StatusBarController(
            options: .testing(userDefaults: suite)
        )

        XCTAssertNil(
            UserDefaults.standard.object(forKey: braveRefreshKey),
            "Testing-mode init must not write braveRefreshKey into UserDefaults.standard"
        )
        XCTAssertNil(
            UserDefaults.standard.object(forKey: githubStarDismissedKey),
            "Testing-mode init must not write githubStarPromptDismissed into UserDefaults.standard"
        )
    }

    // MARK: - Init with .testing writes the default to the injected suite

    func testInitWithTestingOptionsWritesDefaultToInjectedSuite() {
        let suiteName = "B09.test.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        defer { suite.removePersistentDomain(forName: suiteName) }

        _ = StatusBarController(
            options: .testing(userDefaults: suite)
        )

        XCTAssertNotNil(
            suite.object(forKey: braveRefreshKey),
            "Testing-mode init should still populate the braveRefreshKey default — into the injected suite"
        )
    }

    // MARK: - Production options stay observable (back-compat)

    func testProductionOptionsLookLikeCurrentBehavior() {
        XCTAssertTrue(
            StatusBarController.InitOptions.production.runBackgroundTasks,
            "Production options must continue starting background tasks"
        )
        XCTAssertTrue(
            StatusBarController.InitOptions.production.promptGitHubStar,
            "Production options must continue prompting GitHub star"
        )
        XCTAssertEqual(
            StatusBarController.InitOptions.production.userDefaults,
            UserDefaults.standard,
            "Production options should target UserDefaults.standard"
        )
    }
}
