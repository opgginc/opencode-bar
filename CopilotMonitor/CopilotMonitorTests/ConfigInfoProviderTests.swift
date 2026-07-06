import XCTest
@testable import OpenCode_Bar

@MainActor
final class ConfigInfoProviderTests: XCTestCase {
    private var suiteName: String = ""
    private var suite: UserDefaults!
    private var controller: StatusBarController!

    override func setUp() {
        super.setUp()
        suiteName = "B20.test.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        controller = StatusBarController(options: .testing(userDefaults: suite))
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        controller = nil
        super.tearDown()
    }

    // MARK: - B24: search engines use opencode.json (NOT auth.json)

    func testTavilyUsesOpencodeJsonMcpEnvironmentKey() {
        let info = controller.configInfo(for: .tavilySearch)
        XCTAssertTrue(
            info.fieldName.contains("mcp.tavily.environment.TAVILY_API_KEY"),
            "tavily should reference mcp.tavily.environment.TAVILY_API_KEY, got: \(info.fieldName)"
        )
        XCTAssertTrue(
            info.path.contains("opencode.json"),
            "tavily config path should be opencode.json, got: \(info.path)"
        )
        XCTAssertFalse(
            info.path.contains("auth.json"),
            "tavily config path must NOT be auth.json (that's for OpenCode auth, not MCP), got: \(info.path)"
        )
    }

    func testBraveSearchUsesOpencodeJsonMcpEnvironmentKey() {
        let info = controller.configInfo(for: .braveSearch)
        XCTAssertTrue(
            info.fieldName.contains("mcp.brave-search.environment.BRAVE_API_KEY"),
            "braveSearch should reference mcp.brave-search.environment.BRAVE_API_KEY, got: \(info.fieldName)"
        )
        XCTAssertTrue(
            info.path.contains("opencode.json"),
            "braveSearch config path should be opencode.json, got: \(info.path)"
        )
        XCTAssertFalse(
            info.path.contains("auth.json"),
            "braveSearch config path must NOT be auth.json, got: \(info.path)"
        )
    }

    // MARK: - B20: providers that previously fell to default or had wrong info

    func testOpenCodeZenReferencesCLINotAuthJson() {
        let info = controller.configInfo(for: .openCodeZen)
        XCTAssertTrue(
            info.fieldName.lowercased().contains("opencode") ||
            info.path.lowercased().contains("opencode"),
            ".openCodeZen configInfo should reference the opencode CLI, got: \(info)"
        )
        XCTAssertFalse(
            info.path.contains("~/.local/share/opencode/auth.json"),
            ".openCodeZen must NOT use the OpenCode auth.json path, got: \(info.path)"
        )
    }

    func testGrokUsesGrokHomeAuthJson() {
        let info = controller.configInfo(for: .grok)
        XCTAssertTrue(
            info.path.contains(".grok"),
            "grok should reference ~/.grok/auth.json, got: \(info.path)"
        )
        XCTAssertFalse(
            info.path.contains("opencode/auth.json"),
            "grok must NOT point at OpenCode auth.json, got: \(info.path)"
        )
    }

    func testCommandCodeUsesBrowserCookieNotAuthJson() {
        let info = controller.configInfo(for: .commandCode)
        XCTAssertTrue(
            info.fieldName.lowercased().contains("cookie") ||
            info.fieldName.lowercased().contains("session_token"),
            "commandCode should reference browser cookie, got: \(info.fieldName)"
        )
        XCTAssertFalse(
            info.path.contains("auth.json"),
            "commandCode must NOT point at auth.json (uses BrowserCookieService), got: \(info.path)"
        )
    }

    func testKiroReferencesCliNotAuthJson() {
        let info = controller.configInfo(for: .kiro)
        XCTAssertTrue(
            info.fieldName.lowercased().contains("kiro") &&
            (info.fieldName.lowercased().contains("cli") || info.fieldName.lowercased().contains("binary")),
            "kiro should reference kiro-cli binary, got: \(info.fieldName)"
        )
        XCTAssertFalse(
            info.path.contains("auth.json"),
            "kiro must NOT point at auth.json (kiro-cli handles its own auth), got: \(info.path)"
        )
    }

    func testGeminiCLIReferencesGoogleKeyPluginPath() {
        let info = controller.configInfo(for: .geminiCLI)
        XCTAssertTrue(
            info.fieldName.contains("google"),
            "geminiCLI should reference jenslys/opencode-gemini-auth 'google' key, got: \(info.fieldName)"
        )
        XCTAssertTrue(
            info.path.contains("auth.json"),
            "geminiCLI's jenslys path should be auth.json, got: \(info.path)"
        )
    }

    // MARK: - Smoke tests: existing correct entries must not regress

    func testCopilotAuthJsonPathUnchanged() {
        let info = controller.configInfo(for: .copilot)
        XCTAssertEqual(info.fieldName, "github-copilot")
        XCTAssertTrue(info.path.contains("auth.json"))
    }

    func testCursorBrowserCookieHintUnchanged() {
        let info = controller.configInfo(for: .cursor)
        XCTAssertTrue(
            info.fieldName.contains("Cursor") || info.fieldName.contains("登录"),
            "cursor should mention Cursor app / 登录, got: \(info.fieldName)"
        )
        XCTAssertTrue(
            info.path.contains("Cursor") || info.path.contains("登录"),
            "cursor path should describe the login hint, got: \(info.path)"
        )
    }

    func testCodexCodexAuthJsonUnchanged() {
        let info = controller.configInfo(for: .codex)
        XCTAssertEqual(info.fieldName, "OPENAI_API_KEY 或 tokens")
        XCTAssertTrue(info.path.contains(".codex/auth.json"))
    }

    func testAntigravityAntigravityAccountsUnchanged() {
        let info = controller.configInfo(for: .antigravity)
        XCTAssertEqual(info.fieldName, "antigravity-accounts.json")
        XCTAssertTrue(info.path.contains(".local/share/opencode"))
    }

    func testAllListedProvidersReturnExplicitEntries() {
        // Every provider in the documented switch should have a case.
        // If a new identifier was added without an explicit configInfo case,
        // it would fall through to the unhelpful generic "对应 provider 的 key 字段".
        let identifiers: [ProviderIdentifier] = [
            .copilot, .claude, .openRouter, .openCode, .openCodeGo, .openCodeZen,
            .kimi, .kimiCN, .minimaxCodingPlan, .minimaxCodingPlanCN,
            .zaiCodingPlan, .nanoGpt, .synthetic, .chutes, .mimo,
            .volcanoArk, .hunyuan, .zhipuGLM,
            .codex, .antigravity, .cursor, .commandCode, .kiro, .geminiCLI,
            .tavilySearch, .braveSearch, .grok
        ]
        for id in identifiers {
            let info = controller.configInfo(for: id)
            XCTAssertFalse(
                info.fieldName.contains("对应 provider"),
                "Provider \(id.rawValue) should have an explicit field name; got generic fallback"
            )
        }
    }
}
