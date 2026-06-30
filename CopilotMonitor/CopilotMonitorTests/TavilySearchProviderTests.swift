import XCTest
@testable import OpenCode_Bar

final class TavilySearchProviderTests: XCTestCase {
    func testParseUsageFromResponseData() throws {
        let bundle = Bundle(for: type(of: self))
        let url = bundle.url(forResource: "tavily_usage_response", withExtension: "json")!
        let data = try Data(contentsOf: url)

        let parsed = try TavilySearchProvider.parseUsage(from: data, keyName: "google")

        XCTAssertEqual(parsed.used, 67)
        XCTAssertEqual(parsed.limit, 1000)
        XCTAssertEqual(parsed.remaining, 933)
        XCTAssertEqual(parsed.planName, "Researcher")
        if case .quotaBased(let remaining, let entitlement, _) = parsed.usage {
            XCTAssertEqual(remaining, 933)
            XCTAssertEqual(entitlement, 1000)
        } else {
            XCTFail("expected quotaBased usage")
        }
    }
}
