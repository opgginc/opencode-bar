import XCTest
@testable import OpenCode_Bar

final class OpenCodeGoProviderTests: XCTestCase {
    override func tearDown() {
        resetMockURLProtocol()
        super.tearDown()
    }

    func testProviderIdentifier() {
        let provider = OpenCodeGoProvider()
        XCTAssertEqual(provider.identifier, .openCodeGo)
    }

    func testProviderType() {
        let provider = OpenCodeGoProvider()
        XCTAssertEqual(provider.type, .quotaBased)
    }

    func testUsageAPIParserReadsRollingWeeklyMonthlyWindows() throws {
        let json = """
        {"usage":{"rolling":{"status":"ok","percent":4,"resetsAt":"2026-09-17T05:42:46.182Z"},"weekly":{"status":"ok","percent":"8","resetsAt":"2026-09-21T00:00:00Z"},"monthly":{"status":"ok","percent":2}}}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))

        let usage = try OpenCodeGoProvider.parseUsageAPIJSON(data)

        XCTAssertEqual(usage.rolling?.usagePercent ?? -1, 4, accuracy: 0.001)
        XCTAssertEqual(usage.weekly?.usagePercent ?? -1, 8, accuracy: 0.001)
        XCTAssertEqual(usage.monthly?.usagePercent ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(
            usage.rolling?.resetDate,
            APIValueParser.parseDate(from: "2026-09-17T05:42:46.182Z")
        )
        XCTAssertEqual(
            usage.weekly?.resetDate,
            APIValueParser.parseDate(from: "2026-09-21T00:00:00Z")
        )
        XCTAssertNil(usage.monthly?.resetDate)
        XCTAssertEqual(usage.missingWindowNames, [])
    }

    func testUsageAPIParserThrowsWhenNoWindows() throws {
        for json in [
            """
            {"usage":{}}
            """,
            """
            {"usage":{"rolling":{"status":"expired","percent":99,"resetsAt":"2026-09-17T05:42:46Z"}}}
            """
        ] {
            let data = try XCTUnwrap(json.data(using: .utf8))
            XCTAssertThrowsError(try OpenCodeGoProvider.parseUsageAPIJSON(data))
        }
    }

    func testUsageAPIParserSkipsNonOkWindows() throws {
        let json = """
        {"usage":{"rolling":{"status":"expired","percent":99,"resetsAt":"2026-09-17T05:42:46Z"},"weekly":{"status":"ok","percent":8,"resetsAt":"2026-09-21T00:00:00Z"}}}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))

        let usage = try OpenCodeGoProvider.parseUsageAPIJSON(data)

        XCTAssertNil(usage.rolling)
        XCTAssertEqual(usage.weekly?.usagePercent ?? -1, 8, accuracy: 0.001)
        XCTAssertEqual(usage.missingWindowNames, ["rolling", "monthly"])
    }

    func testUsageAPIParserSkipsWindowWithBadPercent() throws {
        let json = """
        {"usage":{"rolling":{"status":"ok","percent":true,"resetsAt":"2026-09-17T05:42:46Z"},"weekly":{"status":"ok","percent":8,"resetsAt":"2026-09-21T00:00:00Z"}}}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))

        let usage = try OpenCodeGoProvider.parseUsageAPIJSON(data)

        XCTAssertNil(usage.rolling)
        XCTAssertEqual(usage.weekly?.usagePercent ?? -1, 8, accuracy: 0.001)
        XCTAssertEqual(usage.missingWindowNames, ["rolling", "monthly"])
    }

    func testFetchUsesUsageAPIAndLabelsSource() async throws {
        let session = makeMockSession()
        let provider = OpenCodeGoProvider(session: session, apiKey: "test-key")
        let modelsJSON = """
        {"data":[{},{},{}]}
        """
        let usageJSON = """
        {"usage":{"rolling":{"status":"ok","percent":4,"resetsAt":"2026-09-17T05:42:46.182Z"},"weekly":{"status":"ok","percent":8,"resetsAt":"2026-09-21T00:00:00Z"},"monthly":{"status":"ok","percent":2,"resetsAt":"2026-10-15T12:50:56Z"}}}
        """

        SharedMockURLProtocol.requestHandler = { request in
            let url = request.url?.absoluteString ?? ""
            XCTAssertTrue((request.value(forHTTPHeaderField: "Authorization") ?? "").hasPrefix("Bearer "))
            let body: String
            if url == OpenCodeGoAPI.usageURL.absoluteString {
                body = usageJSON
            } else {
                XCTAssertEqual(url, OpenCodeGoAPI.modelsURL.absoluteString)
                body = modelsJSON
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }

        let result = try await provider.fetch()

        switch result.usage {
        case .quotaBased(let remaining, let entitlement, let overagePermitted):
            XCTAssertEqual(remaining, 92)
            XCTAssertEqual(entitlement, 100)
            XCTAssertFalse(overagePermitted)
        default:
            XCTFail("Expected quota-based usage")
        }

        XCTAssertEqual(result.details?.fiveHourUsage ?? -1, 4, accuracy: 0.001)
        XCTAssertEqual(result.details?.sevenDayUsage ?? -1, 8, accuracy: 0.001)
        XCTAssertEqual(result.details?.openCodeGoMonthlyUsage ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(result.details?.openCodeGoModelCount, 3)
        XCTAssertEqual(result.details?.authUsageSummary, OpenCodeGoAPI.usageSourceLabel)
    }

    func testFetchPreservesErrorClassification() async throws {
        let session = makeMockSession()

        for (statusCode, check) in [
            (401, "authenticationFailed"),
            (500, "networkError")
        ] as [(Int, String)] {
            let provider = OpenCodeGoProvider(session: session, apiKey: "test-key")
            SharedMockURLProtocol.requestHandler = { request in
                let url = request.url?.absoluteString ?? ""
                let code = url == OpenCodeGoAPI.usageURL.absoluteString ? statusCode : 200
                let body = code == 200 ? """
                {"data":[{}]}
                """ : """
                {"type":"error","error":{"type":"AuthError","message":"Unauthorized"}}
                """
                let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
                return (response, Data(body.utf8))
            }

            do {
                _ = try await provider.fetch()
                XCTFail("Expected error for HTTP \(statusCode)")
            } catch let error as ProviderError {
                switch (statusCode, error) {
                case (401, .authenticationFailed), (500, .networkError):
                    break
                default:
                    XCTFail("HTTP \(statusCode) must stay \(check), got \(error)")
                }
            }
            resetMockURLProtocol()
        }
    }

    func testOpenCodeGoAPIKeyDecodes() throws {
        let json = """
        {
            "opencode-go": {
                "type": "api",
                "key": "opencode-go-test-key"
            }
        }
        """

        let data = try XCTUnwrap(json.data(using: .utf8))
        let auth = try JSONDecoder().decode(OpenCodeAuth.self, from: data)

        XCTAssertEqual(auth.openCodeGo?.key, "opencode-go-test-key")
    }
}
