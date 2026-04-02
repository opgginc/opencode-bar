import XCTest
@testable import OpenCode_Bar

final class TokenManagerTests: XCTestCase {

    func testCodexEndpointConfigurationDefaultsToChatGPT() {
        let configuration = TokenManager.shared.codexEndpointConfiguration(from: nil)

        XCTAssertEqual(configuration, CodexEndpointConfiguration(
            mode: .directChatGPT,
            source: "Default ChatGPT usage endpoint"
        ))
    }

    func testCodexEndpointConfigurationDerivesExternalUsageURLFromBaseURL() {
        let configuration = TokenManager.shared.codexEndpointConfiguration(
            from: [
                "provider": [
                    "openai": [
                        "options": [
                            "baseURL": "https://codex.2631.eu/v1"
                        ]
                    ]
                ]
            ],
            sourcePath: "/tmp/opencode.json"
        )

        XCTAssertEqual(configuration, CodexEndpointConfiguration(
            mode: .external(usageURL: URL(string: "https://codex.2631.eu/api/codex/usage")!),
            source: "/tmp/opencode.json"
        ))
    }

    func testCodexEndpointConfigurationPrefersExplicitUsageOverride() {
        let configuration = TokenManager.shared.codexEndpointConfiguration(
            from: [
                "provider": [
                    "openai": [
                        "options": [
                            "baseURL": "https://codex.2631.eu/v1"
                        ]
                    ]
                ],
                "opencode-bar": [
                    "codex": [
                        "usageURL": "https://custom.example.com/api/codex/usage"
                    ]
                ]
            ],
            sourcePath: "/tmp/opencode.json"
        )

        XCTAssertEqual(configuration, CodexEndpointConfiguration(
            mode: .external(usageURL: URL(string: "https://custom.example.com/api/codex/usage")!),
            source: "/tmp/opencode.json"
        ))
    }

    func testCodexEndpointConfigurationIgnoresMalformedUsageOverrideAndFallsBackToBaseURL() {
        let configuration = TokenManager.shared.codexEndpointConfiguration(
            from: [
                "provider": [
                    "openai": [
                        "options": [
                            "baseURL": "https://codex.2631.eu/v1"
                        ]
                    ]
                ],
                "opencode-bar": [
                    "codex": [
                        "usageURL": "://bad-url"
                    ]
                ]
            ],
            sourcePath: "/tmp/opencode.json"
        )

        XCTAssertEqual(configuration, CodexEndpointConfiguration(
            mode: .external(usageURL: URL(string: "https://codex.2631.eu/api/codex/usage")!),
            source: "/tmp/opencode.json"
        ))
    }

    func testCodexEndpointConfigurationFallsBackToDefaultWhenConfigIsMalformed() {
        let configuration = TokenManager.shared.codexEndpointConfiguration(
            from: [
                "provider": [
                    "openai": [
                        "options": [
                            "baseURL": "://bad-url"
                        ]
                    ]
                ]
            ],
            sourcePath: "/tmp/opencode.json"
        )

        XCTAssertEqual(configuration, CodexEndpointConfiguration(
            mode: .directChatGPT,
            source: "Default ChatGPT usage endpoint"
        ))
    }

    func testGetOpenAIAccountsIncludesOpenCodeAPIKeyAccount() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let xdgDataHome = tempDirectory.path
        let authDirectory = tempDirectory
            .appendingPathComponent("opencode", isDirectory: true)
        let authPath = authDirectory.appendingPathComponent("auth.json")

        try fileManager.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let originalXDGDataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
        if let originalXDGDataHome {
            setenv("XDG_DATA_HOME", originalXDGDataHome, 1)
        } else {
            unsetenv("XDG_DATA_HOME")
        }
        defer {
            if let originalXDGDataHome {
                setenv("XDG_DATA_HOME", originalXDGDataHome, 1)
            } else {
                unsetenv("XDG_DATA_HOME")
            }
            TokenManager.shared.clearOpenCodeAuthCacheForTesting()
        }

