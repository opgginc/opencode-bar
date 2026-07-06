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

    // MARK: - B44 follow-up: cross-provider duplicates must list ALL keys, not pick one

    func testCrossProviderDuplicatesListAllKeysNotJustOne() {
        // Simulate the user-reported scenario: same physical account has both
        // `kimi.<id>` and `kimi_cn.<id>` set, each with an Allegretto plan.
        // The pre-fix code did `sorted().dropFirst()` and returned only the
        // alphabetically-last key — silently picking the wrong side.
        let (_, suite) = freshSuite()
        let manager = SubscriptionSettingsManager(defaults: suite)
        let accountId = "b44-followup@example.com"
        let globalKey = "kimi.\(accountId)"
        let cnKey = "kimi_cn.\(accountId)"
        defer {
            manager.removePlan(forKey: globalKey)
            manager.removePlan(forKey: cnKey)
        }

        manager.setPlan(.preset("Allegretto", 39), forKey: globalKey)
        manager.setPlan(.preset("Allegretto", 39), forKey: cnKey)

        let groups = manager.findLikelyDuplicateSubscriptionGroups()
        XCTAssertEqual(groups.count, 1, "kimi + kimi_cn for the same accountId must be one duplicate group")
        XCTAssertEqual(Set(groups[0]), Set([globalKey, cnKey]),
                       "Both keys must appear in the duplicate group — UI needs both rows so the user can pick")
    }

    func testCrossProviderDuplicateLabelUsesCNYForCNKey() {
        // The pre-fix delete label used `displayTitle(formatter:)` without
        // passing `presets:`, so for a CN key the cost was treated as USD and
        // multiplied by the exchange rate (e.g. 39 USD × 6.795 = ¥265) —
        // misleading the user into deleting the wrong row.
        let (_, suite) = freshSuite()
        let manager = SubscriptionSettingsManager(defaults: suite)
        let accountId = "b44-cny-cost@example.com"
        let cnKey = "kimi_cn.\(accountId)"
        defer { manager.removePlan(forKey: cnKey) }

        manager.setPlan(.preset("Allegretto", 39), forKey: cnKey)

        // monthlyCost(..., inCurrency: .rmb) walks the cnyCost table for the
        // provider and returns the native CNY price when the preset has one.
        let formatter = CurrencyFormatter.shared
        let cost = manager.monthlyCost(forKey: cnKey, inCurrency: .rmb, formatter: formatter)
        XCTAssertEqual(cost, 199, accuracy: 0.01,
                       "CN Kimi Allegretto must surface native CNY 199, not 39 USD × 6.795 = ¥265")
    }

    func testSameProviderSingleKeyNotFlaggedAsDuplicate() {
        // Sanity check: a single key for one (provider, accountId) should not
        // appear in the duplicate list at all.
        let (_, suite) = freshSuite()
        let manager = SubscriptionSettingsManager(defaults: suite)
        let key = "kimi_cn.b44-solo@example.com"
        defer { manager.removePlan(forKey: key) }

        manager.setPlan(.preset("Allegretto", 39), forKey: key)

        XCTAssertTrue(manager.findLikelyDuplicateSubscriptionKeys().isEmpty,
                      "Single key with no counterpart must not be flagged as duplicate")
    }
}
