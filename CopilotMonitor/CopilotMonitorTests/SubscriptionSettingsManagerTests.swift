import XCTest
@testable import OpenCode_Bar

final class SubscriptionSettingsManagerTests: XCTestCase {
    private var suiteName: String = ""
    private var defaults: UserDefaults = .standard
    private var manager: SubscriptionSettingsManager = .shared

    override func setUp() {
        super.setUp()
        suiteName = "SubscriptionSettingsManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        manager = SubscriptionSettingsManager(userDefaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Isolated UserDefaults

    func testInjectedManagerDoesNotPolluteSharedDefaults() {
        // Set a value via injected manager — should NOT appear in .standard
        manager.setPlan(.preset("Plus", 20), forKey: "minimax_coding_plan.test@example.com")

        XCTAssertNil(UserDefaults.standard.data(forKey: "subscription_v2.minimax_coding_plan.test@example.com"),
                     "Injected manager must not write to UserDefaults.standard")
    }

    func testInjectedManagerReadsBackOwnWrites() {
        manager.setPlan(.preset("Max", 50), forKey: "minimax_coding_plan.test@example.com")
        let plan = manager.getPlan(forKey: "minimax_coding_plan.test@example.com")
        XCTAssertEqual(plan, .preset("Max", 50))
    }

    func testInjectedManagerDoesNotReadSharedDefaults() {
        // Write via .shared (polutes .standard)
        let sharedKey = "minimax_coding_plan.shared-test@example.com"
        SubscriptionSettingsManager.shared.setPlan(.preset("Plus", 20), forKey: sharedKey)
        defer { SubscriptionSettingsManager.shared.removePlan(forKey: sharedKey) }

        // Injected manager should NOT see this
        XCTAssertEqual(manager.getPlan(forKey: sharedKey), .none,
                       "Injected manager must not read from UserDefaults.standard")
    }

    func testForTestingFactoryReturnsIsolatedInstance() {
        let (testManager, testDefaults) = SubscriptionSettingsManager.forTesting()
        testManager.setPlan(.preset("Max", 50), forKey: "claude.test@example.com")

        XCTAssertEqual(testManager.getPlan(forKey: "claude.test@example.com"), .preset("Max", 50))
        // The factory's defaults should contain the written data
        XCTAssertNotNil(testDefaults.data(forKey: "subscription_v2.claude.test@example.com"))
    }

    // MARK: - Original shared behavior preserved

    func testSharedInstanceStillUsesStandardDefaults() {
        let shared = SubscriptionSettingsManager.shared
        // Sanity check that .shared writes to .standard
        let bareKey = "minimax_coding_plan.shared-probe-\(UUID().uuidString)"
        let probeKey = "subscription_v2.\(bareKey)"
        defer {
            shared.removePlan(forKey: bareKey)
            UserDefaults.standard.removeObject(forKey: probeKey)
        }

        shared.setPlan(.preset("Plus", 20), forKey: bareKey)

        XCTAssertNotNil(UserDefaults.standard.data(forKey: probeKey),
                        ".shared must continue to use UserDefaults.standard")
    }
}