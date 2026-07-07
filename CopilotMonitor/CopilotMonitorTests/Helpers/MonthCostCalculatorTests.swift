import XCTest
@testable import OpenCode_Bar

/// F2b Task 5 — MonthCostCalculator (15 test cases).
/// Formula: cost = (input * inputRate + output * outputRate + cacheRead * cacheReadRate) / 1e6.
/// cacheWrite excluded (5 reference consensus: Anthropic prompt cache write free,
/// OpenAI cache write simplified excluded).
final class MonthCostCalculatorTests: XCTestCase {

    private var calc: MonthCostCalculator!

    override func setUp() {
        super.setUp()
        calc = MonthCostCalculator()
    }

    // MARK: - Provider basic cost tests (1-7)

    func testKimiK26Basic() {
        // kimi representative rate: input=6.50, output=27.00, cache=1.10 (RMB/M).
        let tokens = TokenBreakdown(input: 1_000_000, output: 500_000)
        let cost = calc.calculate(provider: "kimi", model: "kimi-k2.6", tokens: tokens)
        // 1 * 6.5 + 0.5 * 27 = 6.5 + 13.5 = 20.0
        XCTAssertEqual(cost ?? -1, 20.0, accuracy: 1e-9)
    }

    func testKimiCacheRead() {
        // 1M cacheRead only -> cost = 1 * 1.10 = 1.10
        let tokens = TokenBreakdown(cacheRead: 1_000_000)
        let cost = calc.calculate(provider: "kimi", model: "kimi-k2.6", tokens: tokens)
        XCTAssertEqual(cost ?? -1, 1.10, accuracy: 1e-9)
    }

    func testKimiCacheWriteExcluded() {
        // 1M cacheWrite only -> cost = 0 (cacheWrite not billed).
        let tokens = TokenBreakdown(cacheWrite: 1_000_000)
        let cost = calc.calculate(provider: "kimi", model: "kimi-k2.6", tokens: tokens)
        XCTAssertEqual(cost ?? -1, 0.0, accuracy: 1e-9)
    }

    func testClaudeBasic() {
        // claude representative (sonnet-4-5): input=20.37, output=101.85, cache=25.46 (write rate).
        let tokens = TokenBreakdown(input: 1_000_000, output: 100_000)
        let cost = calc.calculate(provider: "claude", model: "claude-sonnet-4-5", tokens: tokens)
        // 1 * 20.37 + 0.1 * 101.85 = 20.37 + 10.185 = 30.555
        XCTAssertEqual(cost ?? -1, 30.555, accuracy: 1e-9)
    }

    func testCodexBasic() {
        // codex representative (gpt-4o): input=16.98, output=67.90, cache=8.49.
        let tokens = TokenBreakdown(input: 1_000_000, output: 100_000)
        let cost = calc.calculate(provider: "codex", model: "gpt-4o", tokens: tokens)
        // 1 * 16.98 + 0.1 * 67.90 = 16.98 + 6.79 = 23.77
        XCTAssertEqual(cost ?? -1, 23.77, accuracy: 1e-9)
    }

    func testZAIBasic() {
        // zai representative (glm-4.6): input=4.07, output=14.94, cache=0.75.
        let tokens = TokenBreakdown(input: 1_000_000, output: 100_000)
        let cost = calc.calculate(provider: "zai", model: "glm-4.6", tokens: tokens)
        // 1 * 4.07 + 0.1 * 14.94 = 4.07 + 1.494 = 5.564
        XCTAssertEqual(cost ?? -1, 5.564, accuracy: 1e-9)
    }

    func testNanoGptBasic() {
        // nanoGpt representative (gpt-4o): input=16.98, output=67.90, cache=nil.
        let tokens = TokenBreakdown(input: 1_000_000, output: 100_000)
        let cost = calc.calculate(provider: "nanogpt", model: "gpt-4o", tokens: tokens)
        // 1 * 16.98 + 0.1 * 67.90 = 23.77 (cache=nil contributes 0).
        XCTAssertEqual(cost ?? -1, 23.77, accuracy: 1e-9)
    }

    // MARK: - Edge cases (8-13)

    func testUnknownModelReturnsNil() {
        // provider="kimi" but model="unknown-model" does not match kimi's
        // representative (kimi-k2.6) -> nil (UI shows "Unknown").
        let cost = calc.calculate(
            provider: "kimi",
            model: "unknown-model",
            tokens: TokenBreakdown(input: 1_000)
        )
        XCTAssertNil(cost)
    }

    func testUnknownProviderReturnsNil() {
        // provider="mimo" not mapped in F2a PricingTable -> nil.
        let cost = calc.calculate(
            provider: "mimo",
            model: "any-model",
            tokens: TokenBreakdown(input: 1_000)
        )
        XCTAssertNil(cost)
    }

