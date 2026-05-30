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

    func testDashboardUsageParserReadsEscapedUsageWindows() throws {
        let html = #"""
        <script>
        self.__next_f.push([1,"{\"rollingUsage\":{\"usagePercent\":12.5,\"resetInSec\":3600},\"weeklyUsage\":{\"usagePercent\":\"25\",\"resetInSec\":\"7200\"},\"monthlyUsage\":{\"usagePercent\":50,\"resetInSec\":10800}}"])
        </script>
        """#
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let usage = try OpenCodeGoProvider.parseDashboardUsageHTML(html, now: now)

        XCTAssertEqual(usage.rolling?.usagePercent ?? -1, 12.5, accuracy: 0.001)
        XCTAssertEqual(usage.weekly?.usagePercent ?? -1, 25.0, accuracy: 0.001)
        XCTAssertEqual(usage.monthly?.usagePercent ?? -1, 50.0, accuracy: 0.001)
        XCTAssertEqual(usage.rolling?.resetInSeconds, 3_600)
        XCTAssertEqual(usage.weekly?.resetDate, now.addingTimeInterval(7_200))
        XCTAssertEqual(usage.monthly?.resetDate, now.addingTimeInterval(10_800))
    }

    func testDashboardUsageParserReadsSolidResourceReferences() throws {
        let html = #"""
        <script>
        $R[24]($R[18],$R[30]={mine:!0,useBalance:!0,rollingUsage:$R[31]={status:"ok",resetInSec:18000,usagePercent:0},weeklyUsage:$R[32]={status:"ok",resetInSec:162822,usagePercent:31},monthlyUsage:$R[33]={status:"ok",resetInSec:1404782,usagePercent:21}});
        </script>
        """#

        let usage = try OpenCodeGoProvider.parseDashboardUsageHTML(html)

        XCTAssertEqual(usage.rolling?.usagePercent ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(usage.weekly?.usagePercent ?? -1, 31, accuracy: 0.001)
        XCTAssertEqual(usage.monthly?.usagePercent ?? -1, 21, accuracy: 0.001)
        XCTAssertEqual(usage.rolling?.resetInSeconds, 18_000)
    }

    func testDashboardUsageParserKeepsPartialUsageWindows() throws {
        let html = #"""
        <script>
        self.__next_f.push([1,"{\"rollingUsage\":{\"usagePercent\":64,\"resetInSec\":900}}"])
        </script>
        """#

        let usage = try OpenCodeGoProvider.parseDashboardUsageHTML(html)

        XCTAssertEqual(usage.rolling?.usagePercent ?? -1, 64, accuracy: 0.001)
        XCTAssertNil(usage.weekly)
        XCTAssertNil(usage.monthly)
        XCTAssertEqual(usage.missingWindowNames, ["weeklyUsage", "monthlyUsage"])
    }

    func testWorkspaceIDExtractionKeepsRecentOrderAndDeduplicates() {
        let urls = [
            "https://opencode.ai/workspace/wrk_01ABCDEF0123456789ABCDEFG/go",
            "https://opencode.ai/workspace/wrk_01SECOND0123456789ABCDEF/usage",
            "https://opencode.ai/workspace/wrk_01ABCDEF0123456789ABCDEFG/keys",
            "https://opencode.ai/go"
        ]

        XCTAssertEqual(
            OpenCodeGoProvider.extractWorkspaceIDs(from: urls),
            [
                "wrk_01ABCDEF0123456789ABCDEFG",
                "wrk_01SECOND0123456789ABCDEF"
            ]
        )
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
