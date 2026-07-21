import XCTest
@testable import OpenCode_Bar

final class ZaiCodingPlanProviderTests: XCTestCase {

    func testProviderIdentifier() {
        let provider = ZaiCodingPlanProvider()
        XCTAssertEqual(provider.identifier, .zaiCodingPlan)
    }

    func testProviderType() {
        let provider = ZaiCodingPlanProvider()
        XCTAssertEqual(provider.type, .quotaBased)
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
