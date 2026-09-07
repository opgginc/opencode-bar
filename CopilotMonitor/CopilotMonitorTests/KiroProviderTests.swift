import XCTest
import SQLite3
@testable import OpenCode_Bar

final class KiroProviderTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL { directory.appendingPathComponent("data.sqlite3") }
    private var session: URLSession!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KiroTestURLProtocol.self]
        session = URLSession(configuration: configuration)
        KiroTestURLProtocol.requests = []
        KiroTestURLProtocol.status = 200
        KiroTestURLProtocol.body = Self.usageData
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        try FileManager.default.removeItem(at: directory)
    }

    func testFetchUsesStoredTokenAndLeavesDatabaseUnchanged() async throws {
        try writeCredentials()
        let before = try Data(contentsOf: databaseURL)
        let result = try await KiroProvider(databaseURL: databaseURL, session: session).fetch()
        let request = try XCTUnwrap(KiroTestURLProtocol.requests.first)
        XCTAssertEqual(KiroTestURLProtocol.requests.count, 1)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "management.us-east-1.kiro.dev")
        XCTAssertEqual(request.url?.path, "/Get-Usage-Limits")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(result.usage.totalEntitlement, 100_000)
        XCTAssertEqual(result.usage.remainingQuota, 99_634)
        XCTAssertEqual(result.details?.authSource, databaseURL.path)
        XCTAssertEqual(try Data(contentsOf: databaseURL), before)
    }

    func testExpiredCredentialsFailBeforeNetworkAccess() async throws {
        try writeCredentials(expiry: "2000-01-01T00:00:00Z")
        try await assertAuthenticationFailure()
        XCTAssertTrue(KiroTestURLProtocol.requests.isEmpty)
    }

    func testMissingDatabaseIsNotCreated() async throws {
        try await assertAuthenticationFailure()
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
        XCTAssertTrue(KiroTestURLProtocol.requests.isEmpty)
    }

    func testRejectedCredentialsDoNotRetryOrModifyTokens() async throws {
        try writeCredentials()
        let before = try Data(contentsOf: databaseURL)
        for status in [401, 403] {
            KiroTestURLProtocol.status = status
            KiroTestURLProtocol.requests = []
            try await assertAuthenticationFailure()
            XCTAssertEqual(KiroTestURLProtocol.requests.count, 1)
            XCTAssertEqual(try Data(contentsOf: databaseURL), before)
        }
    }

    func testMalformedCredentialsFailBeforeNetworkAccess() async throws {
        try writeCredentials(expiry: "invalid-date")
        try await assertAuthenticationFailure()
        XCTAssertTrue(KiroTestURLProtocol.requests.isEmpty)
    }

    func testMultipleCredentialRecordsFailBeforeNetworkAccess() async throws {
        try writeCredentials()
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database,
            "INSERT INTO auth_kv SELECT 'kirocli:odic:token', value FROM auth_kv", nil, nil, nil), SQLITE_OK)
        try await assertAuthenticationFailure()
        XCTAssertTrue(KiroTestURLProtocol.requests.isEmpty)
    }

    func testIdentityCenterUsesRegionalEndpointAndTokenType() async throws {
        try writeCredentials(key: "kirocli:odic:token", region: "eu-central-1")
        _ = try await KiroProvider(databaseURL: databaseURL, session: session).fetch()
        let request = try XCTUnwrap(KiroTestURLProtocol.requests.first)
        XCTAssertEqual(request.url?.host, "management.eu-central-1.kiro.dev")
        XCTAssertEqual(request.value(forHTTPHeaderField: "TokenType"), "SSO_OIDC")
    }

    func testInvalidRegionCannotChangeCredentialDestination() async throws {
        try writeCredentials(region: "us-east-1.evil.example/")
        try await assertAuthenticationFailure()
        XCTAssertTrue(KiroTestURLProtocol.requests.isEmpty)
    }

    func testUsagePreservesPrecisionOveragesAndBonusExpiry() throws {
        let data = Data(#"""
        {
          "nextDateReset": 2000000000,
          "subscriptionInfo": {"subscriptionTitle": "KIRO PRO+"},
          "overageConfiguration": {"overageStatus": "ENABLED"},
          "usageBreakdownList": [{
            "resourceType": "CREDIT", "currentUsage": 1050, "currentUsageWithPrecision": 1050.25,
            "usageLimit": 1000, "usageLimitWithPrecision": 1000,
            "freeTrialInfo": {"freeTrialStatus": "ACTIVE", "currentUsage": 25,
              "usageLimit": 100, "freeTrialExpiry": 1900000000},
            "bonuses": [{"status": "ACTIVE", "currentUsage": 50, "usageLimit": 100, "expiresAt": 100}]
          }]
        }
        """#.utf8)
        let result = try KiroProvider.parseUsageResponse(data, authSource: "test", now: Date(timeIntervalSince1970: 1800000000))
        XCTAssertEqual(result.usage.remainingQuota, -5_025)
        XCTAssertEqual(result.details?.creditsRemaining, -50.25)
        XCTAssertEqual(result.details?.planType, "Pro+")
        XCTAssertEqual(result.details?.secondaryUsage, 25)
        XCTAssertEqual(result.details?.secondaryReset, Date(timeIntervalSince1970: 1900000000))
        XCTAssertEqual(result.details?.primaryReset, Date(timeIntervalSince1970: 2000000000))
        if case .quotaBased(_, _, let enabled) = result.usage {
            XCTAssertTrue(enabled)
        } else {
            XCTFail("Expected quota usage")
        }
    }

    func testInvalidCreditResponsesFail() {
        for json in [
            #"{"usageBreakdownList":[]}"#,
            #"{"usageBreakdownList":[{"resourceType":"CREDIT","currentUsage":-1,"usageLimit":50}]}"#,
            #"{"usageBreakdownList":[{"resourceType":"CREDIT","currentUsage":0,"usageLimit":0}]}"#,
            #"{"usageBreakdownList":[{"resourceType":"CREDIT","currentUsage":1e100,"usageLimit":50}]}"#
        ] {
            XCTAssertThrowsError(try KiroProvider.parseUsageResponse(Data(json.utf8), authSource: "test"))
        }
    }

    func testInvalidBonusUsageFailsBeforeMenuConversion() {
        for bonus in [
            #"{"status":"ACTIVE","currentUsage":1e100,"usageLimit":1}"#,
            #"{"status":"ACTIVE","currentUsage":-1,"usageLimit":100}"#,
            #"{"status":"ACTIVE","currentUsage":1,"usageLimit":0}"#
        ] {
            let json = """
            {"usageBreakdownList":[{"resourceType":"CREDIT","currentUsage":0,"usageLimit":50,"bonuses":[\(bonus)]}]}
            """
            XCTAssertThrowsError(try KiroProvider.parseUsageResponse(Data(json.utf8), authSource: "test"))
        }
    }

    private func assertAuthenticationFailure() async throws {
        do {
            _ = try await KiroProvider(databaseURL: databaseURL, session: session).fetch()
            XCTFail("Expected authentication failure")
        } catch ProviderError.authenticationFailed {
            // Authentication failures terminate the fetch here.
        }
    }

    private func writeCredentials(
        expiry: String = "2099-01-01T00:00:00.123456Z", key: String = "kirocli:social:token",
        region: String = "us-east-1"
    ) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let value: [String: Any] = [
            "access_token": "test-access-token", "expires_at": expiry,
            "refresh_token": "owned-by-kiro", "region": region,
            "profile_arn": "arn:aws:codewhisperer:\(region):123456789012:profile/test"
        ]
        let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: value), encoding: .utf8))
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE auth_kv (key TEXT PRIMARY KEY, value TEXT)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "INSERT INTO auth_kv VALUES ('\(key)', '\(json)')", nil, nil, nil), SQLITE_OK)
    }

    private static let usageData = Data(#"""
    {
      "nextDateReset": 2000000000,
      "subscriptionInfo": {"subscriptionTitle": "KIRO PRO"},
      "overageConfiguration": {"overageStatus": "DISABLED"},
      "usageBreakdownList": [{"resourceType": "CREDIT", "currentUsageWithPrecision": 3.66,
        "usageLimitWithPrecision": 1000}]
    }
    """#.utf8)
}

private class KiroTestURLProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    static var status = 200
    static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
