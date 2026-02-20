import XCTest
@testable import OpenCode_Bar

final class NanoGptProviderTests: XCTestCase {
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
        let provider = NanoGptProvider()
        XCTAssertEqual(provider.identifier, .nanoGpt)
    }

    func testProviderType() {
        let provider = NanoGptProvider()
        XCTAssertEqual(provider.type, .quotaBased)
    }

    func testFetchSuccessCreatesProviderResult() async throws {
        guard TokenManager.shared.getNanoGptAPIKey() != nil else {
            throw XCTSkip("Nano-GPT API key not available; skipping fetch test.")
        }

        let session = makeSession()
        let provider = NanoGptProvider(tokenManager: .shared, session: session)

        let usageJSON = """
        {
          "active": true,
          "limits": { "daily": 5000, "weeklyInputTokens": 35000, "monthly": 60000 },
          "daily": { "used": 5, "remaining": 4995, "percentUsed": 0.001, "resetAt": 1738540800000 },
          "weeklyInputTokens": { "used": 1200, "remaining": 33800, "percentUsed": 0.0342857, "resetAt": 1738886400000 },
          "monthly": { "used": 45, "remaining": 59955, "percentUsed": 0.00075, "resetAt": 1739404800000 },
          "period": { "currentPeriodEnd": "2025-02-13T23:59:59.000Z" }
        }
        """

        let balanceJSON = """
        {
          "usd_balance": "129.46956147",
          "nano_balance": "26.71801147"
        }
        """

        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            if url.path == "/api/subscription/v1/usage" {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(usageJSON.utf8))
            }

            if url.path == "/api/check-balance" {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(balanceJSON.utf8))
            }

            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let result = try await provider.fetch()

        switch result.usage {
        case .quotaBased(let remaining, let entitlement, let overagePermitted):
            XCTAssertEqual(remaining, 33800)
            XCTAssertEqual(entitlement, 35000)
            XCTAssertFalse(overagePermitted)
        default:
            XCTFail("Expected quota-based usage")
        }

        XCTAssertEqual(result.details?.sevenDayUsage ?? -1, 3.42857, accuracy: 0.001)
        XCTAssertNil(result.details?.tokenUsagePercent)
        XCTAssertNil(result.details?.tokenUsageUsed)
        XCTAssertNil(result.details?.tokenUsageTotal)
        XCTAssertNil(result.details?.mcpUsagePercent)
        XCTAssertNil(result.details?.mcpUsageUsed)
        XCTAssertNil(result.details?.mcpUsageTotal)
        XCTAssertEqual(result.details?.creditsBalance ?? -1, 129.46956147, accuracy: 0.0000001)
        XCTAssertEqual(result.details?.totalCredits ?? -1, 26.71801147, accuracy: 0.0000001)
        XCTAssertNotNil(result.details?.sevenDayReset)
    }

    func testFetchReturnsAuthenticationErrorOn401() async throws {
        guard TokenManager.shared.getNanoGptAPIKey() != nil else {
            throw XCTSkip("Nano-GPT API key not available; skipping fetch test.")
        }

        let session = makeSession()
        let provider = NanoGptProvider(tokenManager: .shared, session: session)

        MockURLProtocol.requestHandler = { request in
            let url = request.url ?? URL(string: "https://nano-gpt.com")!
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

    func testFetchSucceedsWhenBalanceEndpointFails() async throws {
        guard TokenManager.shared.getNanoGptAPIKey() != nil else {
            throw XCTSkip("Nano-GPT API key not available; skipping fetch test.")
        }

        let session = makeSession()
        let provider = NanoGptProvider(tokenManager: .shared, session: session)

        let usageJSON = """
        {
          "limits": { "daily": 5000, "weeklyInputTokens": 35000, "monthly": 60000 },
          "daily": { "used": 10, "remaining": 4990, "percentUsed": 0.002, "resetAt": 1738540800000 },
          "weeklyInputTokens": { "used": 1200, "remaining": 33800, "percentUsed": 0.0342857, "resetAt": 1738886400000 },
          "monthly": { "used": 100, "remaining": 59900, "percentUsed": 0.001666, "resetAt": 1739404800000 }
        }
        """

        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            if url.path == "/api/subscription/v1/usage" {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(usageJSON.utf8))
            }

            let response = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }

        let result = try await provider.fetch()
        switch result.usage {
        case .quotaBased(let remaining, let entitlement, _):
            XCTAssertEqual(remaining, 33800)
            XCTAssertEqual(entitlement, 35000)
        default:
            XCTFail("Expected quota-based usage")
        }
        XCTAssertNil(result.details?.creditsBalance)
        XCTAssertNil(result.details?.totalCredits)
    }

    func testFetchParsesWeeklyInputTokensFromSnakeCaseVariants() async throws {
        guard TokenManager.shared.getNanoGptAPIKey() != nil else {
            throw XCTSkip("Nano-GPT API key not available; skipping fetch test.")
        }

        let session = makeSession()
        let provider = NanoGptProvider(tokenManager: .shared, session: session)

        let usageJSON = """
        {
          "active": true,
          "limits": { "daily": 5000, "weekly_input_tokens": 35000, "monthly": 60000 },
          "daily": { "used": 10, "remaining": 4990, "percent_used": "0.2%", "reset_at": 1738540800000 },
          "input_tokens": {
            "weekly_input_tokens": {
              "usage": 1750,
              "left": 33250,
              "usage_percent": 5,
              "next_reset_at": 1738886400000
            }
          },
          "monthly": { "used": 100, "remaining": 59900, "percentUsed": 0.001666, "resetAt": 1739404800000 }
        }
        """

        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            if url.path == "/api/subscription/v1/usage" {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(usageJSON.utf8))
            }

            let response = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }

        let result = try await provider.fetch()

        XCTAssertEqual(result.details?.sevenDayUsage ?? -1, 5.0, accuracy: 0.001)
        XCTAssertNotNil(result.details?.sevenDayReset)
        XCTAssertNil(result.details?.tokenUsagePercent)
        XCTAssertNil(result.details?.mcpUsagePercent)
    }

    func testFetchFallsBackToWeeklyWhenMonthlyQuotaMissing() async throws {
        guard TokenManager.shared.getNanoGptAPIKey() != nil else {
            throw XCTSkip("Nano-GPT API key not available; skipping fetch test.")
        }

        let session = makeSession()
        let provider = NanoGptProvider(tokenManager: .shared, session: session)

        let usageJSON = """
        {
          "active": true,
          "limits": { "weeklyInputTokens": 60000000, "dailyInputTokens": null },
          "weeklyInputTokens": {
            "used": 17077091,
            "remaining": 42922909,
            "percentUsed": 0.28461818333333333,
            "resetAt": 1771804800000
          },
          "dailyInputTokens": null,
          "period": { "currentPeriodEnd": "2026-03-12T16:50:28.000Z" }
        }
        """

        let balanceJSON = """
        {
          "usd_balance": "0.00000000",
          "nano_balance": "0.00000000"
        }
        """

        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            if url.path == "/api/subscription/v1/usage" {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(usageJSON.utf8))
            }

            if url.path == "/api/check-balance" {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(balanceJSON.utf8))
            }

            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let result = try await provider.fetch()

        switch result.usage {
        case .quotaBased(let remaining, let entitlement, let overagePermitted):
            XCTAssertEqual(remaining, 42922909)
            XCTAssertEqual(entitlement, 60000000)
            XCTAssertFalse(overagePermitted)
        default:
            XCTFail("Expected quota-based usage")
        }

        XCTAssertEqual(result.details?.sevenDayUsage ?? -1, 28.4618183, accuracy: 0.0001)
        XCTAssertNotNil(result.details?.sevenDayReset)
        XCTAssertNil(result.details?.tokenUsagePercent)
        XCTAssertNil(result.details?.tokenUsageUsed)
        XCTAssertNil(result.details?.tokenUsageTotal)
        XCTAssertNil(result.details?.mcpUsagePercent)
        XCTAssertNil(result.details?.mcpUsageUsed)
        XCTAssertNil(result.details?.mcpUsageTotal)
    }

    func testFetchReturnsDecodingErrorWhenWeeklyQuotaMissing() async throws {
        guard TokenManager.shared.getNanoGptAPIKey() != nil else {
            throw XCTSkip("Nano-GPT API key not available; skipping fetch test.")
        }

        let session = makeSession()
        let provider = NanoGptProvider(tokenManager: .shared, session: session)

        let usageJSON = """
        {
          "active": true,
          "limits": { "monthly": 60000 },
          "monthly": { "used": 100, "remaining": 59900, "percentUsed": 0.001666, "resetAt": 1739404800000 }
        }
        """

        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            if url.path == "/api/subscription/v1/usage" {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(usageJSON.utf8))
            }

            let response = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }

        do {
            _ = try await provider.fetch()
            XCTFail("Expected decoding failure for missing weekly quota")
        } catch let error as ProviderError {
            switch error {
            case .decodingError(let message):
                XCTAssertEqual(message, "Missing Nano-GPT weekly quota limit")
            default:
                XCTFail("Unexpected provider error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
