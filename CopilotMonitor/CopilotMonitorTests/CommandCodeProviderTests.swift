import XCTest
@testable import OpenCode_Bar

final class CommandCodeProviderTests: XCTestCase {
    func testProviderIdentifier() {
        let provider = CommandCodeProvider()
        XCTAssertEqual(provider.identifier, .commandCode)
    }

    func testProviderType() {
        let provider = CommandCodeProvider()
        XCTAssertEqual(provider.type, .quotaBased)
    }

    func testCookieHeaderParsesSecureCookie() {
        let header = CommandCodeCookieHeader.override(
            from: "foo=bar; __Secure-better-auth.session_token=test-token; other=value"
        )

        XCTAssertEqual(header?.name, "__Secure-better-auth.session_token")
        XCTAssertEqual(header?.token, "test-token")
        XCTAssertEqual(header?.headerValue, "__Secure-better-auth.session_token=test-token")
    }

    func testCookieHeaderParsesCommandCodeProductionCookie() {
        let header = CommandCodeCookieHeader.override(
            from: "foo=bar; __Secure-commandcode_prod_.session_token=test-token; other=value"
        )

        XCTAssertEqual(header?.name, "__Secure-commandcode_prod_.session_token")
        XCTAssertEqual(header?.token, "test-token")
        XCTAssertEqual(header?.headerValue, "__Secure-commandcode_prod_.session_token=test-token")
    }

    func testCookieHeaderParsesBareToken() {
        let header = CommandCodeCookieHeader.override(from: "test-token")

        XCTAssertEqual(header?.name, "__Secure-better-auth.session_token")
        XCTAssertEqual(header?.token, "test-token")
    }

    func testCookieHeaderRejectsUnsupportedCookieHeader() {
        let header = CommandCodeCookieHeader.override(from: "unrelated=value")

        XCTAssertNil(header)
    }

    func testDirectAPISnapshotParsesCodexBarCompatiblePayloads() throws {
        let creditsJSON = """
        {
            "credits": {
                "belowThreshold": false,
                "creditThreshold": 0,
                "monthlyCredits": 8.7784,
                "purchasedCredits": 0,
                "premiumMonthlyCredits": 0,
                "opensourceMonthlyCredits": 8.7784
            }
        }
        """.data(using: .utf8)!
        let subscriptionJSON = """
        {
            "success": true,
            "data": {
                "planId": "individual-go",
                "status": "active",
                "currentPeriodEnd": "2026-06-06T07:28:50.000Z"
            }
        }
        """.data(using: .utf8)!

        let snapshot = try CommandCodeProvider.snapshotFromDirectAPI(
            creditsData: creditsJSON,
            subscriptionData: subscriptionJSON,
            authSource: "test"
        )

        XCTAssertEqual(snapshot.plan?.displayName, "Go")
        XCTAssertEqual(snapshot.monthlyCreditsTotal, 10)
        XCTAssertEqual(snapshot.monthlyCreditsUsed ?? 0, 1.2216, accuracy: 0.0001)
        XCTAssertEqual(snapshot.usagePercent, 12.216, accuracy: 0.001)
        XCTAssertEqual(snapshot.usageSummary, "Go · $1.22 of $10.00")
        XCTAssertNotNil(snapshot.billingPeriodEnd)
    }

    func testOpenCommandUsageSnapshotParsesProxyPayload() throws {
        let data = """
        {
            "credits_remaining": 21.5,
            "monthly_spend": 8.5,
            "monthly_limit": 30,
            "remaining_days": 12,
            "reset_date": "2026-06-06"
        }
        """.data(using: .utf8)!

        let snapshot = try CommandCodeProvider.snapshotFromOpenCommandUsage(data, authSource: "OpenCommand local proxy")

        XCTAssertEqual(snapshot.monthlyCreditsRemaining, 21.5)
        XCTAssertEqual(snapshot.monthlyCreditsTotal, 30)
        XCTAssertEqual(snapshot.monthlyCreditsUsed ?? 0, 8.5, accuracy: 0.0001)
        XCTAssertEqual(snapshot.usagePercent, 28.333, accuracy: 0.001)
        XCTAssertEqual(snapshot.authSource, "OpenCommand local proxy")
        XCTAssertNotNil(snapshot.billingPeriodEnd)
    }

    func testProviderResultUsesCentPrecisionForDollarCredits() {
        let snapshot = CommandCodeUsageSnapshot(
            monthlyCreditsRemaining: 8.7784,
            purchasedCredits: 0,
            premiumMonthlyCredits: 0,
            opensourceMonthlyCredits: 8.7784,
            plan: CommandCodePlan(id: "individual-go", displayName: "Go", monthlyCreditsUSD: 10),
            billingPeriodEnd: nil,
            subscriptionStatus: "active",
            authSource: "test"
        )

        let result = CommandCodeProvider.makeResult(from: snapshot)

        XCTAssertEqual(result.usage.totalEntitlement, 1000)
        XCTAssertEqual(result.usage.remainingQuota, 878)
        XCTAssertEqual(result.usage.usagePercentage, 12.2, accuracy: 0.0001)
        XCTAssertEqual(result.details?.creditsRemaining, 8.7784)
        XCTAssertEqual(result.details?.creditsTotal, 10)
    }
}
