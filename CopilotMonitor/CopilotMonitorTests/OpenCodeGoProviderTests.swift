import XCTest
@testable import OpenCode_Bar

final class OpenCodeGoProviderTests: XCTestCase {
    func testProviderIdentifier() {
        let provider = OpenCodeGoProvider()
        XCTAssertEqual(provider.identifier, .openCodeGo)
    }

    func testProviderType() {
        let provider = OpenCodeGoProvider()
        XCTAssertEqual(provider.type, .quotaBased)
    }

    func testGoUsageAPIParserReadsPercentWindowsAndResets() throws {
        let json = """
        {"usage": {
            "rolling": {"status": "ok", "percent": 5, "resetsAt": "2026-10-15T00:03:54.000Z"},
            "weekly": {"status": "ok", "percent": 15, "resetsAt": "2026-10-19T00:00:00.000Z"},
            "monthly": {"status": "ok", "percent": 37, "resetsAt": "2026-10-30T03:26:32.000Z"}
        }}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-14T20:00:00Z"))

        let usage = try OpenCodeGoProvider.parseGoUsageAPI(data, now: now)

        XCTAssertEqual(usage.rolling?.usagePercent ?? -1, 5.0, accuracy: 0.001)
        XCTAssertEqual(usage.weekly?.usagePercent ?? -1, 15.0, accuracy: 0.001)
        XCTAssertEqual(usage.monthly?.usagePercent ?? -1, 37.0, accuracy: 0.001)
        XCTAssertEqual(usage.rolling?.resetInSeconds, 4 * 3_600 + 3 * 60 + 54)
        XCTAssertTrue(usage.missingWindowNames.isEmpty)
    }

    func testGoUsageAPIParserKeepsPartialWindows() throws {
        let json = """
        {"usage": {"weekly": {"status": "ok", "percent": 50, "resetsAt": "2026-10-19T00:00:00.000Z"}}}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))

        let usage = try OpenCodeGoProvider.parseGoUsageAPI(data)

        XCTAssertNil(usage.rolling)
        XCTAssertEqual(usage.weekly?.usagePercent ?? -1, 50.0, accuracy: 0.001)
        XCTAssertNil(usage.monthly)
        XCTAssertEqual(usage.missingWindowNames, ["rollingUsage", "monthlyUsage"])
    }

    func testGoUsageAPIParserThrowsOnUnexpectedShape() {
        for json in [#"{"product": "go"}"#, #"[]"#, #"not json"#, #"{"usage": {}}"#] {
            XCTAssertThrowsError(try OpenCodeGoProvider.parseGoUsageAPI(Data(json.utf8)), "json: \(json)")
        }
    }

    func testGoUsageAPIParserLeavesResetNilWhenResetsAtMissing() throws {
        let json = """
        {"usage": {"rolling": {"status": "ok", "percent": 5}}}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))

        let usage = try OpenCodeGoProvider.parseGoUsageAPI(data)

        XCTAssertEqual(usage.rolling?.usagePercent ?? -1, 5.0, accuracy: 0.001)
        XCTAssertNil(usage.rolling?.resetDate)
        XCTAssertEqual(usage.rolling?.resetInSeconds, 0)
    }

    func testOpenCodeGoAPIKeyDecodes() throws {
        let json = """
        {
            "opencode-go": {
                "type": "api",
                "key": "opencode-go-test-key"
            }
        }
        """

        let data = try XCTUnwrap(json.data(using: .utf8))
        let auth = try JSONDecoder().decode(OpenCodeAuth.self, from: data)

        XCTAssertEqual(auth.openCodeGo?.key, "opencode-go-test-key")
    }
}
