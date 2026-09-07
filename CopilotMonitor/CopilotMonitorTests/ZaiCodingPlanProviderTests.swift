import XCTest
@testable import OpenCode_Bar

final class ZaiCodingPlanProviderTests: XCTestCase {
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

    /// Read the menu produced by the real controller build path without adding
    /// a production-only test accessor to StatusBarController.
    @MainActor
    private func menu(from controller: StatusBarController) -> NSMenu? {
        guard let value = Mirror(reflecting: controller).children
            .first(where: { $0.label == "menu" })?.value else {
            return nil
        }
        return unwrapMenu(value)
    }

    private func unwrapMenu(_ value: Any) -> NSMenu? {
        if let menu = value as? NSMenu {
            return menu
        }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional,
              let child = mirror.children.first else {
            return nil
        }
        return unwrapMenu(child.value)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testProviderIdentifier() {
        let provider = ZaiCodingPlanProvider()
        XCTAssertEqual(provider.identifier, .zaiCodingPlan)
    }

    func testProviderType() {
        let provider = ZaiCodingPlanProvider()
        XCTAssertEqual(provider.type, .quotaBased)
    }

    // MARK: - Helpers

    /// Real Lite-tier response shape: only CREDIT_LIMIT items, two rolling windows
    /// (unit=3 -> 5-hour session, unit=6 -> 7-day weekly), usage/remaining instead
    /// of total, no TOKENS_LIMIT / TIME_LIMIT.
    private let creditOnlyJSON = """
    {
      "data": {
        "limits": [
          {
            "type": "CREDIT_LIMIT",
            "unit": 3,
            "number": 5,
            "usage": 2000,
            "currentValue": 27,
            "remaining": 1972,
            "percentage": 1,
            "nextResetTime": 1786717056698
          },
          {
            "type": "CREDIT_LIMIT",
            "unit": 6,
            "number": 1,
            "usage": 10000,
            "currentValue": 27,
            "remaining": 9972,
            "percentage": 1,
            "nextResetTime": 1787301777997
          }
        ],
        "level": "lite"
      }
    }
    """

    private let modelUsageJSON = """
    {"data": {"totalUsage": {"totalTokensUsage": 120, "totalModelCallCount": 8}}}
    """

    private let toolUsageJSON = """
    {"data": {"totalUsage": {"totalNetworkSearchCount": 1, "totalWebReadMcpCount": 2, "totalZreadMcpCount": 3}}}
    """

    /// Installs a mock session that serves quota/model/tool endpoints and runs
    /// the real `fetch()` pipeline with an injected API key (no credential store).
    private func makeProvider(quotaJSON: String) -> ZaiCodingPlanProvider {
        let session = makeSession()
        let provider = ZaiCodingPlanProvider(tokenManager: .shared, session: session, apiKey: "sk-test-fake")

        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body: String
            if url.path.contains("quota/limit") {
                body = quotaJSON
            } else if url.path.contains("model-usage") {
                body = self.modelUsageJSON
            } else if url.path.contains("tool-usage") {
                body = self.toolUsageJSON
            } else {
                body = "{}"
            }
            return (response, Data(body.utf8))
        }
        return provider
    }

    // MARK: - CREDIT_LIMIT-only (lite tier)

    /// Provider-level regression: a CREDIT_LIMIT-only response with BOTH windows
    /// must surface the 5-hour window as token usage AND the weekly window via
    /// the weekly fields — not drop the second window.
    func testCreditOnlyResponsePopulatesBothWindows() async throws {
        let result = try await makeProvider(quotaJSON: creditOnlyJSON).fetch()
        let details = try XCTUnwrap(result.details)

        // 5-hour session window (unit=3, usage=2000)
        XCTAssertEqual(details.tokenUsagePercent, 1)
        XCTAssertEqual(details.tokenUsageUsed, 27)
        XCTAssertEqual(details.tokenUsageTotal, 2000)
        XCTAssertNotNil(details.tokenUsageReset)

        // Weekly window (unit=6, usage=10000)
        XCTAssertEqual(details.weeklyUsagePercent, 1)
        XCTAssertEqual(details.weeklyUsageUsed, 27)
        XCTAssertEqual(details.weeklyUsageTotal, 10000)
        XCTAssertNotNil(details.weeklyUsageReset)
        // The observed fixture has 27 + 1972 = 1999 while usage is 2000;
        // successful fetch proves no exact remaining arithmetic is required.

        // No MCP window in this schema
        XCTAssertNil(details.mcpUsagePercent)

        // Model/tool usage still fetched
        XCTAssertEqual(details.modelUsageTokens, 120)
        XCTAssertEqual(details.toolNetworkSearchCount, 1)
    }

