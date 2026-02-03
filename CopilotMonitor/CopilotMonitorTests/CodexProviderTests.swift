import XCTest
@testable import CopilotMonitor

final class CodexProviderTests: XCTestCase {
    
    var provider: CodexProvider!
    
    override func setUp() {
        super.setUp()
        provider = CodexProvider()
    }
    
    override func tearDown() {
        provider = nil
        super.tearDown()
    }
    
    func testProviderIdentifier() {
        XCTAssertEqual(provider.identifier, .codex)
    }
    
    func testProviderType() {
        XCTAssertEqual(provider.type, .quotaBased)
    }
    
    func testCodexFixtureDecoding() throws {
        let fixture = try loadFixture(named: "codex_response")
        
        guard let dict = fixture as? [String: Any] else {
            XCTFail("Fixture should be a dictionary")
            return
        }
        
        XCTAssertNotNil(dict["plan_type"])
        XCTAssertNotNil(dict["rate_limit"])
        
        guard let rateLimit = dict["rate_limit"] as? [String: Any] else {
            XCTFail("rate_limit should be a dictionary")
            return
        }
        
        guard let primaryWindow = rateLimit["primary_window"] as? [String: Any] else {
            XCTFail("primary_window should be a dictionary")
            return
        }
        
        let usedPercent = primaryWindow["used_percent"] as? Double
        let resetAfterSeconds = primaryWindow["reset_after_seconds"] as? Int
        
        XCTAssertNotNil(usedPercent)
        XCTAssertNotNil(resetAfterSeconds)
        XCTAssertEqual(usedPercent, 9.0)
        XCTAssertEqual(resetAfterSeconds, 7252)
    }
    
    func testProviderUsageQuotaBasedModel() {
        let usage = ProviderUsage.quotaBased(remaining: 91, entitlement: 100, overagePermitted: false)
        
        XCTAssertEqual(usage.usagePercentage, 9.0)
        XCTAssertTrue(usage.isWithinLimit)
        XCTAssertEqual(usage.remainingQuota, 91)
        XCTAssertEqual(usage.totalEntitlement, 100)
        XCTAssertNil(usage.resetTime)
    }
    
    func testProviderUsageStatusMessage() {
        let usage = ProviderUsage.quotaBased(remaining: 91, entitlement: 100, overagePermitted: false)
        
        let message = usage.statusMessage
        XCTAssertTrue(message.contains("91"))
        XCTAssertTrue(message.contains("remaining"))
    }
    
    // MARK: - CodexAuth Struct Decoding Tests

    /// Verify that ~/.codex/auth.json native format with tokens and null API key can be parsed
    func testCodexNativeAuthDecoding() throws {
        let json = """
        {
            "OPENAI_API_KEY": null,
            "tokens": {
                "access_token": "test-access-token",
                "account_id": "test-account-id",
                "id_token": "test-id-token",
                "refresh_token": "test-refresh-token"
            },
            "last_refresh": "2026-01-28T13:20:36.123Z"
        }
        """
        let data = json.data(using: .utf8)!
        let auth = try JSONDecoder().decode(CodexAuth.self, from: data)
        XCTAssertEqual(auth.tokens?.accessToken, "test-access-token")
        XCTAssertEqual(auth.tokens?.accountId, "test-account-id")
        XCTAssertEqual(auth.tokens?.idToken, "test-id-token")
        XCTAssertEqual(auth.tokens?.refreshToken, "test-refresh-token")
        XCTAssertEqual(auth.lastRefresh, "2026-01-28T13:20:36.123Z")
        XCTAssertNil(auth.openaiAPIKey)
    }

    /// Verify that CodexAuth correctly parses when OPENAI_API_KEY is set (non-null)
    func testCodexNativeAuthWithAPIKey() throws {
        let json = """
        {
            "OPENAI_API_KEY": "sk-test-key",
            "tokens": {
                "access_token": "test-access-token",
                "account_id": "test-account-id",
                "id_token": "test-id-token",
                "refresh_token": "test-refresh-token"
            },
            "last_refresh": "2026-01-28T13:20:36.123Z"
        }
        """
        let data = json.data(using: .utf8)!
        let auth = try JSONDecoder().decode(CodexAuth.self, from: data)
        XCTAssertEqual(auth.openaiAPIKey, "sk-test-key")
        XCTAssertEqual(auth.tokens?.accessToken, "test-access-token")
    }

    /// Verify that CodexAuth can parse with only the minimal required fields (tokens with access_token and account_id)
    func testCodexNativeAuthMinimalFields() throws {
        let json = """
        {
            "tokens": {
                "access_token": "test-token",
                "account_id": "test-id"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let auth = try JSONDecoder().decode(CodexAuth.self, from: data)
        XCTAssertEqual(auth.tokens?.accessToken, "test-token")
        XCTAssertEqual(auth.tokens?.accountId, "test-id")
        XCTAssertNil(auth.tokens?.idToken)
        XCTAssertNil(auth.tokens?.refreshToken)
        XCTAssertNil(auth.openaiAPIKey)
        XCTAssertNil(auth.lastRefresh)
    }

    /// Verify that CodexAuth handles empty tokens object gracefully
    func testCodexNativeAuthEmptyTokens() throws {
        let json = """
        {
            "tokens": {}
        }
        """
        let data = json.data(using: .utf8)!
        let auth = try JSONDecoder().decode(CodexAuth.self, from: data)
        XCTAssertNil(auth.tokens?.accessToken)
        XCTAssertNil(auth.tokens?.accountId)
    }

    /// Verify that CodexAuth handles missing tokens key (no tokens at all)
    func testCodexNativeAuthNoTokens() throws {
        let json = """
        {
            "OPENAI_API_KEY": "sk-only-key"
        }
        """
        let data = json.data(using: .utf8)!
        let auth = try JSONDecoder().decode(CodexAuth.self, from: data)
        XCTAssertNil(auth.tokens)
        XCTAssertEqual(auth.openaiAPIKey, "sk-only-key")
    }

    private func loadFixture(named: String) throws -> Any {
        let testBundle = Bundle(for: type(of: self))
        
        guard let url = testBundle.url(forResource: named, withExtension: "json") else {
            throw NSError(domain: "FixtureError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture file not found: \(named)"])
        }
        
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        return json
    }
}
