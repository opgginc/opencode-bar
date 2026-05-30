import XCTest
@testable import OpenCode_Bar

final class CopilotProviderTests: XCTestCase {
    
    func testCopilotUsageDecoding() throws {
        let fixtureData = loadFixture(named: "copilot_response.json")
        let response = try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any]
        
        XCTAssertNotNil(response)
        XCTAssertEqual(response?["copilot_plan"] as? String, "individual_pro")
        
        let quotaSnapshots = response?["quota_snapshots"] as? [String: Any]
        XCTAssertNotNil(quotaSnapshots)
        
        let premiumInteractions = quotaSnapshots?["premium_interactions"] as? [String: Any]
        XCTAssertNotNil(premiumInteractions)
        XCTAssertEqual(premiumInteractions?["entitlement"] as? Int, 1500)
        XCTAssertEqual(premiumInteractions?["remaining"] as? Int, -3821)
        XCTAssertEqual(premiumInteractions?["overage_permitted"] as? Bool, true)
    }
    
    func testCopilotUsageModelDecoding() throws {
        let json = """
        {
            "netBilledAmount": 382.1,
            "netQuantity": 5321.0,
            "discountQuantity": 5321.0,
            "userPremiumRequestEntitlement": 1500,
            "filteredUserPremiumRequestEntitlement": 1500
        }
        """
        
        let decoder = JSONDecoder()
        let usage = try decoder.decode(CopilotUsage.self, from: json.data(using: .utf8)!)
        
        XCTAssertEqual(usage.netBilledAmount, 382.1)
        XCTAssertEqual(usage.usedRequests, 5321)
        XCTAssertEqual(usage.limitRequests, 1500)
    }
    
    func testCopilotUsageWithinLimit() throws {
        let json = """
        {
            "netBilledAmount": 0.0,
            "netQuantity": 500.0,
            "discountQuantity": 500.0,
            "userPremiumRequestEntitlement": 1500,
            "filteredUserPremiumRequestEntitlement": 1500
        }
        """
        
        let decoder = JSONDecoder()
        let usage = try decoder.decode(CopilotUsage.self, from: json.data(using: .utf8)!)
        
        XCTAssertEqual(usage.usedRequests, 500)
        XCTAssertEqual(usage.limitRequests, 1500)
        XCTAssertEqual(usage.usagePercentage, 33.333333333333336, accuracy: 0.01)
    }
    
    func testCopilotUsageOverageCalculation() throws {
        let json = """
        {
            "netBilledAmount": 382.1,
            "netQuantity": 5321.0,
            "discountQuantity": 5321.0,
            "userPremiumRequestEntitlement": 1500,
            "filteredUserPremiumRequestEntitlement": 1500
        }
        """
        
        let decoder = JSONDecoder()
        let usage = try decoder.decode(CopilotUsage.self, from: json.data(using: .utf8)!)
        
        let overage = usage.usedRequests - usage.limitRequests
        let expectedCost = Double(overage) * 0.10
        
        XCTAssertEqual(overage, 3821)
        XCTAssertEqual(expectedCost, 382.1, accuracy: 0.01)
        XCTAssertEqual(usage.netBilledAmount, expectedCost, accuracy: 0.01)
    }
    
    func testCopilotUsageMissingFields() throws {
        let json = """
        {
            "netBilledAmount": 0.0
        }
        """
        
        let decoder = JSONDecoder()
        let usage = try decoder.decode(CopilotUsage.self, from: json.data(using: .utf8)!)
        
        XCTAssertEqual(usage.netBilledAmount, 0.0)
        XCTAssertEqual(usage.usedRequests, 0)
        XCTAssertEqual(usage.limitRequests, 0)
    }
    
    // MARK: - CopilotAuthSource Tests

    func testCopilotAuthSourceAllCasesExist() {
        // Verify all four expected auth source cases exist and have distinct descriptions
        let descriptions: Set<String> = [
            CopilotAuthSource.opencodeAuth.description,
            CopilotAuthSource.copilotCliKeychain.description,
            CopilotAuthSource.vscodeHosts.description,
            CopilotAuthSource.vscodeApps.description
        ]
        XCTAssertEqual(descriptions.count, 4, "Each CopilotAuthSource case must have a unique description")
    }

    func testCopilotAuthSourceDescriptions() {
        XCTAssertEqual(CopilotAuthSource.opencodeAuth.description, "opencodeAuth")
        XCTAssertEqual(CopilotAuthSource.copilotCliKeychain.description, "copilotCliKeychain")
        XCTAssertEqual(CopilotAuthSource.vscodeHosts.description, "vscodeHosts")
        XCTAssertEqual(CopilotAuthSource.vscodeApps.description, "vscodeApps")
    }

    // MARK: - CopilotAuthSource.priority

    func testSourcePriorityOrdering() {
        XCTAssertGreaterThan(
            CopilotAuthSource.opencodeAuth.priority,
            CopilotAuthSource.copilotCliKeychain.priority,
            "opencodeAuth must outrank copilotCliKeychain"
        )
        XCTAssertGreaterThan(
            CopilotAuthSource.copilotCliKeychain.priority,
            CopilotAuthSource.vscodeHosts.priority,
            "copilotCliKeychain must outrank vscodeHosts"
        )
        XCTAssertGreaterThan(
            CopilotAuthSource.vscodeHosts.priority,
            CopilotAuthSource.vscodeApps.priority,
            "vscodeHosts must outrank vscodeApps"
        )
    }

    func testSourcePriorityAbsoluteValues() {
        XCTAssertEqual(CopilotAuthSource.opencodeAuth.priority, 3)
        XCTAssertEqual(CopilotAuthSource.copilotCliKeychain.priority, 2)
        XCTAssertEqual(CopilotAuthSource.vscodeHosts.priority, 1)
        XCTAssertEqual(CopilotAuthSource.vscodeApps.priority, 0)
    }

    // MARK: - CopilotCandidateDedupe

    func testCopilotDedupeRejectsMatchingUsageWithDifferentIdentities() {
        let personal = makeDedupeInput(accountId: "personal", email: "personal@example.com")
        let work = makeDedupeInput(accountId: "work", email: "work@example.com")

        XCTAssertFalse(CopilotCandidateDedupe.isSameAccountUsage(personal, work))
    }

    func testCopilotDedupeAcceptsMatchingUsageWithCaseInsensitiveIdentity() {
        let first = makeDedupeInput(accountId: "Foo", email: "Foo@Example.com")
        let second = makeDedupeInput(accountId: "foo", email: "foo@example.com")

        XCTAssertTrue(CopilotCandidateDedupe.isSameAccountUsage(first, second))
    }

    func testCopilotDedupeRejectsIdentitylessMatchingUsage() {
        let identified = makeDedupeInput(accountId: "foo", email: "foo@example.com")
        let identityless = makeDedupeInput(accountId: nil, email: nil)

        XCTAssertFalse(CopilotCandidateDedupe.isSameAccountUsage(identified, identityless))
    }

    func testCopilotDedupeDropsOnlyPlaceholderWithoutRealUsage() {
        let placeholder = makeDedupeInput(
            accountId: nil,
            email: nil,
            entitlement: 0,
            remaining: 0,
            isPlaceholder: true
        )
        let emptyRealCandidate = makeDedupeInput(
            accountId: "real-user",
            email: "real@example.com",
            entitlement: 300,
            remaining: 300,
            isPlaceholder: false
        )

        XCTAssertTrue(CopilotCandidateDedupe.shouldDropPlaceholder(placeholder))
        XCTAssertFalse(CopilotCandidateDedupe.shouldDropPlaceholder(emptyRealCandidate))

        let candidates = [placeholder, emptyRealCandidate]
        let filtered = CopilotCandidateDedupe.filterRemovingPlaceholders(candidates, input: { $0 })
        XCTAssertEqual(filtered.count, 1)
        XCTAssertFalse(filtered[0].isPlaceholder)
    }

    func testCopilotDedupeRejectsPlanMismatch() {
        let individual = makeDedupeInput(accountId: "user", email: "user@example.com", planType: "Individual")
        let business = makeDedupeInput(accountId: "user", email: "user@example.com", planType: "Business")

        XCTAssertFalse(CopilotCandidateDedupe.isSameAccountUsage(individual, business))
    }

    func testCopilotDedupeRejectsUsedRequestMismatch() {
        let first = makeDedupeInput(accountId: "user", email: "user@example.com", usedRequests: 16)
        let second = makeDedupeInput(accountId: "user", email: "user@example.com", usedRequests: 17)

        XCTAssertFalse(CopilotCandidateDedupe.isSameAccountUsage(first, second))
    }

    func testCopilotDedupeRejectsLimitRequestMismatch() {
        let first = makeDedupeInput(accountId: "user", email: "user@example.com", limitRequests: 300)
        let second = makeDedupeInput(accountId: "user", email: "user@example.com", limitRequests: 500)

        XCTAssertFalse(CopilotCandidateDedupe.isSameAccountUsage(first, second))
    }

    private func makeDedupeInput(
        accountId: String?,
        email: String?,
        entitlement: Int = 300,
        remaining: Int = 284,
        usedRequests: Int? = 16,
        limitRequests: Int? = 300,
        planType: String? = "Individual",
        isPlaceholder: Bool = false
    ) -> CopilotCandidateDedupeInput {
        CopilotCandidateDedupeInput(
            accountId: accountId,
            email: email,
            planType: planType,
            totalEntitlement: entitlement,
            remainingQuota: remaining,
            usedRequests: usedRequests,
            limitRequests: limitRequests,
            isPlaceholder: isPlaceholder
        )
    }

    private func loadFixture(named: String) -> Data {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: named, withExtension: nil) else {
            fatalError("Fixture \(named) not found")
        }
        guard let data = try? Data(contentsOf: url) else {
            fatalError("Could not load fixture \(named)")
        }
        return data
    }
}
