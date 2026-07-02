import XCTest
@testable import OpenCode_Bar

final class BraveSearchProviderTests: XCTestCase {

    private let refreshModeKey = "searchEngines.brave.refreshMode"
    private let eventEstimatedUsedKey = "searchEngines.brave.eventEstimatedUsed"
    private let eventCursorKey = "searchEngines.brave.eventCursor"
    private let eventMonthKey = "searchEngines.brave.eventMonth"
    private let eventLastScanAtKey = "searchEngines.brave.eventLastScanAt"

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: refreshModeKey)
        defaults.removeObject(forKey: eventEstimatedUsedKey)
        defaults.removeObject(forKey: eventCursorKey)
        defaults.removeObject(forKey: eventMonthKey)
        defaults.removeObject(forKey: eventLastScanAtKey)
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: refreshModeKey)
        defaults.removeObject(forKey: eventEstimatedUsedKey)
        defaults.removeObject(forKey: eventCursorKey)
        defaults.removeObject(forKey: eventMonthKey)
        defaults.removeObject(forKey: eventLastScanAtKey)
        super.tearDown()
    }

    func testEventOnlyModeWithoutAPIKeyReturnsValidResult() async throws {
        let tokenManager = MockBraveSearchTokenManager()
        tokenManager.braveSearchAPIKey = nil

        UserDefaults.standard.set(0, forKey: refreshModeKey)

        let provider = BraveSearchProvider(tokenManager: tokenManager)

        let result = try await provider.fetch()

        if case .quotaBased(_, _, _) = result.usage {
            // Expected
        } else {
            XCTFail("Expected quotaBased usage, got \(result.usage)")
        }

        XCTAssertNotNil(result.details)
        XCTAssertEqual(result.details?.authUsageSummary, "Estimated (event-based)")
        XCTAssertNil(result.details?.authSource)
    }
}

final class MockBraveSearchTokenManager: BraveSearchTokenManaging {
    var braveSearchAPIKey: (key: String, source: String)?

    func getBraveSearchAPIKeyWithSource() -> (key: String, source: String)? {
        return braveSearchAPIKey
    }
}
