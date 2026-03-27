import XCTest
@testable import CopilotMonitor

final class OpenCodeAuthDecodingTests: XCTestCase {
    func testDecodingDoesNotFailWhenSomeEntriesHaveUnexpectedSchema() throws {
        // openai is stored as an API key object in this fixture (not OAuth).
        // The decoder should still succeed and parse other supported entries.
        let json = """
        {
            "openai": { "type": "apiKey", "key": "sk-test-openai" },
            "openrouter": { "key": "or-test-key" },
            "github-copilot": {
                "type": "oauth",
                "access": "gho_test",
                "refresh": "gho_refresh",
                "expires": 0
            }
        }
        """

        let data = try XCTUnwrap(json.data(using: .utf8))
        let auth = try JSONDecoder().decode(OpenCodeAuth.self, from: data)

        XCTAssertNil(auth.openai, "OpenAI entry is not OAuth, so it should be ignored instead of failing decoding")
        XCTAssertEqual(auth.openrouter?.key, "or-test-key")
        XCTAssertEqual(auth.githubCopilot?.access, "gho_test")
    }

    func testAPIKeyCanDecodeFromStringValue() throws {
        let json = """
        {
            "openrouter": "or-raw-string-key"
        }
        """

        let data = try XCTUnwrap(json.data(using: .utf8))
        let auth = try JSONDecoder().decode(OpenCodeAuth.self, from: data)
        XCTAssertEqual(auth.openrouter?.key, "or-raw-string-key")
    }

    func testMiniMaxCodingPlanAPIKeyDecodes() throws {
        let json = """
        {
            "minimax-coding-plan": {
                "type": "api",
                "key": "minimax-test-key"
            }
        }
        """

        let data = try XCTUnwrap(json.data(using: .utf8))
        let auth = try JSONDecoder().decode(OpenCodeAuth.self, from: data)

        XCTAssertEqual(auth.minimaxCodingPlan?.key, "minimax-test-key")
    }

    func testOAuthDecodesWithFlexibleExpiresAndAccountIdTypes() throws {
        let json = """
        {
            "openai": {
                "type": "oauth",
                "access": "eyJ.test",
                "refresh": "rt_test",
                "expires": "1770563557150",
                "accountId": 123
            }
        }
        """

        let data = try XCTUnwrap(json.data(using: .utf8))
        let auth = try JSONDecoder().decode(OpenCodeAuth.self, from: data)

        XCTAssertEqual(auth.openai?.access, "eyJ.test")
        XCTAssertEqual(auth.openai?.expires, 1_770_563_557_150)
        XCTAssertEqual(auth.openai?.accountId, "123")
    }
}