    func testCreditOnlySingleWindowStillRenders() async throws {
        // A response with only the weekly window (no unit=3 item) must map it
        // to the weekly fields and NOT double-fill the session/token fields.
        let singleWindow = """
        {"data": {"limits": [
          {"type": "CREDIT_LIMIT", "unit": 6, "number": 1, "usage": 10000,
           "currentValue": 27, "remaining": 9972, "percentage": 1,
           "nextResetTime": 1787301777997}
        ], "level": "lite"}}
        """
        let result = try await makeProvider(quotaJSON: singleWindow).fetch()
        let details = try XCTUnwrap(result.details)
        XCTAssertNil(details.tokenUsageTotal)
        XCTAssertNil(details.tokenUsageUsed)
        XCTAssertEqual(details.weeklyUsageTotal, 10000)
        XCTAssertEqual(details.weeklyUsageUsed, 27)
    }

    func testCreditLimitUnitThreeWithFutureDurationIsNotMappedAsFiveHour() async throws {
        let futureHourWindow = """
        {"data": {"limits": [
          {"type": "CREDIT_LIMIT", "unit": 3, "number": 10, "usage": 4000,
           "currentValue": 40, "remaining": 3960, "percentage": 1},
          {"type": "CREDIT_LIMIT", "unit": 6, "number": 1, "usage": 10000,
           "currentValue": 27, "remaining": 9972, "percentage": 1}
        ]}}
        """
        let result = try await makeProvider(quotaJSON: futureHourWindow).fetch()
        let details = try XCTUnwrap(result.details)

        XCTAssertNil(details.tokenUsagePercent)
        XCTAssertNil(details.tokenUsageUsed)
        XCTAssertNil(details.tokenUsageTotal)
        XCTAssertEqual(details.weeklyUsagePercent, 1)
        XCTAssertEqual(details.weeklyUsageTotal, 10000)
    }

    func testCreditLimitUnitSixWithFutureDurationIsNotMappedAsWeekly() async throws {
        let futureWeeklyWindow = """
        {"data": {"limits": [
          {"type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 2000,
           "currentValue": 27, "remaining": 1972, "percentage": 1},
          {"type": "CREDIT_LIMIT", "unit": 6, "number": 2, "usage": 20000,
           "currentValue": 100, "remaining": 19900, "percentage": 1}
        ]}}
        """
        let result = try await makeProvider(quotaJSON: futureWeeklyWindow).fetch()
        let details = try XCTUnwrap(result.details)

        XCTAssertEqual(details.tokenUsagePercent, 1)
        XCTAssertEqual(details.tokenUsageTotal, 2000)
        XCTAssertNil(details.weeklyUsagePercent)
        XCTAssertNil(details.weeklyUsageUsed)
        XCTAssertNil(details.weeklyUsageTotal)
    }

    func testCreditLimitUnitThreeWithoutNumberUsesCompatibilityFallback() async throws {
        let legacySessionWindow = """
        {"data": {"limits": [
          {"type": "CREDIT_LIMIT", "unit": 3, "usage": 2000,
           "currentValue": 27, "percentage": 1}
        ]}}
        """
        let result = try await makeProvider(quotaJSON: legacySessionWindow).fetch()
        let details = try XCTUnwrap(result.details)

        XCTAssertEqual(details.tokenUsagePercent, 1)
        XCTAssertEqual(details.tokenUsageUsed, 27)
        XCTAssertEqual(details.tokenUsageTotal, 2000)
        XCTAssertNil(details.weeklyUsagePercent)
    }

