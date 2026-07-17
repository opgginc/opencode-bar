import XCTest
@testable import OpenCode_Bar

final class GeminiCLIProviderTests: XCTestCase {
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

    private static func requestBodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }
    
    func testParseGeminiQuotaResponse() throws {
        let fixture = try loadFixture(named: "gemini_response")
        let data = try JSONSerialization.data(withJSONObject: fixture, options: [])
        
        let decoder = JSONDecoder()
        let response = try decoder.decode(GeminiQuotaResponse.self, from: data)
        
        XCTAssertEqual(response.buckets.count, 5)
        
        XCTAssertEqual(response.buckets[0].modelId, "gemini-2.0-flash")
        XCTAssertEqual(response.buckets[0].remainingFraction, 1.0)
        XCTAssertEqual(response.buckets[0].resetTime, "2026-01-30T17:05:02Z")
        
        XCTAssertEqual(response.buckets[1].modelId, "gemini-2.5-flash")
        XCTAssertEqual(response.buckets[1].remainingFraction, 1.0)
        
        XCTAssertEqual(response.buckets[2].modelId, "gemini-2.5-pro")
        XCTAssertEqual(response.buckets[2].remainingFraction, 0.85)
        
        XCTAssertEqual(response.buckets[3].modelId, "gemini-3-flash-preview")
        XCTAssertEqual(response.buckets[3].remainingFraction, 0.95)
        
        XCTAssertEqual(response.buckets[4].modelId, "gemini-3-pro-preview")
        XCTAssertEqual(response.buckets[4].remainingFraction, 0.80)
    }
    
    func testMinimumRemainingFractionCalculation() throws {
        let fixture = try loadFixture(named: "gemini_response")
        let data = try JSONSerialization.data(withJSONObject: fixture, options: [])
        
        let decoder = JSONDecoder()
        let response = try decoder.decode(GeminiQuotaResponse.self, from: data)
        
        let minFraction = response.buckets.map(\.remainingFraction).min()
        
        XCTAssertEqual(minFraction, 0.80)
        
        let remainingPercentage = (minFraction ?? 0.0) * 100.0
        XCTAssertEqual(remainingPercentage, 80.0)
    }
    
    func testResetTimeParsingFromISO8601() throws {
        let fixture = try loadFixture(named: "gemini_response")
        let data = try JSONSerialization.data(withJSONObject: fixture, options: [])
        
        let decoder = JSONDecoder()
        let response = try decoder.decode(GeminiQuotaResponse.self, from: data)
        
        let formatter = ISO8601DateFormatter()
        let resetDates = response.buckets.compactMap { bucket -> Date? in
            formatter.date(from: bucket.resetTime)
        }
        
        XCTAssertEqual(resetDates.count, 5)
        
        let earliestReset = resetDates.min()
        XCTAssertNotNil(earliestReset)
    }

    func testQuotaRequestUsesDefaultProjectAndDecodesSuccessfulResponse() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let fixture = try loadFixture(named: "gemini_response")
        let responseData = try JSONSerialization.data(withJSONObject: fixture)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let requestData = try XCTUnwrap(Self.requestBodyData(from: request))
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestData) as? [String: String]
            )
            XCTAssertEqual(payload, ["project": "default"])

            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (response, responseData)
        }

        let response = try await GeminiQuotaAPI.fetchQuota(
            accessToken: "test-access-token",
            projectId: GeminiProjectPolicy.resolve(primary: nil),
            session: session
        )

        XCTAssertEqual(response.buckets.count, 5)
        XCTAssertEqual(response.buckets.last?.modelId, "gemini-3-pro-preview")
    }

    func testOAuthRefreshPreservesInvalidGrantWithoutRetry() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)
            )
            let data = Data(#"{"error":"invalid_grant","error_description":"Token expired"}"#.utf8)
            return (response, data)
        }

        do {
            _ = try await TokenManager.shared.requestGeminiAccessToken(
                refreshToken: "test-refresh-token",
                clientId: "account-client",
                clientSecret: "account-secret",
                session: session
            )
            XCTFail("Expected typed OAuth rejection")
        } catch let error as GeminiOAuthRefreshError {
            XCTAssertEqual(
                error,
                .rejected(statusCode: 400, code: "invalid_grant", message: "Token expired")
            )
            XCTAssertFalse(
                GeminiOAuthRetryPolicy.shouldRetryWithGeminiCLIClient(
                    source: .opencodeAuth,
                    error: error
                )
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOAuthRefreshClassifiesOpenCodeClientMismatchForRetry() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)
            )
            return (response, Data(#"{"error":"Unauthorized"}"#.utf8))
        }

        do {
            _ = try await TokenManager.shared.requestGeminiAccessToken(
                refreshToken: "test-refresh-token",
                clientId: "opencode-plugin-client",
                clientSecret: "opencode-plugin-secret",
                session: session
            )
            XCTFail("Expected typed OAuth rejection")
        } catch let error as GeminiOAuthRefreshError {
            XCTAssertTrue(error.isClientMismatch)
            XCTAssertTrue(
                GeminiOAuthRetryPolicy.shouldRetryWithGeminiCLIClient(
                    source: .opencodeAuth,
                    error: error
                )
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOAuthRetryPolicyAllowsOnlyOpenCodeClientMismatch() {
        let mismatch = GeminiOAuthRefreshError.rejected(
            statusCode: 401,
            code: "unauthorized_client",
            message: nil
        )

        XCTAssertTrue(
            GeminiOAuthRetryPolicy.shouldRetryWithGeminiCLIClient(
                source: .opencodeAuth,
                error: mismatch
            )
        )
        XCTAssertFalse(
            GeminiOAuthRetryPolicy.shouldRetryWithGeminiCLIClient(
                source: .antigravity,
                error: mismatch
            )
        )
        XCTAssertFalse(
            GeminiOAuthRetryPolicy.shouldRetryWithGeminiCLIClient(
                source: .oauthCreds,
                error: mismatch
            )
        )
    }
    
    private func loadFixture(named: String) throws -> Any {
        let testBundle = Bundle(for: type(of: self))
        
        guard let url = testBundle.url(forResource: named, withExtension: "json") else {
            throw NSError(domain: "FixtureError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture file not found: \(named)"])
        }
        
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        return json
    }
}
