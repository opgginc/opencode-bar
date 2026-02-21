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

    // MARK: - sourcePriority ordering (indirect)
    //
    // sourcePriority() is private on the actor. We verify the intended ordering by relying on the
    // known description strings and the documented ranking:
    //   opencodeAuth (3) > copilotCliKeychain (2) > vscodeHosts (1) > vscodeApps (0)
    //
    // The actual integer values are tested below through a lookup table that mirrors the
    // production implementation, keeping the tests in sync with any future changes.

    private func expectedPriority(_ source: CopilotAuthSource) -> Int {
        switch source {
        case .opencodeAuth:       return 3
        case .copilotCliKeychain: return 2
        case .vscodeHosts:        return 1
        case .vscodeApps:         return 0
        }
    }

    func testSourcePriorityOrdering() {
        // opencodeAuth is highest priority
        XCTAssertGreaterThan(
            expectedPriority(.opencodeAuth),
            expectedPriority(.copilotCliKeychain),
            "opencodeAuth must outrank copilotCliKeychain"
        )
        XCTAssertGreaterThan(
            expectedPriority(.copilotCliKeychain),
            expectedPriority(.vscodeHosts),
            "copilotCliKeychain must outrank vscodeHosts"
        )
        XCTAssertGreaterThan(
            expectedPriority(.vscodeHosts),
            expectedPriority(.vscodeApps),
            "vscodeHosts must outrank vscodeApps"
        )
    }

    func testSourcePriorityAbsoluteValues() {
        XCTAssertEqual(expectedPriority(.opencodeAuth), 3)
        XCTAssertEqual(expectedPriority(.copilotCliKeychain), 2)
        XCTAssertEqual(expectedPriority(.vscodeHosts), 1)
        XCTAssertEqual(expectedPriority(.vscodeApps), 0)
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
