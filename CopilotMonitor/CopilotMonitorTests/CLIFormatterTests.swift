import XCTest
@testable import OpenCode_Bar

final class CLIFormatterTests: XCTestCase {
    
    // MARK: - ProviderIdentifier rawValue Tests
    
    func testProviderIdentifierRawValues() {
        XCTAssertEqual(ProviderIdentifier.openRouter.rawValue, "openrouter")
        XCTAssertEqual(ProviderIdentifier.openCodeZen.rawValue, "opencode_zen")
        XCTAssertEqual(ProviderIdentifier.geminiCLI.rawValue, "gemini_cli")
        XCTAssertEqual(ProviderIdentifier.claude.rawValue, "claude")
        XCTAssertEqual(ProviderIdentifier.codex.rawValue, "codex")
        XCTAssertEqual(ProviderIdentifier.kimi.rawValue, "kimi")
        XCTAssertEqual(ProviderIdentifier.antigravity.rawValue, "antigravity")
        XCTAssertEqual(ProviderIdentifier.copilot.rawValue, "copilot")
    }
    
    func testProviderIdentifierDisplayNames() {
        XCTAssertEqual(ProviderIdentifier.openRouter.displayName, "OpenRouter")
        XCTAssertEqual(ProviderIdentifier.openCodeZen.displayName, "OpenCode Zen")
        XCTAssertEqual(ProviderIdentifier.geminiCLI.displayName, "Gemini CLI")
        XCTAssertEqual(ProviderIdentifier.claude.displayName, "Claude")
        XCTAssertEqual(ProviderIdentifier.kimi.displayName, "Kimi for Coding")
    }
    
    // MARK: - ProviderUsage Tests
    
    func testPayAsYouGoUsagePercentage() {
        let usage = ProviderUsage.payAsYouGo(utilization: 50.0, cost: 10.0, resetsAt: nil)
        XCTAssertEqual(usage.usagePercentage, 50.0)
    }
    
    func testQuotaBasedUsagePercentage() {
        let usage = ProviderUsage.quotaBased(remaining: 30, entitlement: 100, overagePermitted: false)
        XCTAssertEqual(usage.usagePercentage, 70.0)
    }
    
    func testQuotaBasedZeroEntitlement() {
        let usage = ProviderUsage.quotaBased(remaining: 0, entitlement: 0, overagePermitted: false)
        XCTAssertEqual(usage.usagePercentage, 0.0)
    }
    
    func testQuotaBasedOverage() {
        let usage = ProviderUsage.quotaBased(remaining: -10, entitlement: 100, overagePermitted: true)
        XCTAssertEqual(usage.usagePercentage, 110.0)
    }
    
    // MARK: - ProviderUsage Limit Tests
    
    func testPayAsYouGoIsWithinLimit() {
        let withinLimit = ProviderUsage.payAsYouGo(utilization: 50.0, cost: nil, resetsAt: nil)
        XCTAssertTrue(withinLimit.isWithinLimit)
        
        let atLimit = ProviderUsage.payAsYouGo(utilization: 100.0, cost: nil, resetsAt: nil)
        XCTAssertTrue(atLimit.isWithinLimit)
        
        let overLimit = ProviderUsage.payAsYouGo(utilization: 150.0, cost: nil, resetsAt: nil)
        XCTAssertFalse(overLimit.isWithinLimit)
    }
    
    func testQuotaBasedIsWithinLimit() {
        let withinLimit = ProviderUsage.quotaBased(remaining: 50, entitlement: 100, overagePermitted: false)
        XCTAssertTrue(withinLimit.isWithinLimit)
        
        let atLimit = ProviderUsage.quotaBased(remaining: 0, entitlement: 100, overagePermitted: false)
        XCTAssertTrue(atLimit.isWithinLimit)
        
        let overLimit = ProviderUsage.quotaBased(remaining: -10, entitlement: 100, overagePermitted: false)
        XCTAssertFalse(overLimit.isWithinLimit)
    }
    
    // MARK: - GeminiAccountQuota Tests
    
    func testGeminiAccountQuotaCreation() {
        let resetDate = ISO8601DateFormatter().date(from: "2026-01-30T17:05:02Z")
        let modelResetTimes: [String: Date] = [
            "gemini-2.5-pro": resetDate!,
            "gemini-2.5-flash": resetDate!
        ]
        let account = GeminiAccountQuota(
            accountIndex: 0,
            email: "test@example.com",
            accountId: "gemini-sub-123",
            remainingPercentage: 85.0,
            modelBreakdown: ["gemini-2.5-pro": 80.0, "gemini-2.5-flash": 90.0],
            authSource: "~/.config/opencode/antigravity-accounts.json",
            earliestReset: resetDate,
            modelResetTimes: modelResetTimes
        )
        
        XCTAssertEqual(account.accountIndex, 0)
        XCTAssertEqual(account.email, "test@example.com")
        XCTAssertEqual(account.accountId, "gemini-sub-123")
        XCTAssertEqual(account.remainingPercentage, 85.0)
        XCTAssertEqual(account.modelBreakdown["gemini-2.5-pro"], 80.0)
        XCTAssertEqual(account.modelBreakdown["gemini-2.5-flash"], 90.0)
        XCTAssertEqual(account.earliestReset, resetDate)
        XCTAssertEqual(account.modelResetTimes["gemini-2.5-pro"], resetDate)
        XCTAssertEqual(account.modelResetTimes["gemini-2.5-flash"], resetDate)
    }
    
