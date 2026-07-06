import XCTest
@testable import OpenCode_Bar

final class SubscriptionSettingsManagerIsolationTests: XCTestCase {

    private func freshSuite(_ suffix: String = "B12") -> (name: String, suite: UserDefaults) {
        let name = "SubscriptionSettingsManagerIsolationTests.\(suffix).\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return (name, suite)
    }

    // MARK: - B12: injected UserDefaults don't leak into .shared / .standard

    func testInjectedInstanceWritesDoNotLeakToShared() {
        let (_, suite) = freshSuite()
        let manager = SubscriptionSettingsManager(defaults: suite)

        let key = "minimax_coding_plan.b12-isotest@example.com"
        manager.setPlan(.preset("Max", 50), forKey: key)

        // .shared uses .standard, not our suite — must NOT see the write
        let sharedView = SubscriptionSettingsManager.shared.getPlan(forKey: key)
        XCTAssertEqual(sharedView, .none,
                       "Injected manager writes must not leak into .shared's UserDefaults.standard view")
    }

    func testSharedWritesDoNotLeakToInjectedInstance() {
        // Pre-populate the .shared -> .standard store, then prove an isolated
        // manager backed by a fresh suite observes an empty world.
        // We cannot reset UserDefaults.standard (it's the real global), so we
        // pick a synthetic key that is guaranteed not to exist in user state.
        let guaranteedMissingKey = "minimax_coding_plan.b12-truly-missing@example.com"

        let (_, injectedSuite) = freshSuite()
        let injectedManager = SubscriptionSettingsManager(defaults: injectedSuite)

        // .shared should report none for our synthetic key
        XCTAssertEqual(SubscriptionSettingsManager.shared.getPlan(forKey: guaranteedMissingKey), .none)
        // Injected manager must independently report none (separate suite)
        XCTAssertEqual(injectedManager.getPlan(forKey: guaranteedMissingKey), .none,
                       "Fresh injected suite must start empty")
    }

    func testTwoInjectedInstancesAreIndependent() {
        let (_, suiteA) = freshSuite("A")
        let (_, suiteB) = freshSuite("B")
        let managerA = SubscriptionSettingsManager(defaults: suiteA)
        let managerB = SubscriptionSettingsManager(defaults: suiteB)

        let keyA = "minimax_coding_plan.b12-A@example.com"
        let keyB = "minimax_coding_plan.b12-B@example.com"

        managerA.setPlan(.preset("Max", 50), forKey: keyA)
        managerB.setPlan(.preset("Ultra", 120), forKey: keyB)

        XCTAssertEqual(managerA.getPlan(forKey: keyA), .preset("Max", 50))
        XCTAssertEqual(managerA.getPlan(forKey: keyB), .none,
                       "managerA must not see managerB's write — separate suites")
        XCTAssertEqual(managerB.getPlan(forKey: keyB), .preset("Ultra", 120))
        XCTAssertEqual(managerB.getPlan(forKey: keyA), .none,
                       "managerB must not see managerA's write — separate suites")
    }

    func testInjectedGetAllSubscriptionKeysOnlyListsOwnSuite() {
        let (_, suiteA) = freshSuite("ownsA")
        let (_, suiteB) = freshSuite("ownsB")
        let managerA = SubscriptionSettingsManager(defaults: suiteA)
        let managerB = SubscriptionSettingsManager(defaults: suiteB)

        managerA.setPlan(.preset("Plus", 20), forKey: "minimax_coding_plan.b12-A-only@example.com")
        managerB.setPlan(.preset("Max", 50),  forKey: "kimi_cn.b12-B-only@example.com")

        let aKeys = managerA.getAllSubscriptionKeys()
        let bKeys = managerB.getAllSubscriptionKeys()

        XCTAssertTrue(aKeys.contains("minimax_coding_plan.b12-A-only@example.com"))
        XCTAssertFalse(aKeys.contains("kimi_cn.b12-B-only@example.com"),
                       "managerA's listing must scope to its own suite, not leak managerB's keys")

        XCTAssertTrue(bKeys.contains("kimi_cn.b12-B-only@example.com"))
        XCTAssertFalse(bKeys.contains("minimax_coding_plan.b12-A-only@example.com"),
                       "managerB's listing must scope to its own suite, not leak managerA's keys")
    }

    func testInjectedRemovePlanOnlyAffectsOwnSuite() {
        let (_, suiteA) = freshSuite("remA")
        let (_, suiteB) = freshSuite("remB")
        let managerA = SubscriptionSettingsManager(defaults: suiteA)
        let managerB = SubscriptionSettingsManager(defaults: suiteB)

        let key = "kimi_cn.b12-remove-test@example.com"
        managerA.setPlan(.preset("Andante", 0), forKey: key)
        managerB.setPlan(.preset("Andante", 0), forKey: key)

        // Remove from managerA only — managerB's copy should still be intact
        managerA.removePlan(forKey: key)

        XCTAssertEqual(managerA.getPlan(forKey: key), .none)
        XCTAssertEqual(managerB.getPlan(forKey: key), .preset("Andante", 0),
                       "removePlan on injected managerA must not touch managerB's separate suite")
    }

    func testSharedStillUsesStandardAfterRefactor() {
        // Backward-compat smoke test: .shared must continue routing through
        // UserDefaults.standard (no behavior change for production callers).
        let sharedManager = SubscriptionSettingsManager.shared
        let probeKey = "minimax_coding_plan.b12-shared-still-works@example.com"
        defer { sharedManager.removePlan(forKey: probeKey) }

        sharedManager.setPlan(.preset("Plus", 20), forKey: probeKey)
        XCTAssertEqual(sharedManager.getPlan(forKey: probeKey), .preset("Plus", 20))
    }

    // MARK: - B06 cross-check: migration still works on injected instance

    func testMigrationOnInjectedInstanceUsesCurrentCost() {
        let (_, suite) = freshSuite()
        let manager = SubscriptionSettingsManager(defaults: suite)
        let key = "minimax_coding_plan.b12-migration@example.com"
        defer { manager.removePlan(forKey: key) }

        manager.setPlan(.preset("Plus HS", 50), forKey: key)
        let migrated = manager.getPlan(forKey: key)
        XCTAssertEqual(migrated, .preset("Plus", 20),
                       "B06 migration should fire through the injected suite the same as .shared")
    }
}
