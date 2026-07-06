import XCTest
@testable import OpenCode_Bar

final class MigrationPresetTests: XCTestCase {

    // MARK: - B06: ProviderSubscriptionPresets.migratedPlan helper

    func testMiniMaxStarterMigratesToPlus() {
        let migrated = ProviderSubscriptionPresets.migratedPlan(
            .preset("Starter", 50), for: .minimaxCodingPlan
        )
        XCTAssertEqual(migrated, .preset("Plus", 20),
                       "MiniMax 'Starter' (legacy) should map to current 'Plus' with new cost")
    }

    func testMiniMaxPlusHSMigratesToPlus() {
        let migrated = ProviderSubscriptionPresets.migratedPlan(
            .preset("Plus HS", 50), for: .minimaxCodingPlan
        )
        XCTAssertEqual(migrated, .preset("Plus", 20))
    }

    func testMiniMaxMaxHSMigratesToMax() {
        let migrated = ProviderSubscriptionPresets.migratedPlan(
            .preset("Max HS", 50), for: .minimaxCodingPlan
        )
        XCTAssertEqual(migrated, .preset("Max", 50))
    }

    func testMiniMaxUltraHSMigratesToUltra() {
        let migrated = ProviderSubscriptionPresets.migratedPlan(
            .preset("Ultra HS", 160), for: .minimaxCodingPlan
        )
        XCTAssertEqual(migrated, .preset("Ultra", 120))
    }

    func testMiniMaxCurrentNamePassesThroughUnchanged() {
        let migrated = ProviderSubscriptionPresets.migratedPlan(
            .preset("Plus", 20), for: .minimaxCodingPlan
        )
        XCTAssertEqual(migrated, .preset("Plus", 20),
                       "Current catalog names must not be re-mapped")
    }

    func testMiniMaxUnknownLegacyNamePassesThrough() {
        // A name not in the legacy map (e.g. user typed something custom) passes through.
        let migrated = ProviderSubscriptionPresets.migratedPlan(
            .preset("Mystery Plan", 99), for: .minimaxCodingPlan
        )
        XCTAssertEqual(migrated, .preset("Mystery Plan", 99))
    }

    func testNonPlanValuePassesThrough() {
        let migratedNone = ProviderSubscriptionPresets.migratedPlan(.none, for: .minimaxCodingPlan)
        XCTAssertEqual(migratedNone, .none)

        let migratedCustom = ProviderSubscriptionPresets.migratedPlan(
            .custom(123.45), for: .minimaxCodingPlan
        )
        XCTAssertEqual(migratedCustom, .custom(123.45),
                       "Custom plans should not be migrated — keep user-entered amount")
    }

    func testNonMiniMaxProviderDoesNotMigrate() {
        // Even a legacy-looking name on another provider's key passes through
        // (the map is MiniMax-specific).
        let migrated = ProviderSubscriptionPresets.migratedPlan(
            .preset("Plus HS", 50), for: .kimiCN
        )
        XCTAssertEqual(migrated, .preset("Plus HS", 50),
                       "Migration map is MiniMax-only; other providers must leave names alone")
    }

    func testMigrationUsesRegionAwareCatalog() {
        // Both regions should resolve to their respective current-cost preset.
        let cnMigrated = ProviderSubscriptionPresets.migratedPlan(
            .preset("Max HS", 50), for: .minimaxCodingPlanCN
        )
        XCTAssertEqual(cnMigrated, .preset("Max", 50),
                       "MiniMax CN should resolve to Max with cost 50")

        let globalMigrated = ProviderSubscriptionPresets.migratedPlan(
            .preset("Max HS", 50), for: .minimaxCodingPlan
        )
        XCTAssertEqual(globalMigrated, .preset("Max", 50),
                       "MiniMax Global should resolve to Max with cost 50")
    }

    // MARK: - B06: getPlan(forKey:) integration — persists migrated value

    func testGetPlanForKeyMigratesLegacyMiniMaxNameAndPersists() {
        let manager = SubscriptionSettingsManager.shared
        let legacyKey = "minimax_coding_plan.b06-migration@example.com"
        defer { manager.removePlan(forKey: legacyKey) }

        manager.setPlan(.preset("Plus HS", 50), forKey: legacyKey)

        // First read: migrate + persist
        let first = manager.getPlan(forKey: legacyKey)
        XCTAssertEqual(first, .preset("Plus", 20),
                       "Stored legacy 'Plus HS' should migrate to current 'Plus' on read")

        // Subsequent reads should hit the persisted migrated value (not re-migrate every time)
        let second = manager.getPlan(forKey: legacyKey)
        XCTAssertEqual(second, .preset("Plus", 20),
                       "Second read should return the persisted migrated value")
    }

    func testGetPlanForKeyCurrentNameNotReMigrated() {
        let manager = SubscriptionSettingsManager.shared
        let key = "minimax_coding_plan.b06-current@example.com"
        defer { manager.removePlan(forKey: key) }

        manager.setPlan(.preset("Ultra", 120), forKey: key)

        let result = manager.getPlan(forKey: key)
        XCTAssertEqual(result, .preset("Ultra", 120),
                       "Already-current names should pass through unchanged")
    }

    func testGetPlanForKeyNonMiniMaxProviderDoesNotMigrate() {
        let manager = SubscriptionSettingsManager.shared
        let key = "kimi_cn.b06-no-op@example.com"
        defer { manager.removePlan(forKey: key) }

        manager.setPlan(.preset("Plus HS", 50), forKey: key)

        let result = manager.getPlan(forKey: key)
        XCTAssertEqual(result, .preset("Plus HS", 50),
                       "Non-MiniMax keys with legacy-looking names should pass through untouched")
    }
}
