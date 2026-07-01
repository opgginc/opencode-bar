import XCTest
@testable import OpenCode_Bar

final class ErrorFilterTests: XCTestCase {
    func testNoCredentialsExcludedFromErrorReport() {
        let errors: [ProviderIdentifier: String] = [
            .codex: "Network error: Fetch timeout after 30.0s",
            .nanoGpt: "Authentication failed: Nano-GPT API key not available",
            .claude: "Authentication failed: Anthropic access token not available"
        ]
        let reportable = StatusBarController.reportableErrors(from: errors)
        XCTAssertTrue(reportable.keys.contains(.codex))       // 真错误保留
        XCTAssertFalse(reportable.keys.contains(.nanoGpt))    // 无凭证排除
        XCTAssertFalse(reportable.keys.contains(.claude))     // 无凭证排除
    }

    func testNoSubscriptionExcludedFromErrorReport() {
        let errors: [ProviderIdentifier: String] = [
            .openRouter: "HTTP 500",
            .openCode: "No active subscription"
        ]
        let reportable = StatusBarController.reportableErrors(from: errors)
        XCTAssertTrue(reportable.keys.contains(.openRouter))
        XCTAssertFalse(reportable.keys.contains(.openCode))
    }
}
