import XCTest
@testable import CopilotMonitor

final class SyntheticProviderTests: XCTestCase {
    private final class MockURLProtocol: URLProtocol {
        static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool {
            return true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            return request
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

    private func makeHTTPResponse(statusCode: Int) -> HTTPURLResponse {
        let url = URL(string: "https://api.synthetic.new/v2/quotas")!
        return HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testProviderIdentifier() {
        let provider = SyntheticProvider()
        XCTAssertEqual(provider.identifier, .synthetic)
    }

    func testProviderType() {
        let provider = SyntheticProvider()
        XCTAssertEqual(provider.type, .quotaBased)
    }

    func testFetchSuccessCreatesProviderResult() async throws {
        guard TokenManager.shared.getSyntheticAPIKey() != nil else {
            throw XCTSkip("Synthetic API key not available; skipping fetch test.")
        }
        let expectedAuthPath = TokenManager.shared.lastFoundAuthPath?.path
        let session = makeSession()
        let provider = SyntheticProvider(tokenManager: .shared, session: session)

        let json = """
        {
          "subscription": {
            "limit": 200,
            "requests": 50.5,
            "renewsAt": "2026-02-05T14:59:30.123Z"
          }
        }
        """
        let data = json.data(using: .utf8)!
        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(statusCode: 200), data)
        }

        let result = try await provider.fetch()

        switch result.usage {
        case .quotaBased(let remaining, let entitlement, let overagePermitted):
            XCTAssertEqual(remaining, 149)
            XCTAssertEqual(entitlement, 200)
            XCTAssertFalse(overagePermitted)
        default:
            XCTFail("Expected quota-based usage")
        }

        XCTAssertEqual(result.details?.limit, 200)
        XCTAssertEqual(result.details?.limitRemaining, 149)
        XCTAssertEqual(result.details?.fiveHourUsage, 25.25, accuracy: 0.01)
        XCTAssertNotNil(result.details?.fiveHourReset)
        XCTAssertEqual(result.details?.authSource, expectedAuthPath)
    }

    func testFetchReturnsAuthenticationErrorOn401() async {
        guard TokenManager.shared.getSyntheticAPIKey() != nil else {
            XCTSkip("Synthetic API key not available; skipping fetch test.")
            return
        }
        let session = makeSession()
        let provider = SyntheticProvider(tokenManager: .shared, session: session)

        let data = Data("{}".utf8)
        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(statusCode: 401), data)
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

    func testFetchReturnsNetworkErrorOnNon200() async {
        guard TokenManager.shared.getSyntheticAPIKey() != nil else {
            XCTSkip("Synthetic API key not available; skipping fetch test.")
            return
        }
        let session = makeSession()
        let provider = SyntheticProvider(tokenManager: .shared, session: session)

        let data = Data("{}".utf8)
        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(statusCode: 500), data)
        }

        do {
            _ = try await provider.fetch()
            XCTFail("Expected network error")
        } catch let error as ProviderError {
            switch error {
            case .networkError(let message):
                XCTAssertTrue(message.contains("HTTP 500"))
            default:
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchReturnsDecodingErrorOnMalformedJSON() async {
        guard TokenManager.shared.getSyntheticAPIKey() != nil else {
            XCTSkip("Synthetic API key not available; skipping fetch test.")
            return
        }
        let session = makeSession()
        let provider = SyntheticProvider(tokenManager: .shared, session: session)

        let data = Data("{".utf8)
        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(statusCode: 200), data)
        }

        do {
            _ = try await provider.fetch()
            XCTFail("Expected decoding error")
        } catch let error as ProviderError {
            switch error {
            case .decodingError:
                break
            default:
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchParsesDateWithoutFractionalSeconds() async throws {
        guard TokenManager.shared.getSyntheticAPIKey() != nil else {
            throw XCTSkip("Synthetic API key not available; skipping fetch test.")
        }
        let session = makeSession()
        let provider = SyntheticProvider(tokenManager: .shared, session: session)

        let json = """
        {
          "subscription": {
            "limit": 100,
            "requests": 20,
            "renewsAt": "2026-02-05T14:59:30Z"
          }
        }
        """
        let data = json.data(using: .utf8)!
        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(statusCode: 200), data)
        }

        let result = try await provider.fetch()
        XCTAssertNotNil(result.details?.fiveHourReset)
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
