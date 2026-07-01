import XCTest
@testable import OpenCode_Bar

final class ErrorClassificationTests: XCTestCase {
    func testAntigravityNoAccountIsNoCredentials() {
        let msg = "Antigravity cache unavailable and no enabled antigravity-accounts.json account with project ID was found"
        XCTAssertFalse(StatusBarController.reportableErrors(from: [.antigravity: msg]).keys.contains(.antigravity))
    }
}
