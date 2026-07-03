import XCTest
@testable import OpenCode_Bar

final class TokenManagerTests: XCTestCase {

    private func makeTestJWT(payload: String) -> String {
        func encode(_ string: String) -> String {
            Data(string.utf8)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        let header = #"{"alg":"RS256","typ":"JWT"}"#
        return "\(encode(header)).\(encode(payload)).signature"
    }

    func testCodexEndpointConfigurationDefaultsToChatGPT() {
        let configuration = TokenManager.shared.codexEndpointConfiguration(from: nil)

        XCTAssertEqual(configuration, CodexEndpointConfiguration(
            mode: .directChatGPT,
            source: "Default ChatGPT usage endpoint",
            usesOpenAIProviderBaseURL: false
        ))
    }

    func testCodexEndpointConfigurationPrefersDirectChatGPTForOcChatGPTMultiAuthPlugin() {
        let configuration = TokenManager.shared.codexEndpointConfiguration(
            from: [
                "plugin": ["oc-chatgpt-multi-auth"],
                "provider": [
                    "openai": [
                        "options": [
                            "baseURL": "http://127.0.0.1:2455/v1"
                        ]
                    ]
                ]
            ],
            sourcePath: "/tmp/opencode.json"
        )

        XCTAssertEqual(configuration, CodexEndpointConfiguration(
            mode: .directChatGPT,
            source: "oc-chatgpt-multi-auth direct ChatGPT usage endpoint",
            usesOpenAIProviderBaseURL: false
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
            source: "/tmp/opencode.json",
            usesOpenAIProviderBaseURL: true
        ))
        XCTAssertEqual(configuration.externalServiceDisplayName, "Codex.2631.eu")
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
            source: "/tmp/opencode.json",
            usesOpenAIProviderBaseURL: false
        ))
        XCTAssertNil(configuration.externalServiceDisplayName)
    }

    func testCodexExternalDisplayNameFormatsOnlyCodexHosts() {
        XCTAssertEqual(
            CodexEndpointConfiguration.displayName(forExternalHost: "proxy.example.com"),
            "proxy.example.com"
        )
        XCTAssertEqual(
            CodexEndpointConfiguration.displayName(forExternalHost: "Codex.example.com"),
            "Codex.example.com"
        )
        XCTAssertEqual(
            CodexEndpointConfiguration.displayName(forExternalHost: "codex"),
            "codex"
        )
        XCTAssertEqual(
            CodexEndpointConfiguration.displayName(forExternalHost: "codex.2631.eu"),
            "Codex.2631.eu"
        )
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
            source: "/tmp/opencode.json",
            usesOpenAIProviderBaseURL: true
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
            source: "Default ChatGPT usage endpoint",
            usesOpenAIProviderBaseURL: false
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

    func testOpenCodeAuthDecodesOcChatGPTMultiAuthFields() throws {
        let json = """
        {
          "openai": {
            "type": "oauth",
            "refresh": "refresh-token",
            "access": "access-token",
            "expires": 1776088671146,
            "idToken": "id-token",
            "multiAccount": true,
            "accountIdOverride": "org-selected-account",
            "organizationIdOverride": "org-selected-account",
            "accountIdSource": "org",
            "accountLabel": "Personal [id:abc123]"
          }
        }
        """

        let auth = try JSONDecoder().decode(OpenCodeAuth.self, from: XCTUnwrap(json.data(using: .utf8)))

        XCTAssertEqual(auth.openai?.access, "access-token")
        XCTAssertEqual(auth.openai?.refresh, "refresh-token")
        XCTAssertEqual(auth.openai?.idToken, "id-token")
        XCTAssertEqual(auth.openai?.accountIdOverride, "org-selected-account")
        XCTAssertEqual(auth.openai?.organizationIdOverride, "org-selected-account")
        XCTAssertEqual(auth.openai?.accountIdSource, "org")
        XCTAssertEqual(auth.openai?.accountLabel, "Personal [id:abc123]")
        XCTAssertEqual(auth.openai?.multiAccount, true)
    }

    func testMiniMaxLegacyCodingPlanKeyFeedsCNProvider() throws {
        // Existing users only have `minimax-coding-plan`, which is a CN-valid key.
        // The CN provider should read it via fallback; the global provider should not.
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let authDirectory = tempDirectory.appendingPathComponent("opencode", isDirectory: true)
        let authPath = authDirectory.appendingPathComponent("auth.json")

        try fileManager.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let originalXDGDataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
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
          "minimax-coding-plan": {
            "type": "api",
            "key": "legacy-cn-key"
          }
        }
        """
        try XCTUnwrap(json.data(using: .utf8)).write(to: authPath)

        setenv("XDG_DATA_HOME", tempDirectory.path, 1)
        TokenManager.shared.clearOpenCodeAuthCacheForTesting()

        XCTAssertEqual(TokenManager.shared.getMiniMaxCodingPlanCNAPIKey(), "legacy-cn-key")
        XCTAssertNil(TokenManager.shared.getMiniMaxCodingPlanAPIKey())
    }

    func testMiniMaxGlobalKeyIsIsolatedFromCNKey() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let authDirectory = tempDirectory.appendingPathComponent("opencode", isDirectory: true)
        let authPath = authDirectory.appendingPathComponent("auth.json")

        try fileManager.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let originalXDGDataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
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
          "minimax-coding-plan-global": {
            "type": "api",
            "key": "global-key"
          },
          "minimax-coding-plan-cn": {
            "type": "api",
            "key": "cn-key"
          }
        }
        """
        try XCTUnwrap(json.data(using: .utf8)).write(to: authPath)

        setenv("XDG_DATA_HOME", tempDirectory.path, 1)
        TokenManager.shared.clearOpenCodeAuthCacheForTesting()

        XCTAssertEqual(TokenManager.shared.getMiniMaxCodingPlanAPIKey(), "global-key")
        XCTAssertEqual(TokenManager.shared.getMiniMaxCodingPlanCNAPIKey(), "cn-key")
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

    func testReadOpenAIMultiAuthFilesCanonicalizesAccountIDFromAccessTokenClaims() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let accountsPath = tempDirectory.appendingPathComponent("openai-codex-accounts.json")

        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let accessToken = makeTestJWT(
            payload: #"""
            {
              "https://api.openai.com/auth": {
                "chatgpt_account_id": "chatgpt-account-id"
              },
              "https://api.openai.com/profile": {
                "email": "user@example.com"
              }
            }
            """#
        )

        let json = """
        {
          "version": 3,
          "accounts": [
            {
              "accountId": "org-example-account",
              "organizationId": "org-example-account",
              "accountIdSource": "org",
              "accessToken": "\(accessToken)",
              "refreshToken": "refresh-1",
              "expiresAt": 1770563557150
            },
            {
              "accountId": "chatgpt-account-id",
              "accountIdSource": "token",
              "accessToken": "\(accessToken)",
              "refreshToken": "refresh-1",
              "expiresAt": 1770563557150
            }
          ],
          "activeIndex": 0
        }
        """

        try XCTUnwrap(json.data(using: .utf8)).write(to: accountsPath)

        let accounts = TokenManager.shared.readOpenAIMultiAuthFiles(at: [accountsPath])

        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(accounts.map(\.accountId), ["chatgpt-account-id", "chatgpt-account-id"])
        XCTAssertEqual(accounts.map(\.email), ["user@example.com", "user@example.com"])
        XCTAssertEqual(accounts.map(\.source), [.openCodeMultiAuth, .openCodeMultiAuth])
        XCTAssertEqual(accounts.map(\.authSource), [accountsPath.path, accountsPath.path])
        XCTAssertEqual(accounts.map(\.sourceLabels), [["OpenCode Multi Auth"], ["OpenCode Multi Auth"]])
    }

    func testReadOpenAIMultiAuthFilesCapturesRefreshMetadata() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let accountsPath = tempDirectory.appendingPathComponent("openai-codex-accounts.json")

        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let accessToken = makeTestJWT(
            payload: #"""
            {
              "https://api.openai.com/auth": {
                "chatgpt_account_id": "chatgpt-account-id"
              },
              "https://api.openai.com/profile": {
                "email": "user@example.com"
              }
            }
            """#
        )

        let json = """
        {
          "version": 3,
          "accounts": [
            {
              "accountId": "chatgpt-account-id",
              "accountIdSource": "token",
              "accessToken": "\(accessToken)",
              "refreshToken": "refresh-token",
              "expiresAt": 1770563557150
            }
          ],
          "activeIndex": 0
        }
        """

        try XCTUnwrap(json.data(using: .utf8)).write(to: accountsPath)

        let account = try XCTUnwrap(TokenManager.shared.readOpenAIMultiAuthFiles(at: [accountsPath]).first)

        XCTAssertEqual(account.refreshToken, "refresh-token")
        let expiresAt = try XCTUnwrap(account.expiresAt)
        XCTAssertEqual(expiresAt.timeIntervalSince1970, 1_770_563_557.15, accuracy: 0.01)
    }

    func testReadOpenCodeAnthropicCodexAccountFilesCapturesCachedUsage() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let accountsPath = tempDirectory.appendingPathComponent("codex-accounts.json")

        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let json = """
        {
          "version": 1,
          "accounts": [
            {
              "id": "local-cache-id",
              "accountID": "chatgpt-account-id",
              "email": "user@example.com",
              "enabled": true,
              "usage": {
                "fetchedAt": 1778410367180,
                "planType": "pro",
                "primary": {
                  "utilization": 25,
                  "resetsAt": "2026-05-10T15:15:02.180Z",
                  "label": "5h",
                  "windowMs": 18000000
                },
                "secondary": {
                  "utilization": 75,
                  "resetsAt": "2026-05-15T19:42:30.180Z",
                  "label": "Weekly",
                  "windowMs": 604800000
                },
                "sparkPrimary": {
                  "utilization": 10,
                  "resetsAt": "2026-05-10T15:52:47.715Z",
                  "label": "Spark 5h",
                  "windowMs": 18000000
                },
                "creditsBalance": "0",
                "creditsUnlimited": false
              }
            },
            {
              "id": "disabled-cache-id",
              "email": "disabled@example.com",
              "enabled": false,
              "usage": {
                "primary": {
                  "utilization": 50
                }
              }
            }
          ]
        }
        """

        try XCTUnwrap(json.data(using: .utf8)).write(to: accountsPath)

        let accounts = TokenManager.shared.readOpenCodeAnthropicCodexAccountFiles(at: [accountsPath])

        XCTAssertEqual(accounts.count, 1)
        let account = try XCTUnwrap(accounts.first)
        XCTAssertEqual(account.accountId, "chatgpt-account-id")
        XCTAssertEqual(account.email, "user@example.com")
        XCTAssertEqual(account.authSource, accountsPath.path)
        XCTAssertEqual(account.source, .openCodeAnthropicAuthCodexCache)
        XCTAssertEqual(account.sourceLabels, ["OpenCode Anthropic Auth"])
        XCTAssertEqual(account.cachedCodexUsage?.planType, "pro")
        XCTAssertEqual(account.cachedCodexUsage?.primary?.utilization, 25)
        XCTAssertEqual(account.cachedCodexUsage?.primary?.label, "5h")
        XCTAssertEqual(account.cachedCodexUsage?.primary?.windowMs, 18_000_000)
        XCTAssertEqual(account.cachedCodexUsage?.secondary?.utilization, 75)
        XCTAssertEqual(account.cachedCodexUsage?.sparkPrimary?.utilization, 10)
        XCTAssertEqual(account.cachedCodexUsage?.creditsBalance, 0)
        XCTAssertEqual(account.cachedCodexUsage?.creditsUnlimited, false)
    }

    func testDedupeOpenAIAccountsPreservesOpenAIMultiAuthRefreshMetadata() throws {
        let expiresAt = Date(timeIntervalSince1970: 1_770_563_557.15)
        let firstAccount = OpenAIAuthAccount(
            accessToken: "first-token",
            accountId: "chatgpt-account-id",
            externalUsageAccountId: nil,
            email: "user@example.com",
            authSource: "/tmp/project-a/openai-codex-accounts.json",
            sourceLabels: ["OpenCode Multi Auth"],
            source: .openCodeMultiAuth,
            credentialType: .oauthBearer,
            refreshToken: "refresh-token",
            expiresAt: expiresAt,
            idToken: "id-token"
        )
        let duplicateAccount = OpenAIAuthAccount(
            accessToken: "duplicate-token",
            accountId: "chatgpt-account-id",
            externalUsageAccountId: nil,
            email: "user@example.com",
            authSource: "/tmp/project-b/openai-codex-accounts.json",
            sourceLabels: ["OpenCode Multi Auth"],
            source: .openCodeMultiAuth,
            credentialType: .oauthBearer,
            refreshToken: "duplicate-refresh-token",
            expiresAt: Date(timeIntervalSince1970: 1_770_563_600),
            idToken: "duplicate-id-token"
        )

        let account = try XCTUnwrap(TokenManager.shared.dedupeOpenAIAccounts([firstAccount, duplicateAccount]).first)

        XCTAssertEqual(account.refreshToken, "refresh-token")
        let mergedExpiresAt = try XCTUnwrap(account.expiresAt)
        XCTAssertEqual(mergedExpiresAt.timeIntervalSince1970, expiresAt.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(account.idToken, "id-token")
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
            source: .codexLB,
            credentialType: .oauthBearer
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
        XCTAssertEqual(account.credentialType, .oauthBearer)
    }

    func testShouldIncludeCodexLBAccountSkipsInactiveStatus() {
        let activeAccount = CodexLBEncryptedAccount(
            accountId: "active-id",
            chatGPTAccountId: "active-chatgpt-id",
            email: "active@example.com",
            planType: "plus",
            status: "active",
            accessTokenEncrypted: Data([0x01]),
            refreshTokenEncrypted: nil,
            idTokenEncrypted: nil,
            lastRefresh: nil
        )
        let inactiveAccount = CodexLBEncryptedAccount(
            accountId: "inactive-id",
            chatGPTAccountId: "inactive-chatgpt-id",
            email: "inactive@example.com",
            planType: "plus",
            status: "deactivated",
            accessTokenEncrypted: Data([0x01]),
            refreshTokenEncrypted: nil,
            idTokenEncrypted: nil,
            lastRefresh: nil
        )
        let legacyAccount = CodexLBEncryptedAccount(
            accountId: "legacy-id",
            chatGPTAccountId: "legacy-chatgpt-id",
            email: "legacy@example.com",
            planType: nil,
            status: nil,
            accessTokenEncrypted: Data([0x01]),
            refreshTokenEncrypted: nil,
            idTokenEncrypted: nil,
            lastRefresh: nil
        )

        XCTAssertTrue(TokenManager.shared.shouldIncludeCodexLBAccount(activeAccount))
        XCTAssertFalse(TokenManager.shared.shouldIncludeCodexLBAccount(inactiveAccount))
        XCTAssertTrue(TokenManager.shared.shouldIncludeCodexLBAccount(legacyAccount))
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
            source: .codexLB,
            credentialType: .oauthBearer
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
            source: .opencodeAuth,
            credentialType: .oauthBearer
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
            source: .opencodeAuth,
            credentialType: .oauthBearer
        )

        XCTAssertNil(account.externalUsageAccountId)
    }

    func testDedupeOpenAIAccountsPrefersCodexNativeAuthOverCodexLBForSameEmail() throws {
        let codexLBAccount = OpenAIAuthAccount(
            accessToken: "codex-lb-token",
            accountId: "chatgpt-account-id_codex-lb-row",
            externalUsageAccountId: "chatgpt-account-id",
            email: "user@example.com",
            authSource: "/tmp/.codex-lb/store.db",
            sourceLabels: ["Codex LB"],
            source: .codexLB,
            credentialType: .oauthBearer
        )
        let codexNativeAccount = OpenAIAuthAccount(
            accessToken: "codex-native-token",
            accountId: "chatgpt-account-id",
            externalUsageAccountId: nil,
            email: "user@example.com",
            authSource: "/tmp/.codex/auth.json",
            sourceLabels: ["Codex"],
            source: .codexAuth,
            credentialType: .oauthBearer
        )

        let accounts = TokenManager.shared.dedupeOpenAIAccounts([codexLBAccount, codexNativeAccount])
        let account = try XCTUnwrap(accounts.first)

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(account.accessToken, "codex-native-token")
        XCTAssertEqual(account.accountId, "chatgpt-account-id")
        XCTAssertEqual(account.externalUsageAccountId, "chatgpt-account-id")
        XCTAssertEqual(account.email, "user@example.com")
        XCTAssertEqual(account.authSource, "/tmp/.codex/auth.json")
        XCTAssertEqual(account.sourceLabels, ["Codex", "Codex LB"])
        XCTAssertEqual(account.source, .codexAuth)
    }

    func testDedupeOpenAIAccountsPrefersCodexNativeAuthOverOpenCodeMultiAuthForSameEmail() throws {
        let multiAuthAccount = OpenAIAuthAccount(
            accessToken: "multi-auth-token",
            accountId: "chatgpt-account-id",
            externalUsageAccountId: nil,
            email: "user@example.com",
            authSource: "/tmp/.opencode/projects/example/openai-codex-accounts.json",
            sourceLabels: ["OpenCode Multi Auth"],
            source: .openCodeMultiAuth,
            credentialType: .oauthBearer
        )
        let codexNativeAccount = OpenAIAuthAccount(
            accessToken: "codex-native-token",
            accountId: "chatgpt-account-id",
            externalUsageAccountId: nil,
            email: "user@example.com",
            authSource: "/tmp/.codex/auth.json",
            sourceLabels: ["Codex"],
            source: .codexAuth,
            credentialType: .oauthBearer
        )

        let accounts = TokenManager.shared.dedupeOpenAIAccounts([multiAuthAccount, codexNativeAccount])
        let account = try XCTUnwrap(accounts.first)

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(account.accessToken, "codex-native-token")
        XCTAssertEqual(account.accountId, "chatgpt-account-id")
        XCTAssertEqual(account.email, "user@example.com")
        XCTAssertEqual(account.authSource, "/tmp/.codex/auth.json")
        XCTAssertEqual(account.sourceLabels, ["Codex", "OpenCode Multi Auth"])
        XCTAssertEqual(account.source, .codexAuth)
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
                source: jsoncPath.path,
                usesOpenAIProviderBaseURL: true
            ),
            "Expected JSONC input to remain valid after stripping comments"
        )
    }

    // MARK: - Process stdout capture regression tests

    func testLargeStdoutCaptureDoesNotDeadlock() throws {
        // Use a shell script that emits output larger than the typical pipe
        // buffer (~64 KB). The previous Pipe-based implementation deadlocked
        // here because the parent waited for exit before draining stdout.
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let largePayload = String(repeating: "x", count: 256 * 1024)
        let scriptPath = tempDirectory.appendingPathComponent("emit.sh")
        let script = "#!/bin/sh\nprintf '%s' '\(largePayload)'\n"
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let captured = TokenManager.shared.runProcessCapturingStdout(
            executableURL: scriptPath,
            arguments: []
        )

        let capturedString = try XCTUnwrap(String(data: XCTUnwrap(captured), encoding: .utf8))
        XCTAssertEqual(capturedString, largePayload)
    }

    func testStdoutCaptureReturnsNilOnNonzeroExit() {
        let captured = TokenManager.shared.runProcessCapturingStdout(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 1"]
        )
        XCTAssertNil(captured)
    }
}
