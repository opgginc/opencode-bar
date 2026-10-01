import XCTest
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

    /// Provider with an injected fake API key so tests run without the
    /// credential store (and therefore execute in CI).
    private func makeProvider(statusCode: Int = 200, body: String) -> DeepSeekProvider {
        let session = makeSession()
        let provider = DeepSeekProvider(tokenManager: .shared, session: session, apiKey: "sk-test-fake")

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

    /// Non-finite secondary amounts must not reach menu or JSON formatting.
    func testNonFiniteSecondaryBalancesFallBackToZero() async throws {
        let body = """
        {"is_available": true, "balance_infos": [
          {"currency": "USD", "total_balance": "26.00", "granted_balance": "NaN", "topped_up_balance": "Infinity"}
        ]}
        """
        let result = try await makeProvider(body: body).fetch()
        let balance = try XCTUnwrap(result.balanceInfos?.first)
        XCTAssertEqual(balance.totalBalance, 26.0)
        XCTAssertEqual(balance.grantedBalance, 0.0)
        XCTAssertEqual(balance.toppedUpBalance, 0.0)
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

    /// The main row must drop a zero CNY ledger and keep only the funded USD,
    /// but fall back to showing all when every currency is zero.
    @MainActor
    func testDeepSeekMainRowShowsOnlyFundedCurrencies() {
        let funded = [
            ProviderBalanceInfo(currency: "CNY", totalBalance: 0.0, grantedBalance: 0.0, toppedUpBalance: 0.0),
            ProviderBalanceInfo(currency: "USD", totalBalance: 26.0, grantedBalance: 0.0, toppedUpBalance: 26.0)
        ]
        XCTAssertEqual(StatusBarController.deepSeekMainRowBalances(funded).map(\.currency), ["USD"])

        let allZero = [
            ProviderBalanceInfo(currency: "CNY", totalBalance: 0.0, grantedBalance: 0.0, toppedUpBalance: 0.0),
            ProviderBalanceInfo(currency: "USD", totalBalance: 0.0, grantedBalance: 0.0, toppedUpBalance: 0.0)
        ]
        XCTAssertEqual(StatusBarController.deepSeekMainRowBalances(allZero).map(\.currency), ["CNY", "USD"])
    }

    /// The pinned status bar and the dropdown row share one balance string:
    /// funded currencies only, or all when nothing is funded.
    @MainActor
    func testFundedBalanceTextMatchesRowTitleRule() {
        let funded = [
            ProviderBalanceInfo(currency: "CNY", totalBalance: 0.0, grantedBalance: 0.0, toppedUpBalance: 0.0),
            ProviderBalanceInfo(currency: "USD", totalBalance: 26.0, grantedBalance: 0.0, toppedUpBalance: 26.0)
        ]
        XCTAssertEqual(StatusBarController.fundedBalanceText(funded), "$26.00")

        let bothFunded = [
            ProviderBalanceInfo(currency: "CNY", totalBalance: 103.49, grantedBalance: 0.0, toppedUpBalance: 103.49),
            ProviderBalanceInfo(currency: "USD", totalBalance: 26.0, grantedBalance: 0.0, toppedUpBalance: 26.0)
        ]
        XCTAssertEqual(StatusBarController.fundedBalanceText(bothFunded), "¥103.49, $26.00")

        let balanceResult = ProviderResult(
            usage: .payAsYouGo(utilization: 0, cost: nil, resetsAt: nil),
            details: nil,
            balanceInfos: funded
        )
        XCTAssertEqual(StatusBarController.balanceStatusText(for: balanceResult), "$26.00")

        let costResult = ProviderResult(
            usage: .payAsYouGo(utilization: 0, cost: 5.0, resetsAt: nil),
            details: nil,
            balanceInfos: funded
        )
        XCTAssertNil(StatusBarController.balanceStatusText(for: costResult))
    }

}
