import XCTest
@testable import OpenCode_Bar

final class SubscriptionPresetTests: XCTestCase {
    func testPresetSupportsNativeCNY() {
        let p = SubscriptionPreset(name: "Ultra 极速版", cost: 124.86, cnyCost: 899)
        XCTAssertEqual(p.cnyCost, 899)
        XCTAssertEqual(p.cost, 124.86, accuracy: 0.01)  // USD 仍作计算真值
    }

    func testUSDPresetHasNilCNY() {
        let p = SubscriptionPreset(name: "Pro", cost: 20)
        XCTAssertNil(p.cnyCost)
    }

    func testKimiPresetsHaveDomesticCNY() {
        let presets = ProviderSubscriptionPresets.kimi
        XCTAssertEqual(presets.first { $0.name == "Moderato" }?.cnyCost, 99)
        XCTAssertEqual(presets.first { $0.name == "Allegretto" }?.cnyCost, 199)
        XCTAssertNil(presets.first { $0.name == "Vivace" }?.cnyCost)
    }

    func testMiniMaxPresetsHaveDomesticCNY() {
        let presets = ProviderSubscriptionPresets.minimaxCodingPlan
        XCTAssertEqual(presets.first { $0.name == "Ultra HS" }?.cnyCost, 899)
        XCTAssertEqual(presets.first { $0.name == "Max" }?.cnyCost, 119)
    }
}
