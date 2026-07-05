import XCTest
@testable import OpenCode_Bar

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

    // MARK: - Family / Region mapping

    func testKimiIdentifiersShareFamily() {
        XCTAssertEqual(ProviderIdentifier.kimi.family, .kimi)
        XCTAssertEqual(ProviderIdentifier.kimiCN.family, .kimi)
        XCTAssertEqual(ProviderIdentifier.kimi.region, .global)
        XCTAssertEqual(ProviderIdentifier.kimiCN.region, .china)
    }

    func testMiniMaxIdentifiersShareFamily() {
        XCTAssertEqual(ProviderIdentifier.minimaxCodingPlan.family, .minimax)
        XCTAssertEqual(ProviderIdentifier.minimaxCodingPlanCN.family, .minimax)
        XCTAssertEqual(ProviderIdentifier.minimaxCodingPlan.region, .global)
        XCTAssertEqual(ProviderIdentifier.minimaxCodingPlanCN.region, .china)
    }

    // MARK: - B05: 新增国服 provider 的 region 默认值必须为 .china
    //
    // `region` 决定 `SubscriptionSettings.presets(family:region:)` 走哪个目录：
    // .china → 走 cnyCost 表格（人民币原生价）；.global → 走 USD 表格。
    // 如果 region 错走 .global，国服用户看到的就是 USD×rate 折算价（贵且过期）。

    func testMiMoIdentifierDefaultsToChinaRegion() {
        XCTAssertEqual(ProviderIdentifier.mimo.region, .china,
                       "MiMo is a domestic provider; region must default to .china so the CNY preset catalog is used")
        XCTAssertEqual(ProviderIdentifier.mimo.family, .mimo)
    }

    func testVolcanoArkIdentifierDefaultsToChinaRegion() {
        XCTAssertEqual(ProviderIdentifier.volcanoArk.region, .china,
                       "火山 Ark is a domestic provider; region must default to .china")
        XCTAssertEqual(ProviderIdentifier.volcanoArk.family, .volcanoArk)
    }

    func testHunyuanIdentifierDefaultsToChinaRegion() {
        XCTAssertEqual(ProviderIdentifier.hunyuan.region, .china,
                       "腾讯混元 is a domestic provider; region must default to .china")
        XCTAssertEqual(ProviderIdentifier.hunyuan.family, .hunyuan)
    }

    func testZhipuGLMIdentifierDefaultsToChinaRegion() {
        XCTAssertEqual(ProviderIdentifier.zhipuGLM.region, .china,
                       "智谱 GLM is a domestic provider; region must default to .china")
        XCTAssertEqual(ProviderIdentifier.zhipuGLM.family, .zhipuGLM)
    }

    // MARK: - B18: iconName 必须与 ProviderFamily 已有约定一致
    //
    // zhipuGLM 曾经返回 g.circle（与 Gemini CLI 撞色），5fa79d2 已改为 z.circle；
    // minimaxCodingPlanCN 不应单独有分支——和 minimaxCodingPlan 共用 MinimaxIcon。
    // 这里是回归测试，防止有人将来又把这些改回旧值或漏掉分支。

    func testIconNameUsesDistinctFamilySymbols() {
        XCTAssertEqual(ProviderIdentifier.zhipuGLM.iconName, "z.circle",
                       "zhipuGLM must use z.circle, not g.circle (which collides with Gemini CLI)")
        XCTAssertEqual(ProviderIdentifier.geminiCLI.iconName, "g.circle",
                       "geminiCLI must use g.circle as the family default")
        XCTAssertEqual(ProviderIdentifier.minimaxCodingPlanCN.iconName, "MinimaxIcon",
                       "minimaxCodingPlanCN must use the same MinimaxIcon asset as the global variant")
        XCTAssertEqual(ProviderIdentifier.minimaxCodingPlan.iconName, "MinimaxIcon",
                       "minimaxCodingPlan and minimaxCodingPlanCN must share the same icon asset")
    }

    // MARK: - RMB filtering by current region

    func testRMBModeShowsKimiGlobalTiersWithUSDConversion() {
        let previousCurrency = CurrencyFormatter.shared.currency
        let presets = ProviderSubscriptionPresets.presets(for: .kimi)
        CurrencyFormatter.shared.currency = .rmb
        defer { CurrencyFormatter.shared.currency = previousCurrency }

        // 当前 region 没有 cnyCost，所以不过滤，所有 global tier 都显示 USD 折算价
        XCTAssertTrue(presets.contains { $0.name == "Vivace" })
        let vivace = presets.first { $0.name == "Vivace" }!
        XCTAssertTrue(vivace.formattedPrice(decimals: 0).contains("¥"))
    }

    func testRMBModeHidesKimiVivaceInChinaRegion() {
        let presets = ProviderSubscriptionPresets.presets(for: .kimiCN)
        XCTAssertFalse(presets.contains { $0.name == "Vivace" })
    }

    func testRMBModeShowsMiniMaxGlobalTiersWithUSDConversion() {
        let previousCurrency = CurrencyFormatter.shared.currency
        let presets = ProviderSubscriptionPresets.presets(for: .minimaxCodingPlan)
        CurrencyFormatter.shared.currency = .rmb
        defer { CurrencyFormatter.shared.currency = previousCurrency }

        XCTAssertFalse(presets.isEmpty)
        XCTAssertTrue(presets.allSatisfy { $0.cnyCost == nil })
        XCTAssertTrue(presets.first!.formattedPrice(decimals: 0).contains("¥"))
    }

    func testRMBModeShowsAllMiniMaxCNTiers() {
        let previousCurrency = CurrencyFormatter.shared.currency
        let presets = ProviderSubscriptionPresets.presets(for: .minimaxCodingPlanCN)
        CurrencyFormatter.shared.currency = .rmb
        defer { CurrencyFormatter.shared.currency = previousCurrency }

        XCTAssertTrue(presets.allSatisfy { $0.cnyCost != nil })
    }

    func testCNPresetFormattedPriceUsesNativeCNYInRMBMode() {
        let previousCurrency = CurrencyFormatter.shared.currency
        let preset = ProviderSubscriptionPresets.presets(for: .kimiCN).first { $0.name == "Moderato" }
        XCTAssertNotNil(preset)

        CurrencyFormatter.shared.currency = .rmb
        defer { CurrencyFormatter.shared.currency = previousCurrency }

        let price = preset!.formattedPrice(decimals: 0)
        XCTAssertEqual(price, "¥99")
    }

    func testMiniMaxCNPresetFormattedPriceUsesNativeCNYInRMBMode() {
        let previousCurrency = CurrencyFormatter.shared.currency
        let preset = ProviderSubscriptionPresets.presets(for: .minimaxCodingPlanCN).first { $0.name == "Plus" }
        XCTAssertNotNil(preset)

        CurrencyFormatter.shared.currency = .rmb
        defer { CurrencyFormatter.shared.currency = previousCurrency }

        let price = preset!.formattedPrice(decimals: 0)
        XCTAssertEqual(price, "¥49")
    }

    // MARK: - Migration / Config Preservation

    func testOldMiniMaxGlobalSubscriptionKeyIsStillReadable() {
        let manager = SubscriptionSettingsManager.shared
        let key = "minimax_coding_plan.migration-test@example.com"
        defer { manager.removePlan(forKey: key) }

        manager.setPlan(.preset("Max", 50), forKey: key)

        let plan = manager.getPlan(forKey: key)
        XCTAssertEqual(plan, .preset("Max", 50))
    }

    func testOldKimiGlobalSubscriptionKeyIsStillReadable() {
        let manager = SubscriptionSettingsManager.shared
        let key = "kimi.migration-test@example.com"
        defer { manager.removePlan(forKey: key) }

        manager.setPlan(.preset("Vivace", 199), forKey: key)

        let plan = manager.getPlan(forKey: key)
        XCTAssertEqual(plan, .preset("Vivace", 199))
    }

    // MARK: - B32: 国内 provider 在 RMB 模式下必须走 cnyCost，不能用硬编码 7.2 折算
    //
    // `monthlyCost(forKey:inCurrency:formatter:)` 在 `.rmb` 分支：
    //   return cnyCost(for: plan, key: key) ?? (plan.cost * formatter.currentRate)
    //
    // 国内 provider（volcanoArk/hunyuan/zhipuGLM）的 preset.cost 是用 `CNY * 1/7.2`
    // 折算出的 USD 近似值。当 cnyCost 命中时应直接返回 CNY 真值，否则
    // fallback 会把过期 7.2 折算的 USD 再乘以当前汇率，造成 ¥40 套餐显示 ¥40.28 这类误差。
    //
    // 这个用例用 rate=7.25（与硬编码 7.2 不同），验证 cnyCost 真值优先。

    func testRMBMonthlyCostUsesNativeCNYForVolcanoArk() {
        let formatter = makeIsolatedFormatter(currency: .rmb, rate: 7.25)
        let manager = SubscriptionSettingsManager.shared
        let key = "volcano_ark.b32-volcano@example.com"
        defer { manager.removePlan(forKey: key) }

        // 模拟菜单写入：cost 字段是 40/7.2 的 USD 近似值
        let presetCost = 40.0 / 7.2
        manager.setPlan(.preset("Agent Plan Small", presetCost), forKey: key)

        let cost = manager.monthlyCost(forKey: key, inCurrency: .rmb, formatter: formatter)
        XCTAssertEqual(cost, 40, accuracy: 0.01,
                       "volcanoArk in RMB mode must return cnyCost=40, not stale 7.2 USD * 7.25 = 40.28")
    }

    func testRMBMonthlyCostUsesNativeCNYForHunyuan() {
        let formatter = makeIsolatedFormatter(currency: .rmb, rate: 7.25)
        let manager = SubscriptionSettingsManager.shared
        let key = "hunyuan.b32-hunyuan@example.com"
        defer { manager.removePlan(forKey: key) }

        let presetCost = 99.0 / 7.2
        manager.setPlan(.preset("Standard", presetCost), forKey: key)

        let cost = manager.monthlyCost(forKey: key, inCurrency: .rmb, formatter: formatter)
        XCTAssertEqual(cost, 99, accuracy: 0.01,
                       "hunyuan in RMB mode must return cnyCost=99, not stale 7.2 USD * 7.25 = 99.69")
    }

    func testRMBMonthlyCostUsesNativeCNYForZhipuGLM() {
        let formatter = makeIsolatedFormatter(currency: .rmb, rate: 7.25)
        let manager = SubscriptionSettingsManager.shared
        let key = "zhipu_glm.b32-zhipu@example.com"
        defer { manager.removePlan(forKey: key) }

        let presetCost = 149.0 / 7.2
        manager.setPlan(.preset("Pro", presetCost), forKey: key)

        let cost = manager.monthlyCost(forKey: key, inCurrency: .rmb, formatter: formatter)
        XCTAssertEqual(cost, 149, accuracy: 0.01,
                       "zhipuGLM in RMB mode must return cnyCost=149, not stale 7.2 USD * 7.25 = 149.93")
    }

    private func makeIsolatedFormatter(currency: Currency, rate: Double) -> CurrencyFormatter {
        let suiteName = "ProviderRegionTests.B32.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let rateDefaults = UserDefaults(suiteName: suiteName + ".rate")!
        rateDefaults.removePersistentDomain(forName: suiteName + ".rate")
        rateDefaults.set(rate, forKey: ExchangeRateStore.cacheKey)
        let formatter = CurrencyFormatter(defaults: defaults, rateStore: ExchangeRateStore(defaults: rateDefaults))
        formatter.currency = currency
        return formatter
    }
}
