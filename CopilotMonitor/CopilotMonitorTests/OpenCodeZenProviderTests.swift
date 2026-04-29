import XCTest
@testable import OpenCode_Bar

final class OpenCodeZenProviderTests: XCTestCase {

    func testParseModelCostsReadsCurrentMultilineStatsFormat() {
        let output = #"""
        ┌────────────────────────────────────────────────────────┐
        │                      MODEL USAGE                       │
        ├────────────────────────────────────────────────────────┤
        │ openai/gpt-5.5                                         │
        │  Messages                                        2,871 │
        │  Input Tokens                                    12.5M │
        │  Cost                                        $215.2045 │
        ├────────────────────────────────────────────────────────┤
        │ nano-gpt/moonshotai/kimi-k2.6:thinking                 │
        │  Messages                                           18 │
        │  Input Tokens                                   410.6K │
        │  Cost                                          $0.2251 │
        └────────────────────────────────────────────────────────┘
        """#

        let modelCosts = OpenCodeZenProvider.parseModelCosts(from: output)

        XCTAssertEqual(modelCosts["openai/gpt-5.5"], 215.2045)
        XCTAssertEqual(modelCosts["nano-gpt/moonshotai/kimi-k2.6:thinking"], 0.2251)
        XCTAssertEqual(modelCosts.count, 2)
    }

    func testParseModelCostsIgnoresCostRowsOutsideModelUsageSection() {
        let output = #"""
        ┌────────────────────────────────────────────────────────┐
        │                      MODEL USAGE                       │
        ├────────────────────────────────────────────────────────┤
        │ openai/gpt-5.5                                         │
        │  Messages                                        2,871 │
        │  Cost                                        $215.2045 │
        ├────────────────────────────────────────────────────────┤
        │                       TOOL USAGE                       │
        ├────────────────────────────────────────────────────────┤
        │ mcp-server                                             │
        │  Calls                                                4 │
        │  Cost                                          $1.2300 │
        └────────────────────────────────────────────────────────┘
        """#

        let modelCosts = OpenCodeZenProvider.parseModelCosts(from: output)

        XCTAssertEqual(modelCosts["openai/gpt-5.5"], 215.2045)
        XCTAssertNil(modelCosts["mcp-server"])
        XCTAssertEqual(modelCosts.count, 1)
    }

    func testAdjustStatsForDisplayExcludesParsedOpenAIModelsWhenOpenAIBaseURLRoutesToCodex() {
        let configuration = CodexEndpointConfiguration(
            mode: .external(usageURL: URL(string: "https://codex.2631.eu/api/codex/usage")!),
            source: "/tmp/opencode.json",
            usesOpenAIProviderBaseURL: true
        )
        let modelCosts = [
            "openai/gpt-5.5": 215.2045,
            "openai/gpt-5.4": 4.2252,
            "nano-gpt/moonshotai/kimi-k2.6:thinking": 0.2251
        ]

        let adjusted = OpenCodeZenProvider.adjustStatsForDisplay(
            totalCost: 219.6548,
            avgCostPerDay: 31.3792,
            modelCosts: modelCosts,
            codexEndpointConfiguration: configuration
        )

        XCTAssertEqual(adjusted.excludedCost, 219.4297, accuracy: 0.0001)
        XCTAssertEqual(adjusted.totalCost, 0.2251, accuracy: 0.0001)
        XCTAssertEqual(adjusted.modelCosts.keys.sorted(), ["nano-gpt/moonshotai/kimi-k2.6:thinking"])
    }

    func testAdjustStatsForDisplayExcludesOpenAIModelsWhenOpenAIBaseURLRoutesToCodex() {
        let configuration = CodexEndpointConfiguration(
            mode: .external(usageURL: URL(string: "https://codex.2631.eu/api/codex/usage")!),
            source: "/tmp/opencode.json",
            usesOpenAIProviderBaseURL: true
        )

        let adjusted = OpenCodeZenProvider.adjustStatsForDisplay(
            totalCost: 22.0,
            avgCostPerDay: 3.142857,
            modelCosts: [
                "openai/gpt-5.4": 11.2679,
                "openai/gpt-5.4-mini": 3.7001,
                "nano-gpt/minimax/minimax-m2.5": 4.2045,
                "nano-gpt/zai-org/glm-5:thinking": 1.6042
            ],
            codexEndpointConfiguration: configuration
        )

        XCTAssertEqual(adjusted.excludedCost, 14.968, accuracy: 0.0001)
        XCTAssertEqual(adjusted.totalCost, 7.032, accuracy: 0.0001)
        XCTAssertEqual(adjusted.avgCostPerDay, 1.004571, accuracy: 0.0001)
        XCTAssertEqual(adjusted.modelCosts.keys.sorted(), [
            "nano-gpt/minimax/minimax-m2.5",
            "nano-gpt/zai-org/glm-5:thinking"
        ])
    }

    func testAdjustStatsForDisplayKeepsOpenAIModelsForExplicitUsageOverride() {
        let configuration = CodexEndpointConfiguration(
            mode: .external(usageURL: URL(string: "https://custom.example.com/api/codex/usage")!),
            source: "/tmp/opencode.json",
            usesOpenAIProviderBaseURL: false
        )

        let adjusted = OpenCodeZenProvider.adjustStatsForDisplay(
            totalCost: 12.0,
            avgCostPerDay: 4.0,
            modelCosts: [
                "openai/gpt-5.4": 9.0,
                "openrouter/qwen/qwen3": 3.0
            ],
            codexEndpointConfiguration: configuration
        )

        XCTAssertEqual(adjusted.excludedCost, 0)
        XCTAssertEqual(adjusted.totalCost, 12.0)
        XCTAssertEqual(adjusted.avgCostPerDay, 4.0)
        XCTAssertEqual(adjusted.modelCosts.count, 2)
    }
}