        let json = """
        {
          "openai": {
            "type": "apiKey",
            "key": "sk-openai-api-key"
          }
        }
        """
        try XCTUnwrap(json.data(using: .utf8)).write(to: authPath)

        setenv("XDG_DATA_HOME", xdgDataHome, 1)
        TokenManager.shared.clearOpenCodeAuthCacheForTesting()

        let accounts = TokenManager.shared.getOpenAIAccounts()
        let apiKeyAccount = try XCTUnwrap(
            accounts.first(where: {
                $0.accessToken == "sk-openai-api-key" &&
                    $0.authSource == authPath.path &&
                    $0.sourceLabels == ["OpenCode (API Key)"]
            })
        )

        XCTAssertNil(apiKeyAccount.accountId)
        XCTAssertNil(apiKeyAccount.externalUsageAccountId)
        XCTAssertNil(apiKeyAccount.email)
        XCTAssertEqual(apiKeyAccount.source, .opencodeAuth)
    }

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

    func testCodexProviderUsesChatGPTAccountIDForCodexLBInExternalMode() {
        let provider = CodexProvider()
        let account = OpenAIAuthAccount(
            accessToken: "token",
            accountId: "codex-lb-internal-id",
            externalUsageAccountId: "chatgpt-account-id",
            email: "user@example.com",
            authSource: "codex-lb",
            sourceLabels: ["Codex LB"],
            source: .codexLB
        )

        let accountID = provider.codexRequestAccountID(
            for: account,
            endpointMode: .external(usageURL: URL(string: "https://codex.example.com/api/codex/usage")!)
        )

        XCTAssertEqual(accountID, "chatgpt-account-id")
    }

    func testMakeCodexLBOpenAIAccountMapsChatGPTAccountIDToExternalUsageAccountID() {
        let encryptedAccount = CodexLBEncryptedAccount(
            accountId: "internal-id",
            chatGPTAccountId: "chatgpt-id",
            email: "user@example.com",
            planType: "plus",
            status: "active",
            accessTokenEncrypted: Data([0x01]),
            refreshTokenEncrypted: nil,
            idTokenEncrypted: nil,
            lastRefresh: "2026-03-22T10:00:00Z"
        )

        let account = TokenManager.shared.makeCodexLBOpenAIAccount(
            from: encryptedAccount,
            accessToken: "token",
            authSourcePath: "/tmp/store.db"
        )

        XCTAssertEqual(account.accountId, "internal-id")
        XCTAssertEqual(account.externalUsageAccountId, "chatgpt-id")
        XCTAssertEqual(account.email, "user@example.com")
        XCTAssertEqual(account.source, .codexLB)
    }

    func testCodexProviderKeepsDefaultAccountIDInDirectMode() {
        let provider = CodexProvider()
        let account = OpenAIAuthAccount(
            accessToken: "token",
            accountId: "direct-account-id",
            externalUsageAccountId: "chatgpt-account-id",
            email: "user@example.com",
            authSource: "codex-lb",
            sourceLabels: ["Codex LB"],
            source: .codexLB
        )

        let accountID = provider.codexRequestAccountID(
            for: account,
            endpointMode: .directChatGPT
        )

        XCTAssertEqual(accountID, "direct-account-id")
    }

    func testCodexProviderKeepsRegularAccountIDForNonCodexLBExternalMode() {
        let provider = CodexProvider()
        let account = OpenAIAuthAccount(
            accessToken: "token",
            accountId: "openai-account-id",
            externalUsageAccountId: nil,
            email: "user@example.com",
            authSource: "opencode-auth",
            sourceLabels: ["OpenCode"],
            source: .opencodeAuth
        )

        let accountID = provider.codexRequestAccountID(
            for: account,
            endpointMode: .external(usageURL: URL(string: "https://codex.example.com/api/codex/usage")!)
        )

        XCTAssertEqual(accountID, "openai-account-id")
    }

    func testCodexProviderDoesNotInventExternalUsageIDForNonCodexSources() {
        let account = OpenAIAuthAccount(
            accessToken: "token",
            accountId: "openai-account-id",
            externalUsageAccountId: nil,
            email: nil,
            authSource: "opencode-auth",
            sourceLabels: ["OpenCode"],
            source: .opencodeAuth
        )

        XCTAssertNil(account.externalUsageAccountId)
    }

    // MARK: - opencode.jsonc Precedence Tests

    func testOpenCodeConfigFilePathsReturnsJSONCBeforeJSONForEachLocation() {
        let paths = TokenManager.shared.getOpenCodeConfigFilePaths()
        let pathStrings = paths.map { $0.path }

        // Each .jsonc path must appear before its corresponding .json path
        // for the same directory. Verify by checking every .json path has a
        // .jsonc counterpart earlier in the array.
        for (index, path) in pathStrings.enumerated() where path.hasSuffix(".json") && !path.hasSuffix(".jsonc") {
            let jsoncVariant = path.replacingOccurrences(of: ".json", with: ".jsonc")
            if let jsoncIndex = pathStrings.firstIndex(of: jsoncVariant) {
                XCTAssertLessThan(
                    jsoncIndex,
                    index,
                    "opencode.jsonc (\(jsoncVariant)) should appear before opencode.json (\(path)) in search order"
                )
            }
        }
    }

    func testOpenCodeConfigFilePathsContainsBothExtensions() {
        let paths = TokenManager.shared.getOpenCodeConfigFilePaths()
        let pathStrings = paths.map { $0.path }

        let jsoncCount = pathStrings.filter { $0.hasSuffix(".jsonc") }.count
        let jsonCount = pathStrings.filter { $0.hasSuffix(".json") && !$0.hasSuffix(".jsonc") }.count

        XCTAssertGreaterThan(jsoncCount, 0, "Expected at least one .jsonc path")
        XCTAssertGreaterThan(jsonCount, 0, "Expected at least one .json path")
        XCTAssertEqual(jsoncCount, jsonCount, "Expected equal number of .jsonc and .json paths")
    }

    func testOpenCodeConfigFilePathsContainsExpectedDirectories() {
        let paths = TokenManager.shared.getOpenCodeConfigFilePaths()
        let pathStrings = paths.map { $0.path }

        // Verify the three expected config directories are covered for each extension.
        // Use hasSuffix instead of contains to avoid .json matching .jsonc paths.
        let expectedSuffixes = [
            "/.config/opencode/opencode.jsonc",
            "/.config/opencode/opencode.json",
            "/.local/share/opencode/opencode.jsonc",
            "/.local/share/opencode/opencode.json",
            "/Application Support/opencode/opencode.jsonc",
            "/Application Support/opencode/opencode.json"
        ]

        for suffix in expectedSuffixes {
            let matches = pathStrings.filter { $0.hasSuffix(suffix) }
            XCTAssertEqual(
                matches.count,
                1,
                "Expected exactly one path ending with '\(suffix)', found \(matches.count): \(matches)"
            )
        }
    }

    func testStripJSONCommentsProducesValidJSONFromJSONCInput() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        // Create .jsonc content that includes comments.
        let jsoncContent = """
        {
            // JSONC-specific comment
            "provider": {
                "openai": {
                    "options": {
                        "baseURL": "https://from-jsonc.example.com/v1"
                    }
                }
            }
        }
        """

        let jsoncPath = tempDirectory.appendingPathComponent("opencode.jsonc")
        try Data(jsoncContent.utf8).write(to: jsoncPath)

        let jsoncData = try Data(contentsOf: jsoncPath)
        let normalizedData = TokenManager.shared.stripJSONComments(from: jsoncData)
        let jsonObject = try JSONSerialization.jsonObject(with: normalizedData)
        let dict = try XCTUnwrap(jsonObject as? [String: Any])

        let configuration = TokenManager.shared.codexEndpointConfiguration(
            from: dict,
            sourcePath: jsoncPath.path
        )

        XCTAssertEqual(
            configuration,
            CodexEndpointConfiguration(
                mode: .external(usageURL: URL(string: "https://from-jsonc.example.com/api/codex/usage")!),
                source: jsoncPath.path
            ),
            "Expected JSONC input to remain valid after stripping comments"
        )
    }
}
