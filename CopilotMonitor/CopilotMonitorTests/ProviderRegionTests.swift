import XCTest
@testable import OpenCode_Bar

/// Phase 5 regression tests for the CN/Global provider split and RMB hiding.
final class ProviderRegionTests: XCTestCase {

    // MARK: - Provider Order

    @MainActor
    func testStatusBarQuotaOrderHasCNBeforeGlobal() {
        let controller = StatusBarController()
        let order = controller.providerQuotaOrderForTesting

        let kimiCNIndex = order.firstIndex(of: .kimiCN)
        let kimiGlobalIndex = order.firstIndex(of: .kimi)
        let minimaxCNIndex = order.firstIndex(of: .minimaxCodingPlanCN)
        let minimaxGlobalIndex = order.firstIndex(of: .minimaxCodingPlan)

        XCTAssertNotNil(kimiCNIndex)
        XCTAssertNotNil(kimiGlobalIndex)
        XCTAssertLessThan(kimiCNIndex!, kimiGlobalIndex!, "Kimi CN must appear before Kimi Global in the menu")

        XCTAssertNotNil(minimaxCNIndex)
        XCTAssertNotNil(minimaxGlobalIndex)
        XCTAssertLessThan(minimaxCNIndex!, minimaxGlobalIndex!, "MiniMax CN must appear before MiniMax Global in the menu")
    }

    // MARK: - RMB Hide Overseas Tiers

    func testRMBModeHidesKimiVivace() {
        let presets = ProviderSubscriptionPresets.presets(for: .kimi)
        let rmbVisible = presets.filter { $0.cnyCost != nil }

        XCTAssertTrue(rmbVisible.contains { $0.name == "Andante" })
        XCTAssertTrue(rmbVisible.contains { $0.name == "Moderato" })
        XCTAssertTrue(rmbVisible.contains { $0.name == "Allegretto" })
        XCTAssertTrue(rmbVisible.contains { $0.name == "Allegro" })
        XCTAssertFalse(rmbVisible.contains { $0.name == "Vivace" }, "Vivace has no native CNY price and must be hidden in RMB mode")
    }

    func testRMBModeHidesAllMiniMaxGlobalTiers() {
        let presets = ProviderSubscriptionPresets.presets(for: .minimaxCodingPlan)
        let rmbVisible = presets.filter { $0.cnyCost != nil }

        XCTAssertTrue(rmbVisible.isEmpty, "MiniMax Global presets have no CNY prices; none should be visible in RMB mode")
    }

    func testRMBModeShowsAllMiniMaxCNTiers() {
        let presets = ProviderSubscriptionPresets.presets(for: .minimaxCodingPlanCN)
        let rmbVisible = presets.filter { $0.cnyCost != nil }

        XCTAssertEqual(rmbVisible.count, presets.count, "All MiniMax CN presets should have native CNY prices")
    }

    func testCNPresetFormattedPriceUsesNativeCNYInRMBMode() {
        let preset = ProviderSubscriptionPresets.presets(for: .kimiCN).first { $0.name == "Moderato" }
        XCTAssertNotNil(preset)

        CurrencyFormatter.shared.currency = .rmb
        defer { CurrencyFormatter.shared.currency = .usd }

        let price = preset!.formattedPrice(decimals: 0)
        XCTAssertEqual(price, "¥99", "CN preset with cnyCost should show native RMB price")
    }

    // MARK: - Migration / Config Preservation

    func testOldMiniMaxGlobalSubscriptionKeyIsStillReadable() {
        let manager = SubscriptionSettingsManager.shared
        // The old enum value `.minimaxCodingPlan` was retained as the global provider alias.
        let key = "minimax_coding_plan.migration-test@example.com"
        defer { manager.removePlan(forKey: key) }

        manager.setPlan(.preset("Max", 50), forKey: key)

        let plan = manager.getPlan(forKey: key)
        XCTAssertEqual(plan, .preset("Max", 50))
    }

    func testOldKimiGlobalSubscriptionKeyIsStillReadable() {
        let manager = SubscriptionSettingsManager.shared
        // The old enum value `.kimi` was retained as the global provider alias.
        let key = "kimi.migration-test@example.com"
        defer { manager.removePlan(forKey: key) }

        manager.setPlan(.preset("Vivace", 199), forKey: key)

        let plan = manager.getPlan(forKey: key)
        XCTAssertEqual(plan, .preset("Vivace", 199))
    }
}