    func testGeminiAccountQuotaCodable() throws {
        let resetDate = ISO8601DateFormatter().date(from: "2026-01-30T17:05:02Z")
        let modelResetTimes: [String: Date] = ["gemini-2.5-pro": resetDate!]
        let original = GeminiAccountQuota(
            accountIndex: 1,
            email: "user@company.com",
            accountId: "gemini-sub-456",
            remainingPercentage: 100.0,
            modelBreakdown: ["gemini-2.5-pro": 100.0],
            authSource: "test",
            earliestReset: resetDate,
            modelResetTimes: modelResetTimes
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(GeminiAccountQuota.self, from: data)
        
        XCTAssertEqual(decoded.accountIndex, original.accountIndex)
        XCTAssertEqual(decoded.email, original.email)
        XCTAssertEqual(decoded.accountId, original.accountId)
        XCTAssertEqual(decoded.remainingPercentage, original.remainingPercentage)
        XCTAssertEqual(decoded.modelBreakdown, original.modelBreakdown)
        XCTAssertEqual(decoded.earliestReset, original.earliestReset)
        XCTAssertEqual(decoded.modelResetTimes, original.modelResetTimes)
    }
    
    // MARK: - DetailedUsage with GeminiAccounts Tests
    
    func testDetailedUsageWithGeminiAccounts() {
        let accounts = [
            GeminiAccountQuota(accountIndex: 0, email: "a@test.com", remainingPercentage: 100, modelBreakdown: [:], authSource: "test", earliestReset: nil, modelResetTimes: [:]),
            GeminiAccountQuota(accountIndex: 1, email: "b@test.com", remainingPercentage: 50, modelBreakdown: [:], authSource: "test", earliestReset: nil, modelResetTimes: [:])
        ]
        
        let details = DetailedUsage(geminiAccounts: accounts)
        
        XCTAssertNotNil(details.geminiAccounts)
        XCTAssertEqual(details.geminiAccounts?.count, 2)
        XCTAssertEqual(details.geminiAccounts?[0].email, "a@test.com")
        XCTAssertEqual(details.geminiAccounts?[1].email, "b@test.com")
    }
    
    // MARK: - ProviderResult Tests
    
    func testProviderResultPayAsYouGo() {
        let usage = ProviderUsage.payAsYouGo(utilization: 0, cost: 37.42, resetsAt: nil)
        let result = ProviderResult(usage: usage, details: nil)
        
        switch result.usage {
        case .payAsYouGo(_, let cost, _):
            XCTAssertEqual(cost, 37.42)
        case .quotaBased:
            XCTFail("Expected payAsYouGo")
        }
    }
    
    func testProviderResultQuotaBased() {
        let usage = ProviderUsage.quotaBased(remaining: 77, entitlement: 100, overagePermitted: false)
        let result = ProviderResult(usage: usage, details: nil)
        
        switch result.usage {
        case .payAsYouGo:
            XCTFail("Expected quotaBased")
        case .quotaBased(let remaining, let entitlement, let overagePermitted):
            XCTAssertEqual(remaining, 77)
            XCTAssertEqual(entitlement, 100)
            XCTAssertFalse(overagePermitted)
        }
    }
    
    func testProviderResultWithGeminiDetails() {
        let accounts = [
            GeminiAccountQuota(accountIndex: 0, email: "user1@gmail.com", remainingPercentage: 100, modelBreakdown: [:], authSource: "test", earliestReset: nil, modelResetTimes: [:]),
            GeminiAccountQuota(accountIndex: 1, email: "user2@company.com", remainingPercentage: 85, modelBreakdown: [:], authSource: "test", earliestReset: nil, modelResetTimes: [:])
        ]
        let details = DetailedUsage(geminiAccounts: accounts)
        let usage = ProviderUsage.quotaBased(remaining: 85, entitlement: 100, overagePermitted: false)
        let result = ProviderResult(usage: usage, details: details)
        
        XCTAssertNotNil(result.details?.geminiAccounts)
        XCTAssertEqual(result.details?.geminiAccounts?.count, 2)
    }
}
