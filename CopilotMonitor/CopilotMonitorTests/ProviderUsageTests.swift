import XCTest
@testable import OpenCode_Bar

/// Basic test suite for provider usage models and fixtures
final class ProviderUsageTests: XCTestCase {
    
    // MARK: - Fixture Loading Tests
    
    /// Test that Claude fixture JSON can be loaded and decoded
    func testClaudeFixtureLoading() throws {
        let fixture = try loadFixture(named: "claude_response")
        XCTAssertNotNil(fixture)
        
        // Verify structure
        let dict = fixture as? [String: Any]
        XCTAssertNotNil(dict?["five_hour"])
        XCTAssertNotNil(dict?["seven_day"])
    }
    
    /// Test that Codex fixture JSON can be loaded and decoded
    func testCodexFixtureLoading() throws {
        let fixture = try loadFixture(named: "codex_response")
        XCTAssertNotNil(fixture)
        
        // Verify structure
        let dict = fixture as? [String: Any]
        XCTAssertNotNil(dict?["plan_type"])
        XCTAssertNotNil(dict?["rate_limit"])
    }
    
    /// Test that Copilot fixture JSON can be loaded and decoded
    func testCopilotFixtureLoading() throws {
        let fixture = try loadFixture(named: "copilot_response")
        XCTAssertNotNil(fixture)
        
        // Verify structure
        let dict = fixture as? [String: Any]
        XCTAssertNotNil(dict?["copilot_plan"])
        XCTAssertNotNil(dict?["quota_snapshots"])
    }
    
    /// Test that Gemini fixture JSON can be loaded and decoded
    func testGeminiFixtureLoading() throws {
        let fixture = try loadFixture(named: "gemini_response")
        XCTAssertNotNil(fixture)
        
        // Verify structure
        let dict = fixture as? [String: Any]
        XCTAssertNotNil(dict?["buckets"])
    }

    // MARK: - CLI Formatter Regression Tests

    func testJSONFormatterIncludesZaiDualUsageFields() throws {
        let usage = ProviderUsage.quotaBased(remaining: 30, entitlement: 100, overagePermitted: false)
        let details = DetailedUsage(tokenUsagePercent: 70, mcpUsagePercent: 40)
        let result = ProviderResult(usage: usage, details: details)

        let json = try JSONFormatter.format([.zaiCodingPlan: result])
        let parsed = try parseJSONObject(json)
        let providerDict = try XCTUnwrap(parsed[ProviderIdentifier.zaiCodingPlan.rawValue] as? [String: Any])

        XCTAssertEqual(providerDict["tokenUsagePercent"] as? Double, 70)
        XCTAssertEqual(providerDict["mcpUsagePercent"] as? Double, 40)
    }

    func testJSONFormatterIncludesGeminiAccountAuthSource() throws {
        let accounts = [
            GeminiAccountQuota(
                accountIndex: 0,
                email: "user@example.com",
                remainingPercentage: 85,
                modelBreakdown: ["gemini-2.5-pro": 85],
                authSource: "~/.config/opencode/antigravity-accounts.json",
                earliestReset: nil,
                modelResetTimes: [:]
            )
        ]
        let details = DetailedUsage(geminiAccounts: accounts)
        let usage = ProviderUsage.quotaBased(remaining: 85, entitlement: 100, overagePermitted: false)
        let result = ProviderResult(usage: usage, details: details)

        let json = try JSONFormatter.format([.geminiCLI: result])
        let parsed = try parseJSONObject(json)
        let providerDict = try XCTUnwrap(parsed[ProviderIdentifier.geminiCLI.rawValue] as? [String: Any])
        let accountsJSON = try XCTUnwrap(providerDict["accounts"] as? [[String: Any]])
        let firstAccount = try XCTUnwrap(accountsJSON.first)

        XCTAssertEqual(
            firstAccount["authSource"] as? String,
            "~/.config/opencode/antigravity-accounts.json"
        )
    }

    func testTableFormatterShowsZaiDualPercentWhenBothWindowsExist() {
        let usage = ProviderUsage.quotaBased(remaining: 30, entitlement: 100, overagePermitted: false)
        let details = DetailedUsage(tokenUsagePercent: 70, mcpUsagePercent: 40)
        let result = ProviderResult(usage: usage, details: details)

        let output = TableFormatter.format([.zaiCodingPlan: result])
        XCTAssertTrue(output.contains("70%,40%"))
    }

    func testTableFormatterFallsBackToAggregatePercentForZaiWhenWindowMissing() {
        let usage = ProviderUsage.quotaBased(remaining: 45, entitlement: 100, overagePermitted: false)
        let details = DetailedUsage(tokenUsagePercent: 70, mcpUsagePercent: nil)
        let result = ProviderResult(usage: usage, details: details)

        let output = TableFormatter.format([.zaiCodingPlan: result])
        XCTAssertTrue(output.contains("55%"))
    }

    func testTableFormatterShowsGeminiPercentOnlyForGeminiAccounts() {
        let geminiAccounts = [
            GeminiAccountQuota(
                accountIndex: 0,
                email: "first@example.com",
                remainingPercentage: 30,
                modelBreakdown: ["gemini-2.5-pro": 30],
                authSource: "~/.config/opencode/antigravity-accounts.json",
                earliestReset: nil,
                modelResetTimes: [:]
            ),
            GeminiAccountQuota(
                accountIndex: 1,
                email: "second@example.com",
                remainingPercentage: 50,
                modelBreakdown: ["gemini-2.5-pro": 50],
                authSource: "~/.gemini/oauth_creds.json",
                earliestReset: nil,
                modelResetTimes: [:]
            )
        ]

        let geminiDetails = DetailedUsage(geminiAccounts: geminiAccounts)
        let geminiUsage = ProviderUsage.quotaBased(remaining: 30, entitlement: 100, overagePermitted: false)
        let geminiResult = ProviderResult(usage: geminiUsage, details: geminiDetails)

        let antigravityUsage = ProviderUsage.quotaBased(remaining: 40, entitlement: 100, overagePermitted: false)
        let antigravityResult = ProviderResult(usage: antigravityUsage, details: nil)

        let output = TableFormatter.format([
            .geminiCLI: geminiResult,
            .antigravity: antigravityResult
        ])

        XCTAssertTrue(output.contains("Gemini (#1)"))
        XCTAssertTrue(output.contains("70%"))
        XCTAssertFalse(output.contains("70%,60%"))
    }
    
    // MARK: - Helper Methods
    
    /// Load a JSON fixture file from the test bundle resources
    /// - Parameter named: The name of the fixture file (without .json extension)
    /// - Returns: Decoded JSON object
    private func loadFixture(named: String) throws -> Any {
        let testBundle = Bundle(for: type(of: self))
        
        guard let url = testBundle.url(forResource: named, withExtension: "json") else {
            throw NSError(domain: "FixtureError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture file not found: \(named)"])
        }
        
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        return json
    }

    /// Parse formatter output JSON text into dictionary for assertions.
    private func parseJSONObject(_ jsonString: String) throws -> [String: Any] {
        let data = try XCTUnwrap(jsonString.data(using: .utf8))
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        return try XCTUnwrap(jsonObject as? [String: Any])
    }
}