    func testCreditLimitUnitSixWithoutNumberUsesCompatibilityFallback() async throws {
        let legacyWeeklyWindow = """
        {"data": {"limits": [
          {"type": "CREDIT_LIMIT", "unit": 6, "usage": 10000,
           "currentValue": 27, "percentage": 1}
        ]}}
        """
        let result = try await makeProvider(quotaJSON: legacyWeeklyWindow).fetch()
        let details = try XCTUnwrap(result.details)

        XCTAssertNil(details.tokenUsagePercent)
        XCTAssertEqual(details.weeklyUsagePercent, 1)
        XCTAssertEqual(details.weeklyUsageUsed, 27)
        XCTAssertEqual(details.weeklyUsageTotal, 10000)
    }

    // MARK: - Standard schema (unchanged behavior)

    /// Old TOKENS_LIMIT / TIME_LIMIT schema must keep working exactly as before
    /// and must NOT pick up any CREDIT_LIMIT fallback when token windows exist.
    func testStandardSchemaUnchanged() async throws {
        let standardJSON = """
        {"data": {"limits": [
          {"type": "TOKENS_LIMIT", "total": 5000, "currentValue": 100, "percentage": 2,
           "nextResetTime": 1786717056698},
          {"type": "TIME_LIMIT", "total": 300, "currentValue": 12, "percentage": 4,
           "nextResetTime": 1787400000000}
        ]}}
        """
        let result = try await makeProvider(quotaJSON: standardJSON).fetch()
        let details = try XCTUnwrap(result.details)
        XCTAssertEqual(details.tokenUsagePercent, 2)
        XCTAssertEqual(details.tokenUsageUsed, 100)
        XCTAssertEqual(details.tokenUsageTotal, 5000)
        XCTAssertEqual(details.mcpUsagePercent, 4)
        XCTAssertEqual(details.mcpUsageUsed, 12)
        XCTAssertEqual(details.mcpUsageTotal, 300)
        // Weekly fields are only for the CREDIT_LIMIT-only path.
        XCTAssertNil(details.weeklyUsagePercent)
        XCTAssertNil(details.weeklyUsageTotal)
    }

    /// Mixed response: TOKENS_LIMIT present must win over CREDIT_LIMIT items,
    /// and the credit weekly window must not be populated.
    func testMixedSchemaPrefersTokenWindows() async throws {
        let mixedJSON = """
        {"data": {"limits": [
          {"type": "CREDIT_LIMIT", "unit": 3, "usage": 2000, "currentValue": 27, "percentage": 1},
          {"type": "CREDIT_LIMIT", "unit": 6, "usage": 10000, "currentValue": 27, "percentage": 1},
          {"type": "TOKENS_LIMIT", "total": 5000, "currentValue": 100, "percentage": 2}
        ]}}
        """
        let result = try await makeProvider(quotaJSON: mixedJSON).fetch()
        let details = try XCTUnwrap(result.details)
        XCTAssertEqual(details.tokenUsageTotal, 5000)
        XCTAssertEqual(details.tokenUsagePercent, 2)
        XCTAssertNil(details.weeklyUsagePercent)
        XCTAssertNil(details.weeklyUsageTotal)
    }

    // MARK: - Decoding

    func testCreditLimitItemsDecode() throws {
        struct Envelope: Decodable {
            let data: ZaiQuotaLimitResponse
        }
        let envelope = try JSONDecoder().decode(
            Envelope.self,
            from: creditOnlyJSON.data(using: .utf8)!
        )
        let limits = try XCTUnwrap(envelope.data.limits)
        XCTAssertEqual(limits.count, 2)

        let session = limits[0]
        XCTAssertEqual(session.type, "CREDIT_LIMIT")
        XCTAssertEqual(session.unit, 3)
        XCTAssertEqual(session.number, 5)
        XCTAssertEqual(session.usage, 2000)
        XCTAssertEqual(session.currentValue, 27)
        XCTAssertEqual(session.remaining, 1972)
        XCTAssertEqual(session.percentage, 1)
        XCTAssertNotNil(session.nextResetTime)
        XCTAssertNil(session.total)

        let weekly = limits[1]
        XCTAssertEqual(weekly.unit, 6)
        XCTAssertEqual(weekly.number, 1)
        XCTAssertEqual(weekly.usage, 10000)
        XCTAssertEqual(weekly.remaining, 9972)
    }

