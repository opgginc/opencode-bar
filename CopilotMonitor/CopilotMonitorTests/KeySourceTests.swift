import XCTest
@testable import OpenCode_Bar

final class KeySourceTests: XCTestCase {
    private func fixtureURL(_ name: String, ext: String) -> URL {
        let bundle = Bundle(for: type(of: self))
        return bundle.url(forResource: name, withExtension: ext)!
    }

    func testYamlKeySourceParsesAllTavilyKeys() throws {
        let url = fixtureURL("ai_infra_keys", ext: "yaml")
        let source = AIInfraYamlKeySource(fileURL: url)
        let keys = try source.keys(forProvider: "tavily")

        XCTAssertEqual(keys.count, 4)
        let names = Set(keys.map { $0.name })
        XCTAssertEqual(names, ["apple", "github", "google", "qq"])
        let appleKey = keys.first { $0.name == "apple" }
        XCTAssertEqual(appleKey?.value, "tvly-dev-APPLE0000000000000000000000000000")
    }

    func testYamlKeySourceReturnsEmptyForUnknownProvider() throws {
        let url = fixtureURL("ai_infra_keys", ext: "yaml")
        let source = AIInfraYamlKeySource(fileURL: url)
        let keys = try source.keys(forProvider: "nonexistent")
        XCTAssertTrue(keys.isEmpty)
    }
}
