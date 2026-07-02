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
        XCTAssertEqual(usage.planName, "Pro")
        XCTAssertEqual(usage.overageStatus, "Disabled")
        XCTAssertNotNil(usage.resetDate)
    }

    func testUsageParserStripsANSIAndParsesCommaNumbers() throws {
        let output = "\u{001B}[32mEstimated Usage | resets on 2026-06-01 | KIRO POWER\u{001B}[0m\nCredits (1,234.5 of 10,000 covered in plan)\nOverages: Enabled"

        let usage = try KiroProvider.parseUsageOutput(output)

        XCTAssertEqual(usage.usedCredits, 1234.5, accuracy: 0.001)
        XCTAssertEqual(usage.totalCredits, 10_000, accuracy: 0.001)
        XCTAssertEqual(usage.planName, "Power")
        XCTAssertEqual(usage.overageStatus, "Enabled")
    }

    func testUsageParserTrimsPlanHintText() throws {
        let output = "Model: auto | Plan: KIRO PRO (/usage for more detail)\nCredits (3.66 of 1000 covered in plan)"

        let usage = try KiroProvider.parseUsageOutput(output)

        XCTAssertEqual(usage.planName, "Pro")
    }

    func testUsageParserReadsTableOutputWithSlashReset() throws {
        let output = #"""
        ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
        ┃                                                          | KIRO FREE      ┃
        ┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫
        ┃ Monthly credits:                                                          ┃
        ┃ ████████████████████████████████████████████████████████ 100% (resets on 01/01) ┃
        ┃                              (50.00 of 50 covered in plan)                 ┃
        ┃ Bonus credits:                                                            ┃
        ┃ 0.00/100 credits used, expires in 88 days                                 ┃
        ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
        """#

        let usage = try KiroProvider.parseUsageOutput(output)

        XCTAssertEqual(usage.usedCredits, 50, accuracy: 0.001)
        XCTAssertEqual(usage.totalCredits, 50, accuracy: 0.001)
        XCTAssertEqual(usage.planName, "Free")
        XCTAssertEqual(try XCTUnwrap(usage.bonusCreditsUsed), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(usage.bonusCreditsTotal), 100, accuracy: 0.001)
        XCTAssertEqual(usage.bonusExpiryDays, 88)
        XCTAssertNotNil(usage.resetDate)
    }

    func testUsageParserFallsBackToPercentAndPlanAllowance() throws {
        let output = "Estimated Usage | resets on 01/01 | KIRO POWER\n████████ 12%"

        let usage = try KiroProvider.parseUsageOutput(output)

        XCTAssertEqual(usage.usedCredits, 1_200, accuracy: 0.001)
        XCTAssertEqual(usage.totalCredits, 10_000, accuracy: 0.001)
        XCTAssertEqual(usage.planName, "Power")
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
            planName: "Pro",
            resetDate: resetDate,
            overageStatus: "Disabled",
            bonusCreditsUsed: 25,
            bonusCreditsTotal: 100,
            bonusExpiryDays: 14
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
        XCTAssertEqual(result.details?.planType, "Pro")
        XCTAssertEqual(try XCTUnwrap(result.details?.creditsRemaining), 996.34, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.details?.creditsTotal), 1000, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.details?.monthlyCost), 3.66, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.details?.secondaryUsage), 25, accuracy: 0.001)
        XCTAssertNotNil(result.details?.secondaryReset)
        XCTAssertEqual(result.details?.authSource, "kiro-cli at /Users/test/.local/bin/kiro-cli")
    }

    func testUsageParserReadsActualCLIOutputWithOverages() throws {
        // Real 2026-07 output from `kiro-cli chat --no-interactive /usage`
        let output = #"""
        Estimated Usage | resets on 2026-08-01 | KIRO PRO
        Credits (1000.00 of 1000 covered in plan)
        100%
        Overages: Enabled  billed at $0.04 per credit (managed by your organization)
        Credits used: 1472.94
        Est. cost: $58.92 USD
        """#

        let usage = try KiroProvider.parseUsageOutput(output)

        XCTAssertEqual(usage.totalCredits, 1000, accuracy: 0.001)
        XCTAssertEqual(usage.usedCredits, 1000, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(usage.totalConsumedCredits), 1472.94, accuracy: 0.001)
        XCTAssertEqual(usage.planName, "Pro")
        XCTAssertEqual(usage.overageStatus, "Enabled")
    }

    func testUsageParserPrefersRealTotalOverHardcodedPlanAllowance() throws {
        // If the CLI reports a total that differs from the hardcoded Pro=1000,
        // the real output must win.
        let output = "Estimated Usage | resets on 2026-08-01 | KIRO PRO\nCredits (1,905.00 of 1,905 monthly credits)"

        let usage = try KiroProvider.parseUsageOutput(output)

        XCTAssertEqual(usage.totalCredits, 1905, accuracy: 0.001)
        XCTAssertEqual(usage.usedCredits, 1905, accuracy: 0.001)
        XCTAssertEqual(usage.planName, "Pro")
    }

    func testMakeResultPreservesOverageAmount() throws {
        let snapshot = KiroUsageSnapshot(
            usedCredits: 1_000,
            totalCredits: 1_000,
            planName: "Pro",
            resetDate: nil,
            overageStatus: "Enabled",
            totalConsumedCredits: 1_050
        )

        let result = KiroProvider.makeResult(
            from: snapshot,
            binaryPath: URL(fileURLWithPath: "/Users/test/.local/bin/kiro-cli")
        )

        XCTAssertEqual(snapshot.remainingCredits, 0, accuracy: 0.001)
        XCTAssertEqual(result.usage.totalEntitlement, 100_000)
        XCTAssertLessThan(try XCTUnwrap(result.usage.remainingQuota), 0)
        XCTAssertGreaterThan(result.usage.usagePercentage, 100)
        if case .quotaBased(_, _, let overagePermitted) = result.usage {
            XCTAssertTrue(overagePermitted)
        } else {
            XCTFail("Expected quota-based usage")
        }
        XCTAssertEqual(try XCTUnwrap(result.details?.creditsRemaining), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.details?.monthlyCost), 1_050, accuracy: 0.001)
    }

    func testMakeResultWithoutOverageStaysWithinLimit() throws {
        let snapshot = KiroUsageSnapshot(
            usedCredits: 366,
            totalCredits: 1_000,
            planName: "Pro",
            resetDate: nil,
            overageStatus: "Disabled",
            totalConsumedCredits: 366
        )

        let result = KiroProvider.makeResult(
            from: snapshot,
            binaryPath: URL(fileURLWithPath: "/Users/test/.local/bin/kiro-cli")
        )

        XCTAssertEqual(result.usage.totalEntitlement, 100_000)
        XCTAssertEqual(result.usage.remainingQuota, 63_400)
        XCTAssertEqual(result.usage.usagePercentage, 36.6, accuracy: 0.001)
        XCTAssertTrue(result.usage.isWithinLimit)
        XCTAssertEqual(try XCTUnwrap(result.details?.creditsRemaining), 634, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.details?.monthlyCost), 366, accuracy: 0.001)
    }
}
