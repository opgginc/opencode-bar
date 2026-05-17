import XCTest
@testable import OpenCode_Bar

final class OpenCodeZenProviderTests: XCTestCase {

    func testParseModelCostsReadsCurrentMultilineStatsFormat() {
        let output = #"""
        ┌────────────────────────────────────────────────────────┐
        │                      MODEL USAGE                       │
        ├────────────────────────────────────────────────────────┤
        │ opencode/gpt-5.5                                       │
        │  Messages                                        2,871 │
        │  Input Tokens                                    12.5M │
        │  Cost                                        $215.2045 │
        ├────────────────────────────────────────────────────────┤
        │ opencode-go/kimi-k2.6                                  │
        │  Messages                                           18 │
        │  Input Tokens                                   410.6K │
        │  Cost                                          $0.2251 │
        └────────────────────────────────────────────────────────┘
        """#

        let modelCosts = OpenCodeZenProvider.parseModelCosts(from: output)

        XCTAssertEqual(modelCosts["opencode/gpt-5.5"], 215.2045)
        XCTAssertEqual(modelCosts["opencode-go/kimi-k2.6"], 0.2251)
        XCTAssertEqual(modelCosts.count, 2)
    }

    func testParseModelMessagesReadsCurrentMultilineStatsFormat() {
        let output = #"""
        ┌────────────────────────────────────────────────────────┐
        │                      MODEL USAGE                       │
        ├────────────────────────────────────────────────────────┤
        │ opencode/gpt-5.5                                       │
        │  Messages                                        2,871 │
        │  Cost                                        $215.2045 │
        ├────────────────────────────────────────────────────────┤
        │ openrouter/google/gemini-3-flash-preview               │
        │  Messages                                           26 │
        │  Cost                                          $0.5563 │
        └────────────────────────────────────────────────────────┘
        """#

        let modelMessages = OpenCodeZenProvider.parseModelMessages(from: output)

        XCTAssertEqual(modelMessages["opencode/gpt-5.5"], 2_871)
        XCTAssertEqual(modelMessages["openrouter/google/gemini-3-flash-preview"], 26)
        XCTAssertEqual(modelMessages.count, 2)
    }

    func testParseModelCostsIgnoresCostRowsOutsideModelUsageSection() {
        let output = #"""
        ┌────────────────────────────────────────────────────────┐
        │                      MODEL USAGE                       │
        ├────────────────────────────────────────────────────────┤
        │ opencode/gpt-5.5                                       │
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

        XCTAssertEqual(modelCosts["opencode/gpt-5.5"], 215.2045)
        XCTAssertNil(modelCosts["mcp-server"])
        XCTAssertEqual(modelCosts.count, 1)
    }

    func testAdjustStatsForDisplayKeepsOnlyOpenCodeZenProviderPrefixes() {
        let modelCosts = [
            "opencode/gpt-5.5": 2.0,
            "opencode-go/minimax-m2.7": 4.0,
            "anthropic/claude-opus-4-7": 15.0,
            "openrouter/google/gemini-3-flash-preview": 9.0,
            "openai/gpt-5.5-fast": 0.0
        ]
        let modelMessages = [
            "opencode/gpt-5.5": 1,
            "opencode-go/minimax-m2.7": 159,
            "anthropic/claude-opus-4-7": 2_848,
            "openrouter/google/gemini-3-flash-preview": 26
        ]

        let adjusted = OpenCodeZenProvider.adjustStatsForDisplay(
            totalCost: 30.0,
            avgCostPerDay: 10.0,
            modelCosts: modelCosts,
            modelMessages: modelMessages
        )

        XCTAssertEqual(adjusted.excludedCost, 24.0, accuracy: 0.0001)
        XCTAssertEqual(adjusted.totalCost, 6.0, accuracy: 0.0001)
        XCTAssertEqual(adjusted.avgCostPerDay, 2.0, accuracy: 0.0001)
        XCTAssertEqual(adjusted.messages, 160)
        XCTAssertEqual(adjusted.modelCosts.keys.sorted(), [
            "opencode-go/minimax-m2.7",
            "opencode/gpt-5.5"
        ])
    }

    func testAdjustStatsForDisplayReturnsZeroWhenStatsHaveNoZenModels() {
        let adjusted = OpenCodeZenProvider.adjustStatsForDisplay(
            totalCost: 22.0,
            avgCostPerDay: 3.142857,
            modelCosts: [
                "openai/gpt-5.4": 11.2679,
                "openai/gpt-5.4-mini": 3.7001,
                "nano-gpt/minimax/minimax-m2.5": 4.2045,
                "nano-gpt/zai-org/glm-5:thinking": 1.6042
            ]
        )

        XCTAssertEqual(adjusted.excludedCost, 22.0, accuracy: 0.0001)
        XCTAssertEqual(adjusted.totalCost, 0, accuracy: 0.0001)
        XCTAssertEqual(adjusted.avgCostPerDay, 0, accuracy: 0.0001)
        XCTAssertEqual(adjusted.messages, 0)
        XCTAssertTrue(adjusted.modelCosts.isEmpty)
    }

    func testIsOpenCodeZenModelMatchesOnlyZenProviderPrefixes() {
        XCTAssertTrue(OpenCodeZenProvider.isOpenCodeZenModel("opencode/gpt-5.5"))
        XCTAssertTrue(OpenCodeZenProvider.isOpenCodeZenModel(" opencode-go/minimax-m2.7 "))
        XCTAssertFalse(OpenCodeZenProvider.isOpenCodeZenModel("openai/gpt-5.5"))
        XCTAssertFalse(OpenCodeZenProvider.isOpenCodeZenModel("openrouter/opencode/gpt-5.5"))
        XCTAssertFalse(OpenCodeZenProvider.isOpenCodeZenModel("nano-gpt/minimax/minimax-m2.5"))
    }
}
