import XCTest
@testable import OpenCode_Bar

/// Regression tests for B07-B15 (test pollution root fix).
/// Verifies that the public test-mode initialization of `StatusBarController`
/// does not write to `UserDefaults.standard`, register timers, or kick off
/// background refreshes.
final class StatusBarControllerTestModeTests: XCTestCase {
    private let githubStarPromptKey = "githubStarPromptDismissed"
    private let braveRefreshModeKey = SearchEnginePreferences.braveRefreshModeKey
    private let refreshIntervalKey = "refreshInterval"
    private let predictionPeriodKey = "predictionPeriod"

    @MainActor
    func testTestModeInitDoesNotWriteBraveRefreshModeDefault() {
        // Clean slate: remove defaults that init might have set on a prior run.
        let originalBraveValue = UserDefaults.standard.object(forKey: braveRefreshModeKey)
        UserDefaults.standard.removeObject(forKey: braveRefreshModeKey)
        defer {
            if let original = originalBraveValue {
                UserDefaults.standard.set(original, forKey: braveRefreshModeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: braveRefreshModeKey)
            }
        }

        _ = StatusBarController(testMode: true)

        XCTAssertNil(
            UserDefaults.standard.object(forKey: braveRefreshModeKey),
            "testMode init must not write BraveSearch refresh-mode default"
        )
    }

    @MainActor
    func testTestModeInitDoesNotShowGitHubStarAlert() {
        // If checkAndPromptGitHubStar were called in testMode and not pre-dismissed,
        // it would present an NSAlert and block the test. We assert by absence: no
        // crash, no alert side-effect, and the dismissed key stays untouched.
        let originalDismissed = UserDefaults.standard.object(forKey: githubStarPromptKey)
        UserDefaults.standard.removeObject(forKey: githubStarPromptKey)
        defer {
            if let original = originalDismissed {
                UserDefaults.standard.set(original, forKey: githubStarPromptKey)
            } else {
                UserDefaults.standard.removeObject(forKey: githubStarPromptKey)
            }
        }

        _ = StatusBarController(testMode: true)

        XCTAssertNil(
            UserDefaults.standard.object(forKey: githubStarPromptKey),
            "testMode init must not flip githubStarPromptDismissed"
        )
    }

    @MainActor
    func testTestModeInitLeavesPeriodicDefaultsUntouched() {
        // Snapshot relevant defaults; verify the test-mode init does not write to them.
        let snapshotKeys = [refreshIntervalKey, predictionPeriodKey]
        var originals: [String: Any?] = [:]
        for key in snapshotKeys {
            originals[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        defer {
            for (key, value) in originals {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }

        _ = StatusBarController(testMode: true)

        for key in snapshotKeys {
            XCTAssertNil(
                UserDefaults.standard.object(forKey: key),
                "testMode init must not write default for \(key)"
            )
        }
    }

    @MainActor
    func testTestModeInitStillProducesUsableMenu() {
        // Sanity check: the menu is still wired up so tests can inspect items.
        let controller = StatusBarController(testMode: true)
        XCTAssertNotNil(controller.topMenuForTesting, "menu must still be created in testMode")
        XCTAssertFalse(controller.providerQuotaOrderForTesting.isEmpty, "quota order must still be populated")
    }
}