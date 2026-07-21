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

    func testClaudeUsageResponseDecodesFableWeeklyScopedLimit() throws {
        let fixtureData = loadFixture(named: "claude_response.json")
        let decoder = JSONDecoder()
        let response = try decoder.decode(ClaudeUsageResponse.self, from: fixtureData)

        let fableLimit = response.limits?.first { limit in
            limit.kind == "weekly_scoped"
                && limit.scope?.model?.display_name?.caseInsensitiveCompare("Fable") == .orderedSame
        }

        XCTAssertNotNil(fableLimit)
        XCTAssertEqual(fableLimit?.percent, 9.0)
        XCTAssertEqual(fableLimit?.resets_at, "2026-02-05T14:59:59Z")
    }

    func testClaudeUsageResponseWithoutLimitsArray() throws {
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

        XCTAssertNil(response.limits)
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

    func testClaudeOAuthRequestPolicyUsesInstalledVersionForUserAgent() {
        let userAgent = ClaudeOAuthRequestPolicy.usageUserAgent(
            environment: [:],
            installedVersion: "2.1.199"
        )

        XCTAssertEqual(userAgent, "claude-code/2.1.199")
    }

    func testClaudeOAuthRequestPolicyRejectsInvalidVersionOverride() {
        let userAgent = ClaudeOAuthRequestPolicy.usageUserAgent(
            environment: ["ANTHROPIC_CLI_VERSION": "invalid"],
            installedVersion: "2.1.199"
        )

        XCTAssertEqual(userAgent, "claude-code/2.1.199")
    }

    func testClaudeOAuthRequestPolicyParsesOfficialVersionOutput() {
        XCTAssertEqual(
            ClaudeOAuthRequestPolicy.versionFromCommandOutput("2.1.199 (Claude Code)\n"),
            "2.1.199"
        )
    }

    func testClaudeOAuthRequestPolicyRejectsPrefixedVersionOutput() {
        XCTAssertNil(ClaudeOAuthRequestPolicy.versionFromCommandOutput("Claude Code 2.1.199"))
    }

    func testClaudeOAuthRequestPolicyRejectsMultilineVersionOutput() {
        XCTAssertNil(ClaudeOAuthRequestPolicy.versionFromCommandOutput("2.1.199\nunexpected"))
    }

    func testClaudeOAuthRequestPolicyRejectsPrereleaseVersionOutput() {
        XCTAssertNil(ClaudeOAuthRequestPolicy.versionFromCommandOutput("2.1.199-beta"))
    }

    func testClaudeOAuthRequestPolicyRejectsUnicodeDigits() {
        XCTAssertNil(ClaudeOAuthRequestPolicy.versionFromCommandOutput("٢.١.١٩٩"))
    }

    func testClaudeOAuthRequestPolicyRejectsVersionOutputFromFailedCommand() async throws {
        let executableURL = try makeClaudeExecutable(
            script: "#!/bin/sh\nprintf '%s\\n' '2.1.199 (Claude Code)'\nexit 1\n"
        )
        defer { try? FileManager.default.removeItem(at: executableURL.deletingLastPathComponent()) }

        await ClaudeOAuthRequestPolicy.resetInstalledClaudeCodeVersionCacheForTesting()
        let version = await ClaudeOAuthRequestPolicy.installedClaudeCodeVersion(
            environment: ["CLAUDE_CODE_PATH": executableURL.path]
        )
        await ClaudeOAuthRequestPolicy.resetInstalledClaudeCodeVersionCacheForTesting()

        XCTAssertNil(version)
    }

    func testClaudeOAuthRequestPolicyCachesUnavailableDiscoveryResult() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executableURL = temporaryDirectory.appendingPathComponent("claude")
        let fileManager = ClaudeExecutableFileManager()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        await ClaudeOAuthRequestPolicy.resetInstalledClaudeCodeVersionCacheForTesting()
        let firstVersion = await ClaudeOAuthRequestPolicy.installedClaudeCodeVersion(
            environment: ["CLAUDE_CODE_PATH": executableURL.path],
            fileManager: fileManager
        )

        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '%s\\n' '2.1.199 (Claude Code)'\n"
            .write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        fileManager.executablePaths = [executableURL.path]

        let secondVersion = await ClaudeOAuthRequestPolicy.installedClaudeCodeVersion(
            environment: ["CLAUDE_CODE_PATH": executableURL.path],
            fileManager: fileManager
        )
        await ClaudeOAuthRequestPolicy.resetInstalledClaudeCodeVersionCacheForTesting()

        XCTAssertNil(firstVersion)
        XCTAssertNil(secondVersion)
    }

    func testClaudeOAuthRequestPolicyCachesDiscoveredVersion() async throws {
        let executableURL = try makeClaudeExecutable(
            script: "#!/bin/sh\nprintf '%s\\n' '2.1.199 (Claude Code)'\n"
        )
        let fileManager = ClaudeExecutableFileManager(executablePaths: [executableURL.path])
        defer { try? FileManager.default.removeItem(at: executableURL.deletingLastPathComponent()) }

        await ClaudeOAuthRequestPolicy.resetInstalledClaudeCodeVersionCacheForTesting()
        let firstVersion = await ClaudeOAuthRequestPolicy.installedClaudeCodeVersion(
            environment: ["CLAUDE_CODE_PATH": executableURL.path],
            fileManager: fileManager
        )
        fileManager.executablePaths = []
        let secondVersion = await ClaudeOAuthRequestPolicy.installedClaudeCodeVersion(
            environment: ["CLAUDE_CODE_PATH": executableURL.path],
            fileManager: fileManager
        )
        await ClaudeOAuthRequestPolicy.resetInstalledClaudeCodeVersionCacheForTesting()

        XCTAssertEqual(firstVersion, "2.1.199")
        XCTAssertEqual(secondVersion, "2.1.199")
    }

    private final class ClaudeExecutableFileManager: FileManager, @unchecked Sendable {
        var executablePaths: Set<String>

        init(executablePaths: Set<String> = []) {
            self.executablePaths = executablePaths
            super.init()
        }

        override func isExecutableFile(atPath path: String) -> Bool {
            executablePaths.contains(path)
        }
    }

    private func makeClaudeExecutable(script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executableURL = directory.appendingPathComponent("claude")

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        return executableURL
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
