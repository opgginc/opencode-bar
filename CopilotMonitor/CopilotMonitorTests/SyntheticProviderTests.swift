import XCTest
@testable import CopilotMonitor

final class SyntheticProviderTests: XCTestCase {
    func testProviderIdentifier() {
        let provider = SyntheticProvider()
        XCTAssertEqual(provider.identifier, .synthetic)
    }

    func testProviderType() {
        let provider = SyntheticProvider()
        XCTAssertEqual(provider.type, .quotaBased)
    }

    func testDecodingWithFractionalRequests() throws {
        let json = """
        {
          "subscription": {
            "limit": 135,
            "requests": 35.6,
            "renewsAt": "2025-09-21T14:36:14.288Z"
          }
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(SyntheticQuotasResponse.self, from: data)

        XCTAssertEqual(response.subscription.limit, 135)
        XCTAssertEqual(response.subscription.requests, 35.6, accuracy: 0.01)
        XCTAssertEqual(response.subscription.renewsAt, "2025-09-21T14:36:14.288Z")
    }

    func testDecodingWithoutFractionalSeconds() throws {
        let json = """
        {
          "subscription": {
            "limit": 100,
            "requests": 0,
            "renewsAt": "2025-12-31T23:59:59Z"
          }
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(SyntheticQuotasResponse.self, from: data)

        XCTAssertEqual(response.subscription.limit, 100)
        XCTAssertEqual(response.subscription.requests, 0)
    }
}
