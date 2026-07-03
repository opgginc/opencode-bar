import XCTest
@testable import OpenCode_Bar

final class KimiProviderTests: XCTestCase {
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

    private func makeStubTokenManager() -> TokenManager {
        TokenManager.shared
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testWeeklyUsedUsesDirectUsedFieldWhenPresent() async throws {
        let json = """
        {
          "user": {"userId": "u1", "membership": {"level": "LEVEL_VIVACE"}},
          "usage": {"limit": "100", "used": "25", "remaining": "80", "resetTime": "2026-07-08T02:32:44Z"},
          "limits": [{"window": {"duration": 5, "timeUnit": "HOUR"},
                      "detail": {"limit": "50", "used": "0", "remaining": "46", "resetTime": "2026-07-01T08:00:00Z"}}]
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, json)
        }

        let provider = KimiCNProvider(tokenManager: makeStubTokenManager(), session: makeSession())
        let result = try await provider.fetch()

        XCTAssertEqual(result.details?.sevenDayUsage ?? -1, 25.0, accuracy: 0.01)
        XCTAssertEqual(result.details?.fiveHourUsage ?? -1, 0.0, accuracy: 0.01)
    }

    func testWeeklyUsedFallsBackToLimitMinusRemainingWhenUsedMissing() async throws {
        let json = """
        {
          "user": {"userId": "u1", "membership": {"level": "LEVEL_VIVACE"}},
          "usage": {"limit": "100", "remaining": "40", "resetTime": "2026-07-08T02:32:44Z"},
          "limits": [{"window": {"duration": 5, "timeUnit": "HOUR"},
                      "detail": {"limit": "50", "remaining": "45", "resetTime": "2026-07-01T08:00:00Z"}}]
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, json)
        }

        let provider = KimiCNProvider(tokenManager: makeStubTokenManager(), session: makeSession())
        let result = try await provider.fetch()

        XCTAssertEqual(result.details?.sevenDayUsage ?? -1, 60.0, accuracy: 0.01)
    }

    func testIntermediateLevelMapsToModeratoInProviderResult() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("opencode"),
            withIntermediateDirectories: true
        )
        let authURL = tempDir.appendingPathComponent("opencode/auth.json")
        let authJSON = """
        { "kimi-for-coding-cn": {"type": "apiKey", "key": "cn-kimi-key"} }
        """
        try authJSON.write(to: authURL, atomically: true, encoding: .utf8)

        let originalXDG = getenv("XDG_DATA_HOME").flatMap { String(cString: $0) }
        setenv("XDG_DATA_HOME", tempDir.path, 1)
        defer {
            if let originalXDG {
                setenv("XDG_DATA_HOME", originalXDG, 1)
            } else {
                unsetenv("XDG_DATA_HOME")
            }
            try? FileManager.default.removeItem(at: tempDir)
        }

        TokenManager.shared.resetCachedAuthForTesting()

        let json = """
        {
          "user": {"userId": "u1", "region": "REGION_CN", "membership": {"level": "LEVEL_INTERMEDIATE"}},
          "usage": {"limit": "100", "remaining": "88", "resetTime": "2026-07-08T02:32:44Z"},
          "limits": [{"window": {"duration": 5, "timeUnit": "HOUR"},
                      "detail": {"limit": "100", "remaining": "64", "resetTime": "2026-07-01T08:00:00Z"}}]
        }
        """

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(json.utf8))
        }

        let provider = KimiCNProvider(tokenManager: .shared, session: makeSession())
        let result = try await provider.fetch()

        XCTAssertEqual(result.details?.planType, "Moderato")
    }

    func testKimiCNProviderIdentifierAndType() {
        let provider = KimiCNProvider()
        XCTAssertEqual(provider.identifier, .kimiCN)
        XCTAssertEqual(provider.type, .quotaBased)
    }

    func testKimiGlobalProviderIdentifierAndType() {
        let provider = KimiGlobalProvider()
        XCTAssertEqual(provider.identifier, .kimi)
        XCTAssertEqual(provider.type, .quotaBased)
    }

    func testKimiProvidersUseSameEndpointAndDifferentKeys() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("opencode"),
            withIntermediateDirectories: true
        )
        let authURL = tempDir.appendingPathComponent("opencode/auth.json")
        let authJSON = """
        {
          "kimi-for-coding": {"type": "apiKey", "key": "global-kimi-key"},
          "kimi-for-coding-cn": {"type": "apiKey", "key": "cn-kimi-key"}
        }
        """
        try authJSON.write(to: authURL, atomically: true, encoding: .utf8)

        let originalXDG = getenv("XDG_DATA_HOME").flatMap { String(cString: $0) }
        setenv("XDG_DATA_HOME", tempDir.path, 1)
        defer {
            if let originalXDG {
                setenv("XDG_DATA_HOME", originalXDG, 1)
            } else {
                unsetenv("XDG_DATA_HOME")
            }
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Reset TokenManager cache so the new XDG_DATA_HOME is read.
        TokenManager.shared.resetCachedAuthForTesting()

        let responseJSON = """
        {
          "user": {"userId": "u1", "membership": {"level": "LEVEL_VIVACE"}},
          "usage": {"limit": "100", "remaining": "40", "resetTime": "2026-07-08T02:32:44Z"},
          "limits": [{"window": {"duration": 5, "timeUnit": "HOUR"},
                      "detail": {"limit": "50", "remaining": "45", "resetTime": "2026-07-01T08:00:00Z"}}]
        }
        """

        var capturedRequests: [URLRequest] = []
        MockURLProtocol.requestHandler = { request in
            capturedRequests.append(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(responseJSON.utf8))
        }

        let session = makeSession()

        let cnProvider = KimiCNProvider(tokenManager: .shared, session: session)
        let globalProvider = KimiGlobalProvider(tokenManager: .shared, session: session)

        _ = try await cnProvider.fetch()
        _ = try await globalProvider.fetch()

        XCTAssertEqual(capturedRequests.count, 2)
        for request in capturedRequests {
            XCTAssertEqual(request.url?.absoluteString, "https://api.kimi.com/coding/v1/usages")
            XCTAssertEqual(request.httpMethod, "GET")
        }

        let cnAuthorization = capturedRequests[0].value(forHTTPHeaderField: "Authorization")
        let globalAuthorization = capturedRequests[1].value(forHTTPHeaderField: "Authorization")

        XCTAssertEqual(cnAuthorization, "Bearer cn-kimi-key")
        XCTAssertEqual(globalAuthorization, "Bearer global-kimi-key")
    }
}
