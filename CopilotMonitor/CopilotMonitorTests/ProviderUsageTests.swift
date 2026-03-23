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

    func testChutesInferredMonthlySubscriptionCostUsesKnownPlanTiers() {
        XCTAssertEqual(ChutesProvider.inferredMonthlySubscriptionCost(planTier: "Base"), 3)
        XCTAssertEqual(ChutesProvider.inferredMonthlySubscriptionCost(planTier: "Plus"), 10)
        XCTAssertEqual(ChutesProvider.inferredMonthlySubscriptionCost(planTier: "Pro"), 20)
        XCTAssertNil(ChutesProvider.inferredMonthlySubscriptionCost(planTier: "Unknown"))
    }

    func testChutesCalculateMonthlyValueUsedPercent() {
        XCTAssertEqual(ChutesProvider.calculateMonthlyValueUsedPercent(usedUSD: 34, capUSD: 50), 68)
        XCTAssertNil(ChutesProvider.calculateMonthlyValueUsedPercent(usedUSD: nil, capUSD: 50))
        XCTAssertNil(ChutesProvider.calculateMonthlyValueUsedPercent(usedUSD: 10, capUSD: 0))
    }

    func testChutesExtractMonthlyValueUsedUSDPrefersAggregateFields() {
        let payload: [String: Any] = [
            "summary": [
                "total_cost_usd": 34.25
            ],
            "items": [
                ["cost_usd": 10.0],
                ["cost_usd": 20.0]
            ]
        ]

        XCTAssertEqual(ChutesProvider.extractMonthlyValueUsedUSD(from: payload), 34.25)
    }

    func testChutesExtractMonthlyValueUsedUSDSumsRecognizedItemFields() {
        let payload: [String: Any] = [
            "items": [
                ["cost_usd": 12.5],
                ["total_cost": "7.25"],
                ["ignored": 99]
            ]
        ]

        XCTAssertEqual(ChutesProvider.extractMonthlyValueUsedUSD(from: payload), 19.75)
    }

    func testChutesCurrentMonthDateRangeUsesUTCMonthBoundaries() throws {
        let formatter = ISO8601DateFormatter()
        let referenceDate = try XCTUnwrap(formatter.date(from: "2026-03-01T00:30:00+14:00"))

        let range = ChutesProvider.currentMonthDateRangeStrings(referenceDate: referenceDate)

        XCTAssertEqual(range.0, "2026-02-01")
        XCTAssertEqual(range.1, "2026-02-28")
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

    func testProviderDisplayPolicyKeepsClaudeAccountRowsVisibleDuringRateLimitCooldown() {
        let result = ProviderResult(
            usage: .quotaBased(remaining: 20, entitlement: 100, overagePermitted: false),
            details: DetailedUsage(email: "primary@example.com"),
            accounts: [
                ProviderAccountResult(
                    accountIndex: 0,
                    accountId: "primary@example.com",
                    usage: .quotaBased(remaining: 20, entitlement: 100, overagePermitted: false),
                    details: DetailedUsage(email: "primary@example.com")
                ),
                ProviderAccountResult(
                    accountIndex: 1,
                    accountId: "secondary@example.com",
                    usage: .quotaBased(remaining: 0, entitlement: 0, overagePermitted: false),
                    details: DetailedUsage(email: "secondary@example.com", authErrorMessage: "Rate limited")
                )
            ]
        )

        XCTAssertFalse(
            ProviderDisplayPolicy.shouldShowRateLimitedErrorRow(
                identifier: .claude,
                errorMessage: "Rate limited. Retrying in 8m.",
                result: result
            )
        )
    }

    func testProviderDisplayPolicyShowsRateLimitErrorRowWithoutAccountRows() {
        let result = ProviderResult(
            usage: .quotaBased(remaining: 40, entitlement: 100, overagePermitted: false),
            details: DetailedUsage(tokenUsagePercent: 60),
            accounts: nil
        )

        XCTAssertTrue(
            ProviderDisplayPolicy.shouldShowRateLimitedErrorRow(
                identifier: .zaiCodingPlan,
                errorMessage: "Rate limited. Retrying in 8m.",
                result: result
            )
        )
    }

    func testProviderManagerUsesMinimumFetchIntervalForClaude() async {
        let provider = CountingStubProvider(
            identifier: .claude,
            minimumFetchInterval: 10 * 60,
            delayNanoseconds: 0,
            result: makeQuotaResult(remaining: 42)
        )
        let manager = ProviderManager(providers: [provider])

        let first = await manager.fetchAll()
        let second = await manager.fetchAll()
        let fetchCount = await provider.fetchCount()

        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(first.results[.claude]?.usage.remainingQuota, 42)
        XCTAssertEqual(second.results[.claude]?.usage.remainingQuota, 42)
        XCTAssertTrue(second.errors.isEmpty)
    }

    func testProviderManagerDeduplicatesConcurrentFetches() async {
        let provider = CountingStubProvider(
            identifier: .claude,
            minimumFetchInterval: 0,
            delayNanoseconds: 250_000_000,
            result: makeQuotaResult(remaining: 33)
        )
        let manager = ProviderManager(providers: [provider])

        async let first = manager.fetchAll()
        async let second = manager.fetchAll()
        let (firstResult, secondResult) = await (first, second)
        let fetchCount = await provider.fetchCount()

        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(firstResult.results[.claude]?.usage.remainingQuota, 33)
        XCTAssertEqual(secondResult.results[.claude]?.usage.remainingQuota, 33)
    }

    func testProviderManagerKeepsRateLimitStatusDuringCooldownWithoutCache() async {
        let provider = RateLimitedStubProvider(identifier: .claude, minimumFetchInterval: 10 * 60)
        let manager = ProviderManager(providers: [provider])

        let first = await manager.fetchAll()
        let second = await manager.fetchAll()
        let fetchCount = await provider.fetchCount()

        XCTAssertEqual(fetchCount, 1)
        XCTAssertNil(first.results[.claude])
        XCTAssertEqual(first.errors[.claude], "Network error: Rate limited. Please try again later.")
        XCTAssertNil(second.results[.claude])
        XCTAssertTrue(second.errors[.claude]?.contains("Rate limited") == true)
        XCTAssertTrue(second.errors[.claude]?.contains("Retrying in") == true)
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

    private func makeQuotaResult(remaining: Int) -> ProviderResult {
        ProviderResult(
            usage: .quotaBased(remaining: remaining, entitlement: 100, overagePermitted: false),
            details: nil
        )
    }
}

private actor StubProviderState {
    private var fetchCount = 0

    func incrementFetchCount() {
        fetchCount += 1
    }

    func currentFetchCount() -> Int {
        fetchCount
    }
}

private final class CountingStubProvider: ProviderProtocol {
    let identifier: ProviderIdentifier
    let type: ProviderType = .quotaBased
    let minimumFetchInterval: TimeInterval

    private let delayNanoseconds: UInt64
    private let result: ProviderResult
    private let state = StubProviderState()

    init(
        identifier: ProviderIdentifier,
        minimumFetchInterval: TimeInterval,
        delayNanoseconds: UInt64,
        result: ProviderResult
    ) {
        self.identifier = identifier
        self.minimumFetchInterval = minimumFetchInterval
        self.delayNanoseconds = delayNanoseconds
        self.result = result
    }

    func fetch() async throws -> ProviderResult {
        await state.incrementFetchCount()
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return result
    }

    func fetchCount() async -> Int {
        await state.currentFetchCount()
    }
}

private final class RateLimitedStubProvider: ProviderProtocol {
    let identifier: ProviderIdentifier
    let type: ProviderType = .quotaBased
    let minimumFetchInterval: TimeInterval

    private let state = StubProviderState()

    init(identifier: ProviderIdentifier, minimumFetchInterval: TimeInterval) {
        self.identifier = identifier
        self.minimumFetchInterval = minimumFetchInterval
    }

    func fetch() async throws -> ProviderResult {
        await state.incrementFetchCount()
        throw ProviderError.networkError("Rate limited. Please try again later.")
    }

    func fetchCount() async -> Int {
        await state.currentFetchCount()
    }
}
