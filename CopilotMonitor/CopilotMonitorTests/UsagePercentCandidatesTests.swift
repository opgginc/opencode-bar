import XCTest
@testable import OpenCode_Bar

@MainActor
final class UsagePercentCandidatesTests: XCTestCase {
    private var suiteName: String = ""
    private var suite: UserDefaults!
    private var controller: StatusBarController!

    override func setUp() {
        super.setUp()
        suiteName = "B03.test.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        controller = StatusBarController(options: .testing(userDefaults: suite))
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        controller = nil
        super.tearDown()
    }

    // MARK: - B03: .volcanoArk / .mimo / .hunyuan / .zhipuGLM share one case branch

    func testVolcanoArkWith5hAnd7dReturnsBothWindowsPlusFallback() {
        let details = DetailedUsage(
            fiveHourUsage: 25.0,
            sevenDayUsage: 42.0
        )
        let usage: ProviderUsage = .quotaBased(remaining: 50, entitlement: 100, overagePermitted: false)

        let candidates = controller.usagePercentCandidates(
            identifier: .volcanoArk,
            usage: usage,
            details: details
        )

        let fallbackCount = candidates.filter { $0.priority == .fallback }.count
        let weeklyFound = candidates.first { $0.priority == .weekly }
        let hourlyFound = candidates.first { $0.priority == .hourly }

        XCTAssertEqual(fallbackCount, 1, "Should have exactly one fallback (no duplicate)")
        XCTAssertNotNil(weeklyFound, "Should have a weekly candidate from sevenDayUsage")
        XCTAssertNotNil(hourlyFound, "Should have an hourly candidate from fiveHourUsage")
        XCTAssertEqual(weeklyFound?.percent ?? 0, 42.0, accuracy: 0.001)
        XCTAssertEqual(hourlyFound?.percent ?? 0, 25.0, accuracy: 0.001)
    }

    func testMimoWithout5hOr7dReturnsOnlyFallbackNoDuplicate() {
        let details = DetailedUsage()
        let usage: ProviderUsage = .payAsYouGo(utilization: 88.5, cost: nil, resetsAt: nil)

        let candidates = controller.usagePercentCandidates(
            identifier: .mimo,
            usage: usage,
            details: details
        )

        let fallbackCount = candidates.filter { $0.priority == .fallback }.count
        let weeklyFound = candidates.first { $0.priority == .weekly }
        let hourlyFound = candidates.first { $0.priority == .hourly }

        XCTAssertEqual(fallbackCount, 1, ".mimo must not duplicate the fallback candidate (B03 regression)")
        XCTAssertNil(weeklyFound, "Without sevenDayUsage, weekly candidate should be absent")
        XCTAssertNil(hourlyFound, "Without fiveHourUsage, hourly candidate should be absent")
        XCTAssertEqual(candidates.first?.percent ?? 0, 88.5, accuracy: 0.001)
    }

    func testHunyuanWithout5hOr7dReturnsOnlyFallbackNoDuplicate() {
        let details = DetailedUsage()
        let usage: ProviderUsage = .payAsYouGo(utilization: 50.0, cost: nil, resetsAt: nil)

        let candidates = controller.usagePercentCandidates(
            identifier: .hunyuan,
            usage: usage,
            details: details
        )

        let fallbackCount = candidates.filter { $0.priority == .fallback }.count

        XCTAssertEqual(fallbackCount, 1, ".hunyuan must not duplicate the fallback candidate (B03 regression)")
    }

    func testZhipuGLMWithout5hOr7dReturnsOnlyFallbackNoDuplicate() {
        let details = DetailedUsage()
        let usage: ProviderUsage = .payAsYouGo(utilization: 50.0, cost: nil, resetsAt: nil)

        let candidates = controller.usagePercentCandidates(
            identifier: .zhipuGLM,
            usage: usage,
            details: details
        )

        let fallbackCount = candidates.filter { $0.priority == .fallback }.count

        XCTAssertEqual(fallbackCount, 1, ".zhipuGLM must not duplicate the fallback candidate (B03 regression)")
    }

    func testVolcanoArkWithEmptyDetailsReturnsOnlyFallback() {
        let details = DetailedUsage()
        let usage: ProviderUsage = .payAsYouGo(utilization: 33.0, cost: nil, resetsAt: nil)

        let candidates = controller.usagePercentCandidates(
            identifier: .volcanoArk,
            usage: usage,
            details: details
        )

        let fallbackCount = candidates.filter { $0.priority == .fallback }.count
        let weeklyFound = candidates.first { $0.priority == .weekly }
        let hourlyFound = candidates.first { $0.priority == .hourly }

        XCTAssertEqual(fallbackCount, 1, ".volcanoArk with no 5h/7d should fall through to single fallback")
        XCTAssertNil(weeklyFound)
        XCTAssertNil(hourlyFound)
        XCTAssertEqual(candidates.first?.percent ?? 0, 33.0, accuracy: 0.001)
    }
}