    func testCreditLimitResolvedTotalFallsBackToUsage() throws {
        struct Envelope: Decodable {
            let data: ZaiQuotaLimitResponse
        }
        let envelope = try JSONDecoder().decode(
            Envelope.self,
            from: creditOnlyJSON.data(using: .utf8)!
        )
        let limits = try XCTUnwrap(envelope.data.limits)
        // CREDIT_LIMIT has no `total`; resolvedTotal must fall back to `usage`.
        XCTAssertNil(limits[0].total)
        XCTAssertEqual(limits[0].resolvedTotal, 2000)
    }

    func testCreditLimitComputedPercentageFallsBackToCurrentValueOverUsage() throws {
        // Strip `percentage` to exercise the derivation fallback: 27/2000*100 = 1.35
        let stripped = creditOnlyJSON.replacingOccurrences(of: "\"percentage\": 1,", with: "")
        struct Envelope: Decodable {
            let data: ZaiQuotaLimitResponse
        }
        let envelope = try JSONDecoder().decode(
            Envelope.self,
            from: stripped.data(using: .utf8)!
        )
        let limits = try XCTUnwrap(envelope.data.limits)
        let computed = try XCTUnwrap(limits[0].computedPercentage)
        XCTAssertEqual(computed, 1.35, accuracy: 0.001)
    }

    // MARK: - Weekly propagation (status bar / change detection / hasAnyValue)

    @MainActor
    func testMenuConstructionDoesNotStartProviderRefresh() {
        XCTAssertNotNil(NSClassFromString("XCTestCase"))
        let controller = StatusBarController(startBackgroundServices: false)
        let properties = Mirror(reflecting: controller).children
        for name in ["refreshTimer", "initialRefreshTask"] {
            guard let property = properties.first(where: { $0.label == name }) else {
                return XCTFail("Missing controller property: \(name)")
            }
            XCTAssertTrue(Mirror(reflecting: property.value).children.isEmpty, "\(name) started during menu construction")
        }
    }

    /// Weekly usage must appear in the status-bar candidate list with the
    /// 7-day window priority so a Lite account shows the right top-bar window.
    @MainActor
    func testUsagePercentCandidatesIncludeWeeklyWithWeeklyPriority() {
        let details = DetailedUsage(
            tokenUsagePercent: 12,
            mcpUsagePercent: 5,
            weeklyUsagePercent: 2
        )
        let usage = ProviderUsage.quotaBased(remaining: 88, entitlement: 100, overagePermitted: false)

        let candidates = StatusBarController.usagePercentCandidates(
            identifier: .zaiCodingPlan,
            usage: usage,
            details: details
        )

        let weekly = candidates.first { $0.percent == 2 }
        XCTAssertNotNil(weekly, "weeklyUsagePercent must be a candidate, got: \(candidates)")
        XCTAssertEqual(weekly?.priority, .weekly)
        // Weekly must also win over hourly/monthly when selected.
        let best = candidates.min { $0.priority.rawValue < $1.priority.rawValue }
        XCTAssertEqual(best?.percent, 2)
    }

    /// Weekly usage must participate in recent-quota-change detection.
    @MainActor
    func testUsedPercentsForChangeDetectionIncludesWeekly() {
        let details = DetailedUsage(
            tokenUsagePercent: 12,
            weeklyUsagePercent: 2
        )
        let usage = ProviderUsage.quotaBased(remaining: 88, entitlement: 100, overagePermitted: false)
        let result = ProviderResult(usage: usage, details: details)

        let percents = StatusBarController.usedPercentsForChangeDetection(identifier: .zaiCodingPlan, result: result)
        XCTAssertTrue(percents.contains(2), "weeklyUsagePercent missing from change detection: \(percents)")
    }

