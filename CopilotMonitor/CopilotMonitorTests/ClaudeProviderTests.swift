import XCTest
@testable import OpenCode_Bar

final class ClaudeProviderTests: XCTestCase {
    
    func testProviderIdentifier() {
        let provider = ClaudeProvider()
        XCTAssertEqual(provider.identifier, .claude)
    }
    
    func testProviderType() {
        let provider = ClaudeProvider()
        XCTAssertEqual(provider.type, .quotaBased)
    }
    
    func testClaudeUsageResponseDecoding() throws {
        let fixtureData = loadFixture(named: "claude_response.json")
        let decoder = JSONDecoder()
        let response = try decoder.decode(ClaudeUsageResponse.self, from: fixtureData)
        
        XCTAssertNotNil(response.seven_day)
        XCTAssertEqual(response.seven_day?.utilization, 4.0)
        XCTAssertEqual(response.seven_day?.resets_at, "2026-02-05T15:00:00Z")
    }
    
    func testClaudeUsageResponseWithHighUtilization() throws {
        let customResponse = """
        {
          "seven_day": {
            "utilization": 85.5,
            "resets_at": "2026-02-05T15:00:00Z"
          }
        }
        """
        let decoder = JSONDecoder()
        let response = try decoder.decode(ClaudeUsageResponse.self, from: customResponse.data(using: .utf8)!)
        
        XCTAssertEqual(response.seven_day?.utilization, 85.5)
    }
    
    func testClaudeUsageResponseWithNullResetTime() throws {
        let customResponse = """
        {
          "seven_day": {
            "utilization": 42.0,
            "resets_at": null
          }
        }
        """
        let decoder = JSONDecoder()
        let response = try decoder.decode(ClaudeUsageResponse.self, from: customResponse.data(using: .utf8)!)
        
        XCTAssertEqual(response.seven_day?.utilization, 42.0)
        XCTAssertNil(response.seven_day?.resets_at)
    }
    
    func testClaudeUsageResponseMissingSevenDay() throws {
        let responseWithoutSevenDay = """
        {
          "five_hour": {
            "utilization": 23.0,
            "resets_at": "2026-01-29T20:00:00Z"
          }
        }
        """
        let decoder = JSONDecoder()
        let response = try decoder.decode(ClaudeUsageResponse.self, from: responseWithoutSevenDay.data(using: .utf8)!)
        
        XCTAssertNil(response.seven_day)
    }

    func testClaudeOAuthRequestPolicyUsesClaudeCodeUserAgentAndDisablesCookies() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://api.anthropic.com/api/oauth/usage")))

        ClaudeOAuthRequestPolicy.applyHeaders(
            to: &request,
            accessToken: "test-access-token",
            environment: [:]
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "claude-code/2.1.80")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.timeoutInterval, 10, accuracy: 0.001)
    }

    func testClaudeOAuthRequestPolicyPrefersExplicitUserAgentOverride() {
        let userAgent = ClaudeOAuthRequestPolicy.usageUserAgent(
            environment: [
                "ANTHROPIC_CODE_USER_AGENT": "claude-code-custom/9.9.9",
                "ANTHROPIC_CLI_VERSION": "3.0.0"
            ]
        )

        XCTAssertEqual(userAgent, "claude-code-custom/9.9.9")
    }

    func testClaudeOAuthRequestPolicyUsesVersionOverrideForUserAgent() {
        let userAgent = ClaudeOAuthRequestPolicy.usageUserAgent(
            environment: ["ANTHROPIC_CLI_VERSION": "3.0.0"]
        )

        XCTAssertEqual(userAgent, "claude-code/3.0.0")
    }
    
    private func loadFixture(named: String) -> Data {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: named, withExtension: nil) else {
            fatalError("Fixture \(named) not found")
        }
        guard let data = try? Data(contentsOf: url) else {
            fatalError("Could not load fixture \(named)")
        }
        return data
    }
}
