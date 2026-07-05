import XCTest
@testable import OpenCode_Bar

final class SubscriptionPresetTests: XCTestCase {
    func testPresetSupportsNativeCNY() {
        let p = SubscriptionPreset(name: "Ultra 极速版", cost: 124.86, cnyCost: 899)
        XCTAssertEqual(p.cnyCost, 899)
        XCTAssertEqual(p.cost, 124.86, accuracy: 0.01)
    }

    func testUSDPresetHasNilCNY() {
        let p = SubscriptionPreset(name: "Pro", cost: 20)
        XCTAssertNil(p.cnyCost)
    }

    func testKimiChinaPresetsHaveDomesticCNY() {
        let presets = ProviderSubscriptionPresets.presets(family: .kimi, region: .china)
        XCTAssertEqual(presets.first { $0.name == "Andante" }?.cnyCost, 49)
        XCTAssertEqual(presets.first { $0.name == "Moderato" }?.cnyCost, 99)
        XCTAssertEqual(presets.first { $0.name == "Allegretto" }?.cnyCost, 199)
        XCTAssertEqual(presets.first { $0.name == "Allegro" }?.cnyCost, 699)
        XCTAssertNil(presets.first { $0.name == "Vivace" })
    }

    func testKimiGlobalPresetsAreUSDOnly() {
        let presets = ProviderSubscriptionPresets.presets(family: .kimi, region: .global)
        XCTAssertNil(presets.first { $0.name == "Andante" })
        XCTAssertEqual(presets.first { $0.name == "Vivace" }?.cost, 199)
        XCTAssertTrue(presets.allSatisfy { $0.cnyCost == nil })
    }

    func testMiniMaxCNPresetsHaveDomesticCNY() {
        let presets = ProviderSubscriptionPresets.presets(family: .minimax, region: .china)
        XCTAssertEqual(presets.first { $0.name == "Ultra" }?.cnyCost, 469)
        XCTAssertEqual(presets.first { $0.name == "Max" }?.cnyCost, 119)
    }

    func testMiniMaxGlobalPresetsUseUSDOnly() {
        let presets = ProviderSubscriptionPresets.presets(family: .minimax, region: .global)
        XCTAssertNil(presets.first { $0.name == "Ultra" }?.cnyCost)
        XCTAssertEqual(presets.first { $0.name == "Max" }?.cost, 50)
    }

    func testCodexPresetsIncludeBothProTiers() {
        let presets = ProviderSubscriptionPresets.presets(family: .codex, region: .global)
        let pro100 = presets.first { $0.name == "Pro $100" }
        let pro200 = presets.first { $0.name == "Pro $200" }
        XCTAssertNotNil(pro100)
        XCTAssertNotNil(pro200)
        XCTAssertEqual(pro100?.cost, 100)
        XCTAssertEqual(pro200?.cost, 200)
    }

    func testNewProvidersHavePresets() {
        XCTAssertFalse(ProviderSubscriptionPresets.presets(for: .mimo).isEmpty)
        XCTAssertFalse(ProviderSubscriptionPresets.presets(for: .volcanoArk).isEmpty)
        XCTAssertFalse(ProviderSubscriptionPresets.presets(for: .hunyuan).isEmpty)
        XCTAssertFalse(ProviderSubscriptionPresets.presets(for: .zhipuGLM).isEmpty)
    }

    // MARK: - B30: Gemini CLI 套餐名称不能撞名（否则菜单里同名高亮 B22 会同时点亮两档）
    //
    // 原 catalog 里 "Plus" 同时给 $4 Monthly 和 $8 Annual，"Ultra" 同时给 $125/$250
    // 两套价格。ProviderMenuBuilder.addSubscriptionItems 只比较 name 不比较 cost，
    // 用户存 Plus $4 时菜单里 Plus Annual 也会被 .on 高亮，视觉冲突。
    // 重命名后 "Plus Monthly" / "Plus Annual" 各自独立、名字不再前缀重叠。

    func testGeminiCLIPresetsHaveUniqueNames() {
        let presets = ProviderSubscriptionPresets.geminiCLI
        let names = presets.map(\.name)
        let uniqueNames = Set(names)
        XCTAssertEqual(names.count, uniqueNames.count,
                       "Gemini CLI preset names must be unique to avoid menu ambiguity (B22/B30): \(names)")
    }

    func testGeminiCLIPlusAndUltraTiersAreDisambiguated() {
        let presets = ProviderSubscriptionPresets.geminiCLI
        let plusMonthly = presets.first { $0.name == "Plus Monthly" }
        let plusAnnual = presets.first { $0.name == "Plus Annual" }
        let ultraMonthly = presets.first { $0.name == "Ultra Monthly" }
        let ultraAnnual = presets.first { $0.name == "Ultra Annual" }

        XCTAssertNotNil(plusMonthly, "Gemini CLI must keep a Monthly Plus tier")
        XCTAssertNotNil(plusAnnual, "Gemini CLI must keep an Annual Plus tier")
        XCTAssertNotNil(ultraMonthly, "Gemini CLI must keep a Monthly Ultra tier")
        XCTAssertNotNil(ultraAnnual, "Gemini CLI must keep an Annual Ultra tier")

        // Plus Monthly 价格应低于 Plus Annual 折算到月的水平（年付是预付一次性）
        XCTAssertLessThan(plusMonthly!.cost, plusAnnual!.cost * 2,
                          "Monthly tier should be cheaper per-cycle than the annual equivalent")
    }
}