    func testCalculateMonthlyTotalsAggregatesPerProvider() {
        let aggs = [
            MonthAggregate(
                provider: "kimi",
                model: "kimi-k2.6",
                tokens: TokenBreakdown(input: 1_000_000, output: 500_000),
                yearMonth: "2026-07"
            ),
            MonthAggregate(
                provider: "kimi",
                model: "kimi-k2.6",
                tokens: TokenBreakdown(input: 2_000_000, output: 1_000_000),
                yearMonth: "2026-07"
            ),
            MonthAggregate(
                provider: "claude",
                model: "claude-sonnet-4-5",
                tokens: TokenBreakdown(input: 1_000_000, output: 100_000),
                yearMonth: "2026-07"
            ),
        ]
        let totals = calc.calculateMonthlyTotals(aggs)
        XCTAssertEqual(totals.count, 2)

        guard let kimi = totals.first(where: { $0.provider == "kimi" }) else {
            XCTFail("Missing kimi total"); return
        }
        // Kimi: input=3M, output=1.5M  ->  cost = 3 * 6.5 + 1.5 * 27 = 19.5 + 40.5 = 60.0
        XCTAssertEqual(kimi.totalCostRMB, 60.0, accuracy: 1e-9)
        XCTAssertEqual(kimi.totalTokens.input, 3_000_000)
        XCTAssertEqual(kimi.totalTokens.output, 1_500_000)
        XCTAssertEqual(kimi.modelBreakdown.count, 2)
        XCTAssertFalse(kimi.hasUnknownPricing)

        guard let claude = totals.first(where: { $0.provider == "claude" }) else {
            XCTFail("Missing claude total"); return
        }
        XCTAssertEqual(claude.totalCostRMB, 30.555, accuracy: 1e-9)
        XCTAssertEqual(claude.totalTokens.input, 1_000_000)
        XCTAssertEqual(claude.totalTokens.output, 100_000)
    }

    func testHasUnknownPricingFlag() {
        // Mix of known + unknown model within same provider should flag hasUnknownPricing.
        let aggs = [
            MonthAggregate(
                provider: "kimi",
                model: "kimi-k2.6",
                tokens: TokenBreakdown(input: 1_000_000),
                yearMonth: "2026-07"
            ),
            MonthAggregate(
                provider: "kimi",
                model: "unknown-model",
                tokens: TokenBreakdown(input: 1_000_000),
                yearMonth: "2026-07"
            ),
        ]
        let totals = calc.calculateMonthlyTotals(aggs)
        guard let kimi = totals.first(where: { $0.provider == "kimi" }) else {
            XCTFail("Missing kimi total"); return
        }
        XCTAssertTrue(kimi.hasUnknownPricing, "Unknown model in any agg should flag")
        XCTAssertEqual(kimi.modelBreakdown.count, 2)
    }

    func testZeroTokensReturnsZero() {
        // All zeros -> cost = 0 (still non-nil since provider/model match).
        let cost = calc.calculate(provider: "kimi", model: "kimi-k2.6", tokens: TokenBreakdown())
        XCTAssertEqual(cost ?? -1, 0.0, accuracy: 1e-9)
    }

    func testVeryLargeTokens() {
        // 1B input + 500M output for kimi-k2.6.
        // cost = 1000 * 6.5 + 500 * 27 = 6500 + 13500 = 20000 RMB.
        let tokens = TokenBreakdown(input: 1_000_000_000, output: 500_000_000)
        let cost = calc.calculate(provider: "kimi", model: "kimi-k2.6", tokens: tokens)
        XCTAssertEqual(cost ?? -1, 20_000.0, accuracy: 1e-6)
    }

    // MARK: - Real user data + zai bridge (14, 15)

    func testRealUserData() {
        // User real data: 14M input + 1.4M output + 473M cacheRead for codex gpt-4o.
        // F2a codex gpt-4o rate: input=16.98, output=67.90, cache=8.49 (RMB/M).
        // Formula:
        //   14 * 16.98 + 1.4 * 67.90 + 473 * 8.49
        //   = 237.72 + 95.06 + 4015.77
        //   = 4348.55 RMB.
        // (Note: F2b plan mentioned "~4640 RMB" based on an older rate model;
        //  current F2a PricingTable values yield 4348.55.)
        let tokens = TokenBreakdown(
            input: 14_000_000,
            output: 1_400_000,
            cacheRead: 473_000_000
        )
        let cost = calc.calculate(provider: "codex", model: "gpt-4o", tokens: tokens)
        XCTAssertEqual(cost ?? 0, 4348.55, accuracy: 0.01)
    }

    func testProviderZaiMapping() {
        // Verify F2b provider string "zai" (Provider.rawValue) bridges to F2a
        // ProviderIdentifier.zaiCodingPlan (different enum, different rawValue).
        // "zai" -> .zaiCodingPlan -> glm-4.6 (representative).
        // Cost = 1 * 4.07 + 0.1 * 14.94 = 5.564.
        let tokens = TokenBreakdown(input: 1_000_000, output: 100_000)
        let cost = calc.calculate(provider: "zai", model: "glm-4.6", tokens: tokens)
        XCTAssertEqual(cost ?? -1, 5.564, accuracy: 1e-9)
    }
}
