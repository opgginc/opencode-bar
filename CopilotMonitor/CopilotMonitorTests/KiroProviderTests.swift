import XCTest
@testable import OpenCode_Bar

final class KiroProviderTests: XCTestCase {
    func testProviderIdentifier() {
        let provider = KiroProvider()
        XCTAssertEqual(provider.identifier, .kiro)
    }

    func testProviderType() {
        let provider = KiroProvider()
        XCTAssertEqual(provider.type, .quotaBased)
    }

    func testUsageParserReadsClassicOutput() throws {
        let output = #"""
        Model: auto | Plan: KIRO PRO (/usage for more detail)

        Estimated Usage | resets on 2026-06-01 | KIRO PRO

        Credits (3.66 of 1000 covered in plan)
        0%
        Overages: Disabled
        """#

        let usage = try KiroProvider.parseUsageOutput(output)

        XCTAssertEqual(usage.usedCredits, 3.66, accuracy: 0.001)
        XCTAssertEqual(usage.totalCredits, 1000, accuracy: 0.001)
        XCTAssertEqual(usage.remainingCredits, 996.34, accuracy: 0.001)
        XCTAssertEqual(usage.usagePercent, 0.366, accuracy: 0.001)
        XCTAssertEqual(usage.planName, "KIRO PRO")
        XCTAssertEqual(usage.overageStatus, "Disabled")
        XCTAssertNotNil(usage.resetDate)
    }

    func testUsageParserStripsANSIAndParsesCommaNumbers() throws {
        let output = "\u{001B}[32mEstimated Usage | resets on 2026-06-01 | KIRO POWER\u{001B}[0m\nCredits (1,234.5 of 10,000 covered in plan)\nOverages: Enabled"

        let usage = try KiroProvider.parseUsageOutput(output)

        XCTAssertEqual(usage.usedCredits, 1234.5, accuracy: 0.001)
        XCTAssertEqual(usage.totalCredits, 10_000, accuracy: 0.001)
        XCTAssertEqual(usage.planName, "KIRO POWER")
        XCTAssertEqual(usage.overageStatus, "Enabled")
    }

    func testUsageParserTrimsPlanHintText() throws {
        let output = "Model: auto | Plan: KIRO PRO (/usage for more detail)\nCredits (3.66 of 1000 covered in plan)"

        let usage = try KiroProvider.parseUsageOutput(output)

        XCTAssertEqual(usage.planName, "KIRO PRO")
    }

    func testUsageParserThrowsWhenCreditsAreMissing() {
        XCTAssertThrowsError(try KiroProvider.parseUsageOutput("Estimated Usage | KIRO PRO"))
    }

    func testMakeResultKeepsCenticreditPrecision() throws {
        let resetDate = try KiroProvider.parseUsageOutput("Credits (3.66 of 1000 covered in plan)\nresets on 2026-06-01")
            .resetDate
        let snapshot = KiroUsageSnapshot(
            usedCredits: 3.66,
            totalCredits: 1000,
            planName: "KIRO PRO",
            resetDate: resetDate,
            overageStatus: "Disabled"
        )

        let result = KiroProvider.makeResult(
            from: snapshot,
            binaryPath: URL(fileURLWithPath: "/Users/test/.local/bin/kiro-cli")
        )

        XCTAssertEqual(result.usage.totalEntitlement, 100_000)
        XCTAssertEqual(result.usage.remainingQuota, 99_634)
        XCTAssertEqual(result.usage.usagePercentage, 0.366, accuracy: 0.001)
        if case .quotaBased(_, _, let overagePermitted) = result.usage {
            XCTAssertFalse(overagePermitted)
        } else {
            XCTFail("Expected quota-based usage")
        }
        XCTAssertEqual(result.details?.planType, "KIRO PRO")
        XCTAssertEqual(try XCTUnwrap(result.details?.creditsRemaining), 996.34, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.details?.creditsTotal), 1000, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.details?.monthlyCost), 3.66, accuracy: 0.001)
        XCTAssertEqual(result.details?.authSource, "kiro-cli at /Users/test/.local/bin/kiro-cli")
    }
}
