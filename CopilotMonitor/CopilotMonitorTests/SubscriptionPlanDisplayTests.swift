import XCTest
@testable import OpenCode_Bar

final class SubscriptionPlanDisplayTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "SubscriptionPlanDisplayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeFormatter(currency: Currency, rate: Double = 7.2) -> CurrencyFormatter {
        let defaults = makeDefaults()
        let rateDefaults = makeDefaults()
        rateDefaults.set(rate, forKey: ExchangeRateStore.cacheKey)
        let formatter = CurrencyFormatter(defaults: defaults, rateStore: ExchangeRateStore(defaults: rateDefaults))
        formatter.currency = currency
        return formatter
    }

    func testRMBSelectedPresetUsesYuanAndMonthlySuffix() {
        let formatter = makeFormatter(currency: .rmb)
        let presets = ProviderSubscriptionPresets.kimiChina
        let plan = SubscriptionPlan.preset("Moderato", 19)

        let title = plan.displayTitle(formatter: formatter, presets: presets)

        XCTAssertFalse(title.contains("$"), "RMB selected-plan text must not contain '$': \(title)")
        XCTAssertTrue(title.contains("/月"), "RMB selected-plan text should use '月' suffix: \(title)")
        XCTAssertTrue(title.contains("¥99"), "RMB selected-plan text should use native CNY price: \(title)")
    }

    func testRMBCustomPlanUsesYuanAndMonthlySuffix() {
        let formatter = makeFormatter(currency: .rmb)
        let plan = SubscriptionPlan.custom(20)

        let title = plan.displayTitle(formatter: formatter, presets: [])

        XCTAssertFalse(title.contains("$"), "RMB custom-plan text must not contain '$': \(title)")
        XCTAssertTrue(title.contains("/月"), "RMB custom-plan text should use '月' suffix: \(title)")
        XCTAssertTrue(title.contains("¥144"), "RMB custom-plan text should convert USD via rate: \(title)")
    }

    func testRMBNonePlanUsesYuanWithoutDollar() {
        let formatter = makeFormatter(currency: .rmb)
        let plan = SubscriptionPlan.none

        let title = plan.displayTitle(formatter: formatter, presets: [])

        XCTAssertFalse(title.contains("$"), "RMB none-plan text must not contain '$': \(title)")
        XCTAssertTrue(title.contains("¥0"), "RMB none-plan text should show zero yuan: \(title)")
    }

    func testUSDSelectedPresetUsesDollarAndMonthlySuffix() {
        let formatter = makeFormatter(currency: .usd)
        let presets = ProviderSubscriptionPresets.kimiChina
        let plan = SubscriptionPlan.preset("Moderato", 19)

        let title = plan.displayTitle(formatter: formatter, presets: presets)

        XCTAssertTrue(title.contains("$19"), "USD selected-plan text should show dollar price: \(title)")
        XCTAssertFalse(title.contains("/m"), "USD selected-plan text must not use '/m': \(title)")
        XCTAssertTrue(title.contains("/月"), "USD selected-plan text should still use Chinese '月' suffix: \(title)")
    }

    func testUSDCustomPlanUsesDollarAndMonthlySuffix() {
        let formatter = makeFormatter(currency: .usd)
        let plan = SubscriptionPlan.custom(25)

        let title = plan.displayTitle(formatter: formatter, presets: [])

        XCTAssertTrue(title.contains("$25"), "USD custom-plan text should show dollar price: \(title)")
        XCTAssertTrue(title.contains("/月"), "USD custom-plan text should use Chinese '月' suffix: \(title)")
    }

    @MainActor
    func testCodexSubscriptionMenuShowsDistinctPro100AndPro200() {
        UserDefaults.standard.set(true, forKey: "githubStarPromptDismissed")

        let controller = StatusBarController()
        let menu = NSMenu()
        controller.addSubscriptionItems(to: menu, provider: .codex, accountId: nil)

        let titles = menu.items.map(\.title)
        let pro100 = titles.first { $0.contains("Pro $100") }
        let pro200 = titles.first { $0.contains("Pro $200") }

        XCTAssertNotNil(pro100, "Codex subscription menu should contain 'Pro $100' preset: \(titles)")
        XCTAssertNotNil(pro200, "Codex subscription menu should contain 'Pro $200' preset: \(titles)")
        XCTAssertNotEqual(pro100, pro200, "Pro $100 and Pro $200 should be distinct menu items")
    }

    // MARK: - B38: "无" highlight must not double up with a detected preset match.

    @MainActor
    func testNoneItemIsNotSelectedWhenDetectedPlanMatchesPreset() {
        // User has no saved plan for CN Kimi (currentPlan == .none because we
        // never persisted anything) and the API reports the user is on
        // "Moderato". The detected preset is the implicit selection, so "无"
        // must NOT also be marked .on.
        let previousCurrency = CurrencyFormatter.shared.currency
        CurrencyFormatter.shared.currency = .usd
        defer { CurrencyFormatter.shared.currency = previousCurrency }

        let testAccount = "b38-detected-\(UUID().uuidString.lowercased())"
        let manager = SubscriptionSettingsManager.shared
        let key = manager.subscriptionKey(for: .kimiCN, accountId: testAccount)
        // Make sure no plan is persisted for this account.
        manager.removePlan(forKey: key)
        defer { manager.removePlan(forKey: key) }

        let controller = StatusBarController()
        // Suppress the GitHub star alert that the default init triggers.
        let dismissKey = "githubStarPromptDismissed"
        let previousDismiss = UserDefaults.standard.bool(forKey: dismissKey)
        UserDefaults.standard.set(true, forKey: dismissKey)
        defer { UserDefaults.standard.set(previousDismiss, forKey: dismissKey) }
        let menu = NSMenu()
        controller.addSubscriptionItems(
            to: menu,
            provider: .kimiCN,
            accountId: testAccount,
            detectedPlanName: "Moderato"
        )

        let items = menu.items
        let noneItem = items.first { $0.title.contains("无") }
        let moderatoItem = items.first { $0.title.contains("Moderato") }

        XCTAssertNotNil(noneItem)
        XCTAssertNotNil(moderatoItem)
        XCTAssertNotEqual(noneItem?.state, .on,
                         "无 should NOT be selected when a detected preset matches a known tier")
        XCTAssertEqual(moderatoItem?.state, .on,
                       "Moderato should be auto-selected when it matches the API-detected plan")
    }

    @MainActor
    func testNoneItemIsSelectedWhenNoDetectedPlan() {
        // No saved plan AND no detected plan name → "无" is the only sensible
        // selection, so it must be marked .on.
        let previousCurrency = CurrencyFormatter.shared.currency
        CurrencyFormatter.shared.currency = .usd
        defer { CurrencyFormatter.shared.currency = previousCurrency }

        let testAccount = "b38-nodetected-\(UUID().uuidString.lowercased())"
        let manager = SubscriptionSettingsManager.shared
        let key = manager.subscriptionKey(for: .kimiCN, accountId: testAccount)
        manager.removePlan(forKey: key)
        defer { manager.removePlan(forKey: key) }

        let controller = StatusBarController()
        let menu = NSMenu()
        controller.addSubscriptionItems(
            to: menu,
            provider: .kimiCN,
            accountId: testAccount,
            detectedPlanName: nil
        )

        let items = menu.items
        let noneItem = items.first { $0.title.contains("无") }

        XCTAssertNotNil(noneItem)
        XCTAssertEqual(noneItem?.state, .on,
                       "无 must be selected when there is no detected preset match")
    }

    @MainActor
    func testUserPickedPresetStillSelectedAndNotNone() {
        // When the user has explicitly saved a preset and the API confirms it,
        // that preset is .on and "无" is NOT. This protects existing behavior.
        let previousCurrency = CurrencyFormatter.shared.currency
        CurrencyFormatter.shared.currency = .usd
        defer { CurrencyFormatter.shared.currency = previousCurrency }

        let testAccount = "b38-picked-\(UUID().uuidString.lowercased())"
        let manager = SubscriptionSettingsManager.shared
        let key = manager.subscriptionKey(for: .kimiCN, accountId: testAccount)
        manager.removePlan(forKey: key)
        manager.setPlan(.preset("Moderato", 19), forKey: key)
        defer { manager.removePlan(forKey: key) }

        let controller = StatusBarController()
        // Suppress the GitHub star alert that the default init triggers.
        let dismissKey = "githubStarPromptDismissed"
        let previousDismiss = UserDefaults.standard.bool(forKey: dismissKey)
        UserDefaults.standard.set(true, forKey: dismissKey)
        defer { UserDefaults.standard.set(previousDismiss, forKey: dismissKey) }
        let menu = NSMenu()
        controller.addSubscriptionItems(
            to: menu,
            provider: .kimiCN,
            accountId: testAccount,
            detectedPlanName: "Moderato"
        )

        let items = menu.items
        let noneItem = items.first { $0.title.contains("无") }
        let moderatoItem = items.first { $0.title.contains("Moderato") }

        XCTAssertNotNil(noneItem)
        XCTAssertNotNil(moderatoItem)
        XCTAssertNotEqual(noneItem?.state, .on,
                         "无 must not be selected when the user has explicitly picked Moderato")
        XCTAssertEqual(moderatoItem?.state, .on,
                       "Moderato must be selected when the user has explicitly picked it")
    }
}
