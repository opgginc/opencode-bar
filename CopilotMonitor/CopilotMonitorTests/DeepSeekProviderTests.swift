import XCTest
import AppKit
import SQLite3
@testable import OpenCode_Bar

final class DeepSeekProviderTests: XCTestCase {
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

    /// Bypass credential lookup unless a test supplies its own credential store fixture.
    private func makeProvider(statusCode: Int = 200, body: String, apiKey: String? = "sk-test-fake") -> DeepSeekProvider {
        let session = makeSession()
        let provider = DeepSeekProvider(tokenManager: .shared, session: session, apiKey: apiKey)

        MockURLProtocol.requestHandler = { request in
            // Assert the request shape so endpoint/method/auth regressions fail.
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.absoluteString, "https://api.deepseek.com/user/balance")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-fake")

            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(body.utf8))
        }
        return provider
    }

    // MARK: - Identity

    func testProviderIdentifier() {
        let provider = DeepSeekProvider()
        XCTAssertEqual(provider.identifier, .deepSeek)
    }

    func testProviderType() {
        let provider = DeepSeekProvider()
        XCTAssertEqual(provider.type, .payAsYouGo)
    }

    // MARK: - Response decoding

    /// Real /user/balance response shape (string amounts, CNY).
    private let balanceJSON = """
    {
      "is_available": true,
      "balance_infos": [
        {
          "currency": "CNY",
          "total_balance": "103.49",
          "granted_balance": "0.00",
          "topped_up_balance": "103.49"
        }
      ]
    }
    """

    func testBalanceResponseDecodesStringAmounts() throws {
        let response = try JSONDecoder().decode(
            DeepSeekProvider.BalanceResponse.self,
            from: balanceJSON.data(using: .utf8)!
        )
        let info = try XCTUnwrap(response.balanceInfos?.first)
        XCTAssertEqual(info.currency, "CNY")
        XCTAssertEqual(info.totalBalance, "103.49")
        XCTAssertEqual(info.grantedBalance, "0.00")
        XCTAssertEqual(info.toppedUpBalance, "103.49")
        XCTAssertEqual(response.isAvailable, true)
    }

    // MARK: - Fetch

    func testFetchPreservesSQLiteCredentialSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databasePath = directory.appendingPathComponent("credentials.sqlite")
        let previousDatabase = ProcessInfo.processInfo.environment["OPENCODE_DB"]
        defer {
            if let previousDatabase {
                setenv("OPENCODE_DB", previousDatabase, 1)
            } else {
                unsetenv("OPENCODE_DB")
            }
            TokenManager.shared.clearOpenCodeAuthCacheForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        var database: OpaquePointer?
        let openResult = sqlite3_open(databasePath.path, &database)
        defer { sqlite3_close(database) }
        XCTAssertEqual(openResult, SQLITE_OK)
        let sql = """
        CREATE TABLE credential (integration_id TEXT, value TEXT, active INTEGER, time_updated INTEGER);
        INSERT INTO credential VALUES ('deepseek', '{"type":"key","key":"sk-test-fake"}', 1, 10);
        """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        setenv("OPENCODE_DB", databasePath.path, 1)
        TokenManager.shared.clearOpenCodeAuthCacheForTesting()

        let result = try await makeProvider(body: balanceJSON, apiKey: nil).fetch()
        XCTAssertEqual(result.details?.authSource, databasePath.path)
    }

    func testFetchSuccessSurfacesBalanceInDetails() async throws {
        let result = try await makeProvider(body: balanceJSON).fetch()

        guard case .payAsYouGo(let utilization, let cost, _) = result.usage else {
            return XCTFail("Expected payAsYouGo usage")
        }
        XCTAssertEqual(utilization, 0)
        // Balance is not spend: cost must stay nil so the aggregate total is unaffected.
        XCTAssertNil(cost)

        let details = try XCTUnwrap(result.details)
        XCTAssertEqual(details.creditsBalance, 103.49)
        XCTAssertEqual(details.balanceCurrency, "CNY")
        XCTAssertEqual(details.balanceCurrencySymbol, "¥")
        XCTAssertEqual(details.balanceGranted, 0.0)
        XCTAssertEqual(details.balanceToppedUp, 103.49)
        XCTAssertEqual(result.balanceInfos, [
            ProviderBalanceInfo(currency: "CNY", totalBalance: 103.49, grantedBalance: 0.0, toppedUpBalance: 103.49)
        ])
    }

    func testFetchUnavailableBalanceStillReturnsData() async throws {
        // is_available=false is a diagnostic signal; balance_infos may still be
        // present (zeroed/frozen) and should still be rendered.
        let unavailableJSON = """
        {
          "is_available": false,
          "balance_infos": [
            {"currency": "CNY", "total_balance": "0.00", "granted_balance": "0.00", "topped_up_balance": "0.00"}
          ]
        }
        """
        let result = try await makeProvider(body: unavailableJSON).fetch()
        let details = try XCTUnwrap(result.details)
        XCTAssertEqual(details.creditsBalance, 0.0)
        XCTAssertEqual(details.balanceCurrency, "CNY")
    }

    func testFetchUnparseableTotalBalanceThrowsDecodingError() async throws {
        let badJSON = """
        {
          "is_available": true,
          "balance_infos": [
            {"currency": "CNY", "total_balance": "not-a-number", "granted_balance": "0.00", "topped_up_balance": "0.00"}
          ]
        }
        """
        do {
            _ = try await makeProvider(body: badJSON).fetch()
            XCTFail("Expected decodingError for unparseable total_balance")
        } catch let error as ProviderError {
            guard case .decodingError = error else {
                return XCTFail("Expected decodingError, got \(error)")
            }
        }
    }

    func testFetchPropagatesHTTPError() async throws {
        do {
            _ = try await makeProvider(statusCode: 401, body: "").fetch()
            XCTFail("Expected network error for 401")
        } catch let error as ProviderError {
            guard case .networkError = error else {
                return XCTFail("Expected networkError, got \(error)")
            }
        }
    }

    // MARK: - Multi-currency policy

    /// Both currencies must be preserved, including a zero CNY balance next to funded USD.
    func testMultiCurrencyPreservesUSDWhenCNYBalanceIsZero() async throws {
        let cnyFirst = """
        {"is_available": true, "balance_infos": [
          {"currency": "CNY", "total_balance": "0.00", "granted_balance": "0.00", "topped_up_balance": "0.00"},
          {"currency": "USD", "total_balance": "26.00", "granted_balance": "0.00", "topped_up_balance": "26.00"}
        ]}
        """
        let usdFirst = """
        {"is_available": true, "balance_infos": [
          {"currency": "USD", "total_balance": "26.00", "granted_balance": "0.00", "topped_up_balance": "26.00"},
          {"currency": "CNY", "total_balance": "0.00", "granted_balance": "0.00", "topped_up_balance": "0.00"}
        ]}
        """
        for body in [cnyFirst, usdFirst] {
            let result = try await makeProvider(body: body).fetch()
            let details = try XCTUnwrap(result.details)
            XCTAssertEqual(details.balanceCurrency, "USD", "Use a funded currency for legacy single-balance fields")
            XCTAssertEqual(details.creditsBalance, 26.0)
            XCTAssertEqual(details.balanceCurrencySymbol, "$")
            XCTAssertEqual(result.balanceInfos?.map(\.currency), ["CNY", "USD"])
            XCTAssertEqual(result.balanceInfos?.map(\.totalBalance), [0.0, 26.0])
        }
    }

    /// USD-only accounts must render with the dollar symbol.
    func testUSDBalanceSurfacesWithDollarSymbol() async throws {
        let usdOnly = """
        {"is_available": true, "balance_infos": [
          {"currency": "USD", "total_balance": "12.00", "granted_balance": "2.00", "topped_up_balance": "10.00"}
        ]}
        """
        let result = try await makeProvider(body: usdOnly).fetch()
        let details = try XCTUnwrap(result.details)
        XCTAssertEqual(details.balanceCurrency, "USD")
        XCTAssertEqual(details.creditsBalance, 12.0)
        XCTAssertEqual(details.balanceCurrencySymbol, "$")
    }

    /// Unsupported-only balances must fail loudly instead of picking an arbitrary entry.
    func testUnsupportedCurrencyThrowsDecodingError() async throws {
        let eurOnly = """
        {"is_available": true, "balance_infos": [
          {"currency": "EUR", "total_balance": "12.00", "granted_balance": "0.00", "topped_up_balance": "12.00"}
        ]}
        """
        do {
            _ = try await makeProvider(body: eurOnly).fetch()
            XCTFail("Expected decodingError for unsupported currency")
        } catch let error as ProviderError {
            guard case .decodingError = error else {
                return XCTFail("Expected decodingError, got \(error)")
            }
        }
    }

    /// One broken ledger must not hide a valid one: a malformed total_balance
    /// is skipped (logged) while the usable currency still renders.
    func testMalformedLedgerIsSkippedWhenAnotherIsUsable() async throws {
        let mixed = """
        {"is_available": true, "balance_infos": [
          {"currency": "USD", "total_balance": "not-a-number", "granted_balance": "0.00", "topped_up_balance": "26.00"},
          {"currency": "CNY", "total_balance": "10.00", "granted_balance": "0.00", "topped_up_balance": "10.00"}
        ]}
        """
        let result = try await makeProvider(body: mixed).fetch()
        XCTAssertEqual(result.balanceInfos?.map(\.currency), ["CNY"])
        XCTAssertEqual(result.balanceInfos?.first?.totalBalance, 10.0)
        XCTAssertEqual(result.details?.creditsBalance, 10.0)
    }

    func testUnexpectedLedgerJSONTypesDoNotHideUsableBalance() async throws {
        let body = """
        {"balance_infos": [
          null,
          {"currency": "CNY", "total_balance": false},
          {"currency": "USD", "total_balance": "26.00", "granted_balance": {}, "topped_up_balance": "26.00"}
        ]}
        """
        let result = try await makeProvider(body: body).fetch()
        XCTAssertEqual(result.balanceInfos, [
            ProviderBalanceInfo(currency: "USD", totalBalance: 26, grantedBalance: nil, toppedUpBalance: 26)
        ])
    }

    @MainActor
    func testNonFiniteSecondaryBalancesRemainUnavailable() async throws {
        let body = """
        {"is_available": true, "balance_infos": [
          {"currency": "USD", "total_balance": "26.00", "granted_balance": "NaN", "topped_up_balance": "Infinity"}
        ]}
        """
        let result = try await makeProvider(body: body).fetch()
        let balance = try XCTUnwrap(result.balanceInfos?.first)
        XCTAssertEqual(balance.totalBalance, 26.0)
        XCTAssertNil(balance.grantedBalance)
        XCTAssertNil(balance.toppedUpBalance)
        XCTAssertEqual(StatusBarController.deepSeekBalanceRowTexts(balanceInfos: [balance]), [
            "Balance (USD): $26.00", "Topped-up (USD): Unavailable", "Granted (USD): Unavailable"
        ])
        let json = try JSONFormatter.format([.deepSeek: result])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: Any]])
        let provider = try XCTUnwrap(payload["deepseek"])
        let ledgers = try XCTUnwrap(provider["balances"] as? [[String: Any]])
        let ledger = try XCTUnwrap(ledgers.first)
        XCTAssertEqual(ledger["balance"] as? Double, 26)
        for field in ["grantedBalance", "toppedUpBalance"] {
            XCTAssertNil(provider[field])
            XCTAssertNil(ledger[field])
        }
    }

    /// An unsupported code next to a usable ledger is skipped quietly while
    /// the supported currency still renders.
    func testUnsupportedLedgerNextToSupportedStillRendersSupported() async throws {
        let mixed = """
        {"is_available": true, "balance_infos": [
          {"currency": "EUR", "total_balance": "12.00", "granted_balance": "0.00", "topped_up_balance": "12.00"},
          {"currency": "CNY", "total_balance": "10.00", "granted_balance": "0.00", "topped_up_balance": "10.00"}
        ]}
        """
        let result = try await makeProvider(body: mixed).fetch()
        XCTAssertEqual(result.balanceInfos?.map(\.currency), ["CNY"])
        XCTAssertEqual(result.balanceInfos?.first?.totalBalance, 10.0)
        XCTAssertEqual(result.details?.creditsBalance, 10.0)
    }

    /// When every supported ledger is malformed the fetch still fails,
    /// instead of silently reporting an empty account.
    func testAllSupportedLedgersMalformedThrowsDecodingError() async throws {
        let broken = """
        {"is_available": true, "balance_infos": [
          {"currency": "CNY", "total_balance": "?", "granted_balance": "0.00", "topped_up_balance": "0.00"},
          {"currency": "USD", "total_balance": "", "granted_balance": "0.00", "topped_up_balance": "0.00"}
        ]}
        """
        do {
            _ = try await makeProvider(body: broken).fetch()
            XCTFail("Expected decodingError when no ledger is usable")
        } catch let error as ProviderError {
            guard case .decodingError = error else {
                return XCTFail("Expected decodingError, got \(error)")
            }
        }
    }

    // MARK: - Detail menu rows

    @MainActor
    func testRateLimitedMenuKeepsBothCachedCurrenciesAccessible() throws {
        let controller = StatusBarController(startBackgroundServices: false)
        let result = ProviderResult(
            usage: .payAsYouGo(utilization: 0, cost: nil, resetsAt: nil),
            details: DetailedUsage(creditsBalance: 26, authSource: "OpenCode"),
            balanceInfos: [
                ProviderBalanceInfo(currency: "CNY", totalBalance: 0, grantedBalance: 0, toppedUpBalance: 0),
                ProviderBalanceInfo(currency: "USD", totalBalance: 26, grantedBalance: 0, toppedUpBalance: 26)
            ]
        )
        let item = controller.createErrorMenuItem(identifier: .deepSeek, errorMessage: "HTTP 429", result: result)
        let menu = NSMenu()
        menu.addItem(item)
        menu.update()
        XCTAssertTrue(item.isEnabled)
        let errorMenu = try XCTUnwrap(item.submenu)
        errorMenu.update()
        let cachedItem = try XCTUnwrap(errorMenu.item(withTitle: "Cached Details"))
        XCTAssertTrue(cachedItem.isEnabled)
        let rows = try XCTUnwrap(cachedItem.submenu).items.flatMap { item in
            item.view?.subviews.compactMap { ($0 as? NSTextField)?.stringValue } ?? []
        }
        XCTAssertTrue(rows.contains("Balance (CNY): ¥0.00"))
        XCTAssertTrue(rows.contains("Balance (USD): $26.00"))
        XCTAssertTrue(rows.contains("Token From: OpenCode"))

        let uncachedItem = controller.createErrorMenuItem(identifier: .deepSeek, errorMessage: "HTTP 429")
        XCTAssertFalse(uncachedItem.isEnabled)
        XCTAssertNil(uncachedItem.submenu)
    }

    @MainActor
    func testDetailMenuShowsWhenBalanceDataIsUnavailable() {
        let controller = StatusBarController(startBackgroundServices: false)
        let submenu = controller.createDetailSubmenu(DetailedUsage(), identifier: .deepSeek, balanceInfos: nil)
        let rows = submenu.items.flatMap { item in
            item.view?.subviews.compactMap { ($0 as? NSTextField)?.stringValue } ?? []
        }
        XCTAssertEqual(rows, ["Balance: Unavailable"])
    }

    @MainActor
    func testDeepSeekBalanceRowTextsKeepBothCurrenciesSeparate() {
        // The provider stores balances in display order (CNY before USD);
        // the rows keep both currencies separate, follow that order, and pin
        // the exact rendered string the submenu shows.
        let balances = [
            ProviderBalanceInfo(currency: "CNY", totalBalance: 0.0, grantedBalance: 0.0, toppedUpBalance: 0.0),
            ProviderBalanceInfo(currency: "USD", totalBalance: 26.0, grantedBalance: 0.0, toppedUpBalance: 26.0)
        ]

        let rows = StatusBarController.deepSeekBalanceRowTexts(balanceInfos: balances)

        XCTAssertEqual(rows, [
            "Balance (CNY): ¥0.00",
            "Topped-up (CNY): ¥0.00",
            "Granted (CNY): ¥0.00",
            "Balance (USD): $26.00",
            "Topped-up (USD): $26.00",
            "Granted (USD): $0.00"
        ])
    }

    /// The pinned status bar and the dropdown row share one balance string:
    /// funded currencies only, or all when nothing is funded.
    @MainActor
    func testStatusBalanceTextShowsFundedCurrenciesOrAllWhenZero() {
        func result(cny: Double, usd: Double, cost: Double? = nil) -> ProviderResult {
            ProviderResult(
                usage: .payAsYouGo(utilization: 0, cost: cost, resetsAt: nil),
                details: nil,
                balanceInfos: [
                    ProviderBalanceInfo(currency: "CNY", totalBalance: cny, grantedBalance: 0, toppedUpBalance: cny),
                    ProviderBalanceInfo(currency: "USD", totalBalance: usd, grantedBalance: 0, toppedUpBalance: usd)
                ]
            )
        }
        XCTAssertEqual(StatusBarController.balanceStatusText(for: result(cny: 0, usd: 26)), "$26.00")
        XCTAssertEqual(StatusBarController.balanceStatusText(for: result(cny: 103.49, usd: 26)), "¥103.49, $26.00")
        XCTAssertEqual(StatusBarController.balanceStatusText(for: result(cny: 0, usd: 0)), "¥0.00, $0.00")
        XCTAssertNil(StatusBarController.balanceStatusText(for: result(cny: 0, usd: 26, cost: 5)))
    }

}
