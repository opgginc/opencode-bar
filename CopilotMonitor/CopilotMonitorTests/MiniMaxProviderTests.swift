import XCTest
@testable import OpenCode_Bar

final class MiniMaxProviderTests: XCTestCase {
    private final class MockURLProtocol: URLProtocol {
        static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override static func canInit(with request: URLRequest) -> Bool {
            true
        }

        override static func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let handler = MockURLProtocol.requestHandler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }

            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testProviderIdentifier() {
        let provider = MiniMaxProvider()
        XCTAssertEqual(provider.identifier, .minimaxCodingPlan)
    }

    func testProviderType() {
        let provider = MiniMaxProvider()
        XCTAssertEqual(provider.type, .quotaBased)
    }

    func testFetchSuccessCreatesProviderResult() async throws {
        guard TokenManager.shared.getMiniMaxCodingPlanAPIKey() != nil else {
            throw XCTSkip("MiniMax Coding Plan API key not available; skipping fetch test.")
        }

        let session = makeSession()
        let provider = MiniMaxProvider(tokenManager: .shared, session: session)
        let responseJSON = """
        {
          "model_remains": [
            {
              "start_time": 1774569600000,
              "end_time": 1774656000000,
              "remains_time": 52115317,
              "current_interval_total_count": 0,
              "current_interval_usage_count": 0,
              "model_name": "speech-hd",
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0,
              "weekly_start_time": 1774224000000,
              "weekly_end_time": 1774828800000,
              "weekly_remains_time": 224915317
            },
            {
              "start_time": 1774587600000,
              "end_time": 1774605600000,
              "remains_time": 1715317,
              "current_interval_total_count": 1500,
              "current_interval_usage_count": 750,
              "model_name": "MiniMax-M*",
              "current_weekly_total_count": 15000,
              "current_weekly_usage_count": 6000,
              "weekly_start_time": 1774224000000,
              "weekly_end_time": 1774828800000,
              "weekly_remains_time": 224915317
            }
          ],
          "base_resp": {
            "status_code": 0,
            "status_msg": "success"
          }
        }
        """

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.minimax.io/v1/api/openplatform/coding_plan/remains")
            XCTAssertTrue((request.value(forHTTPHeaderField: "Authorization") ?? "").hasPrefix("Bearer "))

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(responseJSON.utf8))
        }

        let result = try await provider.fetch()

        switch result.usage {
        case .quotaBased(let remaining, let entitlement, let overagePermitted):
            XCTAssertEqual(remaining, 40)
            XCTAssertEqual(entitlement, 100)
            XCTAssertFalse(overagePermitted)
        default:
            XCTFail("Expected quota-based usage")
        }

        XCTAssertEqual(result.details?.fiveHourUsage ?? -1, 50.0, accuracy: 0.001)
        XCTAssertEqual(result.details?.sevenDayUsage ?? -1, 60.0, accuracy: 0.001)
        XCTAssertNotNil(result.details?.fiveHourReset)
        XCTAssertNotNil(result.details?.sevenDayReset)
        XCTAssertEqual(result.details?.authSource, "~/.local/share/opencode/auth.json")
    }

    func testFetchReturnsAuthenticationErrorOn401() async throws {
        guard TokenManager.shared.getMiniMaxCodingPlanAPIKey() != nil else {
            throw XCTSkip("MiniMax Coding Plan API key not available; skipping fetch test.")
        }

        let session = makeSession()
        let provider = MiniMaxProvider(tokenManager: .shared, session: session)

        MockURLProtocol.requestHandler = { request in
            let url = request.url ?? URL(string: "https://api.minimax.io")!
            let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }

        do {
            _ = try await provider.fetch()
            XCTFail("Expected authentication failure")
        } catch let error as ProviderError {
            switch error {
            case .authenticationFailed:
                break
            default:
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
