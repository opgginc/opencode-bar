import XCTest
@testable import OpenCode_Bar

final class ProviderResultTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "ProviderResultTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeFormatter(currency: Currency, rate: Double = 7.0) -> CurrencyFormatter {
        let defaults = makeDefaults()
        let rateDefaults = makeDefaults()
        rateDefaults.set(rate, forKey: ExchangeRateStore.cacheKey)
        let formatter = CurrencyFormatter(defaults: defaults, rateStore: ExchangeRateStore(defaults: rateDefaults))
        formatter.currency = currency
        return formatter
    }

    // MARK: - TableFormatter currency awareness

    func testSingleProviderPayAsYouGoUsesRMBSymbol() {
        let formatter = makeFormatter(currency: .rmb)

        let usage = ProviderUsage.payAsYouGo(utilization: 0, cost: 10.0, resetsAt: nil)
        let result = ProviderResult(usage: usage, details: nil)
        let output = TableFormatter.format([.claude: result], formatter: formatter)

        XCTAssertTrue(output.contains("¥70.00 spent"),
                      "Expected RMB formatted cost in single-provider row, got:\n\(output)")
        XCTAssertFalse(output.contains("$"),
                       "Output should not contain hardcoded USD symbol in RMB mode, got:\n\(output)")
    }

    func testMultiAccountPayAsYouGoUsesRMBSymbol() {
        let formatter = makeFormatter(currency: .rmb)

        let account = ProviderAccountResult(
            accountIndex: 0,
            accountId: "alice",
            usage: .payAsYouGo(utilization: 0, cost: 5.0, resetsAt: nil),
            details: nil
        )
        let aggregate = ProviderUsage.payAsYouGo(utilization: 0, cost: 5.0, resetsAt: nil)
        let result = ProviderResult(usage: aggregate, details: nil, accounts: [account])

        let output = TableFormatter.format([.openRouter: result], formatter: formatter)

        XCTAssertTrue(output.contains("¥35.00 spent"),
                      "Expected RMB formatted cost in multi-account row, got:\n\(output)")
        XCTAssertFalse(output.contains("$"),
                       "Output should not contain hardcoded USD symbol in RMB mode, got:\n\(output)")
    }

    func testSingleProviderPayAsYouGoStillSupportsUSD() {
        let formatter = makeFormatter(currency: .usd)

        let usage = ProviderUsage.payAsYouGo(utilization: 0, cost: 10.0, resetsAt: nil)
        let result = ProviderResult(usage: usage, details: nil)
        let output = TableFormatter.format([.claude: result], formatter: formatter)

        XCTAssertTrue(output.contains("$10.00 spent"),
                      "Expected USD formatted cost in USD mode, got:\n\(output)")
    }

    // MARK: - B10/B11 regression: stale rate must not leak between formatter instances.

    func testRateDoesNotLeakBetweenFormatterInstances() {
        // Simulate the pollution scenario: a prior write set rate to 6.791 (matches the
        // observed flake value ¥67.91 for $10 cost). A fresh formatter built with
        // rate=7.0 must use 7.0, not the stale 6.791.
        let previousDefaults = makeDefaults()
        previousDefaults.set(6.791, forKey: ExchangeRateStore.cacheKey)
        _ = CurrencyFormatter(defaults: makeDefaults(), rateStore: ExchangeRateStore(defaults: previousDefaults))

        let formatter = makeFormatter(currency: .rmb, rate: 7.0)
        let output = formatter.format(usd: 10.0) + " spent"

        XCTAssertTrue(output.contains("¥70.00"),
                      "Fresh formatter must use its own injected rate 7.0, got: \(output)")
        XCTAssertFalse(output.contains("67.91"),
                       "Stale rate from prior instance leaked into fresh formatter: \(output)")
    }
}