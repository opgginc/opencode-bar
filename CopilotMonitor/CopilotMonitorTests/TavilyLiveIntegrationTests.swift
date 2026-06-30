import XCTest
@testable import OpenCode_Bar

/// Live integration test — hits the real ai-infra keys.local.yaml and the real
/// Tavily API. Skipped automatically when the yaml file is absent (CI / other machines).
final class TavilyLiveIntegrationTests: XCTestCase {
    func testRealMultiKeyFetchReturnsMultipleAccounts() async throws {
        let yamlURL = AIInfraYamlKeySource.defaultURL()
        guard FileManager.default.fileExists(atPath: yamlURL.path) else {
            throw XCTSkip("ai-infra keys.local.yaml not present; skipping live test")
        }

        let provider = TavilySearchProvider()
        let result = try await provider.fetch()

        guard let accounts = result.accounts else {
            XCTFail("expected accounts to be populated for multi-key Tavily")
            return
        }

        print("=== TAVILY LIVE: \(accounts.count) accounts ===")
        for acc in accounts {
            print("  \(acc.accountId ?? "?"): \(String(format: "%.1f", acc.usage.usagePercentage))% used")
        }

        XCTAssertGreaterThan(accounts.count, 1, "expected multiple Tavily keys from ai-infra")
        for acc in accounts {
            XCTAssertNotNil(acc.accountId)
        }
    }
}
