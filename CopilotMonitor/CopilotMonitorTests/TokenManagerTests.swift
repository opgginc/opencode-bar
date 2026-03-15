import XCTest
@testable import OpenCode_Bar

final class TokenManagerTests: XCTestCase {

    func testReadClaudeAnthropicAuthFilesIncludesDisabledAccounts() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let accountsPath = tempDirectory.appendingPathComponent("accounts.json")

        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let json = """
        {
          "version": 1,
          "accounts": [
            {
              "id": "account-primary",
              "type": "oauth",
              "refresh": "refresh-1",
              "access": "access-1",
              "expires": 1770563557150,
              "label": "Primary",
              "enabled": true
            },
            {
              "id": "account-disabled",
              "type": "oauth",
              "refresh": "refresh-2",
              "access": "access-2",
              "expires": 1770563557150,
              "label": "Disabled",
              "enabled": false
            }
          ],
          "activeAccountID": "account-primary",
          "updatedAt": 1770563557150
        }
        """

        try XCTUnwrap(json.data(using: .utf8)).write(to: accountsPath)

        let accounts = TokenManager.shared.readClaudeAnthropicAuthFiles(at: [accountsPath])

        XCTAssertEqual(accounts.count, 2)

        let primaryAccount = try XCTUnwrap(accounts.first)
        XCTAssertEqual(primaryAccount.accessToken, "access-1")
        XCTAssertEqual(primaryAccount.accountId, "account-primary")
        XCTAssertEqual(primaryAccount.refreshToken, "refresh-1")
        XCTAssertEqual(primaryAccount.authSource, accountsPath.path)
        XCTAssertEqual(primaryAccount.source, .opencodeAuth)
        XCTAssertEqual(primaryAccount.sourceLabels, ["OpenCode"])

        let disabledAccount = try XCTUnwrap(accounts.last)
        XCTAssertEqual(disabledAccount.accessToken, "access-2")
        XCTAssertEqual(disabledAccount.accountId, "account-disabled")
        XCTAssertEqual(disabledAccount.refreshToken, "refresh-2")
        XCTAssertEqual(disabledAccount.authSource, accountsPath.path)
        XCTAssertEqual(disabledAccount.source, .opencodeAuth)
        XCTAssertEqual(disabledAccount.sourceLabels, ["OpenCode"])

        let expiresAt = try XCTUnwrap(primaryAccount.expiresAt)
        XCTAssertEqual(expiresAt.timeIntervalSince1970, 1_770_563_557.15, accuracy: 0.01)
    }
}