    /// The real demo/menu build path must render every active Z.AI window on
    /// the top-level provider row, including a weekly-only account.
    @MainActor
    func testZaiTopLevelRowsRenderAllActiveWindows() {
        let controller = StatusBarController(startBackgroundServices: false)
        controller.loadDemoData()

        guard let menu = menu(from: controller) else {
            return XCTFail("StatusBarController did not build its main menu")
        }
        let rows = menu.items
            .compactMap { $0.attributedTitle?.string }
            .filter { $0.hasPrefix(ProviderIdentifier.zaiCodingPlan.displayName) }

        XCTAssertEqual(rows.count, 2, "Expected two real Z.AI rows, got: \(rows)")
        XCTAssertTrue(rows.contains { $0.contains("12%, 1%, 2%") }, "Missing token/weekly/MCP row: \(rows)")

        let weeklyOnlyRows = rows.filter { $0.contains("1%") && !$0.contains("12%") }
        XCTAssertEqual(weeklyOnlyRows.count, 1, "Expected one weekly-only row: \(rows)")
        if let weeklyOnlyRow = weeklyOnlyRows.first {
            XCTAssertFalse(weeklyOnlyRow.contains("2%"), "Weekly-only row fabricated MCP usage: \(weeklyOnlyRows)")
        }
    }

    /// A Z.AI weekly detail window with a reset timestamp must render the
    /// existing reset row through the shared usage-window helper.
    @MainActor
    func testZaiWeeklyDetailWindowRendersResetRow() {
        let details = DetailedUsage(
            weeklyUsagePercent: 27,
            weeklyUsageReset: Date(timeIntervalSince1970: 1_787_301_777)
        )
        let submenu = StatusBarController(startBackgroundServices: false).createDetailSubmenu(
            details,
            identifier: .zaiCodingPlan
        )
        let renderedTexts = submenu.items.flatMap { item in
            item.view?.subviews.compactMap { ($0 as? NSTextField)?.stringValue } ?? []
        }

        XCTAssertTrue(
            renderedTexts.contains { $0.hasPrefix("Resets:") },
            "Weekly detail should render a reset row, got: \(renderedTexts)"
        )
    }

    /// A details payload carrying only weekly fields must count as non-empty so
    /// the detail submenu is not hidden.
    func testHasAnyValueIncludesWeeklyFields() {
        XCTAssertTrue(DetailedUsage(weeklyUsagePercent: 1).hasAnyValue)
        XCTAssertTrue(DetailedUsage(weeklyUsageReset: Date()).hasAnyValue)
        XCTAssertTrue(DetailedUsage(weeklyUsageUsed: 27).hasAnyValue)
        XCTAssertTrue(DetailedUsage(weeklyUsageTotal: 10000).hasAnyValue)
        XCTAssertFalse(DetailedUsage().hasAnyValue)
    }

    func testTransientNetworkErrorClassification() {
        let wrappedTimeout = NSError(
            domain: "ZaiCodingPlanProviderTests",
            code: 1,
            userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            ]
        )
        let cases: [(Error, Bool)] = [
            (ProviderError.networkError("HTTP 500"), true),
            (ProviderError.networkError("TLS handshake failed"), true),
            (ProviderError.networkError("HTTP 400"), false),
            (ProviderError.authenticationFailed("Invalid API key"), false),
            (NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), true),
            (NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost), true),
            (NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), true),
            (NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost), true),
            (wrappedTimeout, true),
            (NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL), false)
        ]

        for (error, expected) in cases {
            XCTAssertEqual(
                ZaiCodingPlanProvider.isTransientNetworkError(error),
                expected,
                "error: \(error.localizedDescription)"
            )
        }
    }

    func testRetryDelayUsesBoundedJitter() {
        XCTAssertEqual(
            ZaiCodingPlanProvider.retryDelayNanoseconds(for: 1, jitter: 0),
            500_000_000
        )
        XCTAssertEqual(
            ZaiCodingPlanProvider.retryDelayNanoseconds(for: 2, jitter: 250_000_000),
            1_250_000_000
        )
    }
}
