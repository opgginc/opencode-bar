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
        XCTAssertEqual(ProviderIdentifier.nanoGpt.rawValue, "nano_gpt")
    }
    
    func testProviderIdentifierDisplayNames() {
        XCTAssertEqual(ProviderIdentifier.openRouter.displayName, "OpenRouter")
        XCTAssertEqual(ProviderIdentifier.openCodeZen.displayName, "OpenCode Zen")
        XCTAssertEqual(ProviderIdentifier.geminiCLI.displayName, "Gemini CLI")
        XCTAssertEqual(ProviderIdentifier.claude.displayName, "Claude")
        XCTAssertEqual(ProviderIdentifier.kimi.displayName, "Kimi for Coding")
        XCTAssertEqual(ProviderIdentifier.nanoGpt.displayName, "Nano-GPT")
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

    // MARK: - TableFormatter Tests

    // MARK: Single-account separator width

    /// The separator line must be exactly providerWidth + typeWidth(15) + usageWidth(10) + metricsWidth + 6
    /// for a single provider result.
    func testTableFormatterSeparatorWidthSingleAccount() {
        let usage = ProviderUsage.quotaBased(remaining: 50, entitlement: 100, overagePermitted: false)
        let result = ProviderResult(usage: usage, details: nil)
        let output = TableFormatter.format([.claude: result])

        let lines = output.components(separatedBy: "\n")
        // Line 0 = header, line 1 = separator
        guard lines.count >= 2 else {
            XCTFail("Expected at least 2 lines in table output")
            return
        }
        let header = lines[0]
        let separator = lines[1]

        // Separator must be exactly as wide as the header (both computed from the same widths)
        XCTAssertEqual(separator.count, header.count,
                       "Separator width (\(separator.count)) must equal header width (\(header.count))")
        // Separator must consist solely of the box-drawing character ─
        XCTAssertTrue(separator.unicodeScalars.allSatisfy { $0.value == 0x2500 },
                      "Separator must contain only ─ characters")
    }

    // MARK: Multi-account separator width grows with metrics content

    /// When a generic multi-account result has long auth-source labels the separator
    /// must be wide enough to accommodate the longest metrics string.
    func testTableFormatterSeparatorWidthGrowsForLongAuthSource() {
        let longAuthSource = "Browser Cookies (Chrome/Brave/Arc/Edge)"
        let accountDetails = DetailedUsage(authSource: longAuthSource)
        let account = ProviderAccountResult(
            accountIndex: 0,
            accountId: "user1",
            usage: .quotaBased(remaining: 900, entitlement: 1500, overagePermitted: true),
            details: accountDetails
        )
        let aggregateUsage = ProviderUsage.quotaBased(remaining: 900, entitlement: 1500, overagePermitted: true)
        let result = ProviderResult(usage: aggregateUsage, details: nil, accounts: [account])

        let output = TableFormatter.format([.copilot: result])
        let lines = output.components(separatedBy: "\n")
        guard lines.count >= 2 else {
            XCTFail("Expected at least 2 lines in table output")
            return
        }

        let separator = lines[1]
        // The data row should contain the shortened auth source (just the last component of a
        // non-path string passes through unchanged since it has no leading / or ~)
        // longAuthSource has no leading / or ~, so it appears verbatim in brackets
        let dataRows = lines.dropFirst(2).filter { !$0.isEmpty }
        guard let dataRow = dataRows.first else {
            XCTFail("Expected at least one data row")
            return
        }
        XCTAssertTrue(dataRow.contains("[\(longAuthSource)]"),
                      "Data row should contain the auth source label verbatim")
        // The separator must be at least as long as the data row
        XCTAssertGreaterThanOrEqual(separator.count, dataRow.count,
                                    "Separator must be wide enough to span the longest data row")
    }

    // MARK: accountLabel – accountId vs. fallback index

    /// When an account has an `accountId`, the label uses it; otherwise #N index is used.
    func testTableFormatterAccountLabelUsesAccountId() {
        let accountWithId = ProviderAccountResult(
            accountIndex: 0,
            accountId: "alice",
            usage: .quotaBased(remaining: 500, entitlement: 1500, overagePermitted: false),
            details: nil
        )
        let accountWithoutId = ProviderAccountResult(
            accountIndex: 1,
            accountId: nil,
            usage: .quotaBased(remaining: 800, entitlement: 1500, overagePermitted: false),
            details: nil
        )
        let aggregateUsage = ProviderUsage.quotaBased(remaining: 500, entitlement: 1500, overagePermitted: false)
        let result = ProviderResult(usage: aggregateUsage, details: nil, accounts: [accountWithId, accountWithoutId])

        let output = TableFormatter.format([.copilot: result])

        // Account with ID should appear as "Copilot (alice)"
        XCTAssertTrue(output.contains("Copilot (alice)"),
                      "Row for account with accountId should use the id: got\n\(output)")
        // Account without ID should fall back to "Copilot (#2)"
        XCTAssertTrue(output.contains("Copilot (#2)"),
                      "Row for account without accountId should use #N index: got\n\(output)")
    }

    // MARK: shortenAuthSource – file paths are shortened, non-paths pass through

    func testTableFormatterShortenAuthSourceAbsolutePath() {
        let absPath = "/Users/alice/.config/some-tool/credentials.json"
        let accountDetails = DetailedUsage(authSource: absPath)
        let account = ProviderAccountResult(
            accountIndex: 0,
            accountId: "alice",
            usage: .quotaBased(remaining: 100, entitlement: 200, overagePermitted: false),
            details: accountDetails
        )
        let result = ProviderResult(
            usage: .quotaBased(remaining: 100, entitlement: 200, overagePermitted: false),
            details: nil,
            accounts: [account]
        )
        let output = TableFormatter.format([.copilot: result])

        // Full path should NOT appear; just the filename should
        XCTAssertFalse(output.contains(absPath),
                       "Full absolute path should be shortened in table output")
        XCTAssertTrue(output.contains("[credentials.json]"),
                      "Only the filename component should appear in table output: got\n\(output)")
    }

    func testTableFormatterShortenAuthSourceTildePath() {
        let tildePath = "~/.local/share/opencode/auth.json"
        let accountDetails = DetailedUsage(authSource: tildePath)
        let account = ProviderAccountResult(
            accountIndex: 0,
            accountId: "bob",
            usage: .quotaBased(remaining: 300, entitlement: 1000, overagePermitted: false),
            details: accountDetails
        )
        let result = ProviderResult(
            usage: .quotaBased(remaining: 300, entitlement: 1000, overagePermitted: false),
            details: nil,
            accounts: [account]
        )
        let output = TableFormatter.format([.copilot: result])

        XCTAssertFalse(output.contains(tildePath),
                       "Tilde path should be shortened in table output")
        XCTAssertTrue(output.contains("[auth.json]"),
                      "Only the filename component of a tilde path should appear: got\n\(output)")
    }

    func testTableFormatterShortenAuthSourceNonPathPassesThrough() {
        let nonPath = "Browser Cookies (Chrome/Brave/Arc/Edge)"
        let accountDetails = DetailedUsage(authSource: nonPath)
        let account = ProviderAccountResult(
            accountIndex: 0,
            accountId: "carol",
            usage: .quotaBased(remaining: 200, entitlement: 500, overagePermitted: false),
            details: accountDetails
        )
        let result = ProviderResult(
            usage: .quotaBased(remaining: 200, entitlement: 500, overagePermitted: false),
            details: nil,
            accounts: [account]
        )
        let output = TableFormatter.format([.copilot: result])

        XCTAssertTrue(output.contains("[\(nonPath)]"),
                      "Non-path auth source should pass through unchanged: got\n\(output)")
    }

    // MARK: Gemini multi-account separator width

    func testTableFormatterSeparatorWidthGeminiMultiAccount() {
        let accounts = [
            GeminiAccountQuota(accountIndex: 0, email: "user1@gmail.com", accountId: "sub-abc", remainingPercentage: 80, modelBreakdown: [:], authSource: "test", earliestReset: nil, modelResetTimes: [:]),
            GeminiAccountQuota(accountIndex: 1, email: "a-very-long-user@example.com", accountId: "sub-xyz", remainingPercentage: 60, modelBreakdown: [:], authSource: "test", earliestReset: nil, modelResetTimes: [:])
        ]
        let details = DetailedUsage(geminiAccounts: accounts)
        let usage = ProviderUsage.quotaBased(remaining: 60, entitlement: 100, overagePermitted: false)
        let result = ProviderResult(usage: usage, details: details)

        let output = TableFormatter.format([.geminiCLI: result])
        let lines = output.components(separatedBy: "\n")
        guard lines.count >= 2 else {
            XCTFail("Expected at least 2 lines in table output")
            return
        }

        let separator = lines[1]
        let dataRows = lines.dropFirst(2).filter { !$0.isEmpty }

        for row in dataRows {
            XCTAssertLessThanOrEqual(row.count, separator.count,
                                     "Separator must be at least as wide as every data row. Row: \(row)")
        }
    }
}
