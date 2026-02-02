import XCTest
@testable import CopilotMonitor

final class GeminiCLIProviderTests: XCTestCase {
    
    func testParseGeminiQuotaResponse() throws {
        let fixture = try loadFixture(named: "gemini_response")
        let data = try JSONSerialization.data(withJSONObject: fixture, options: [])
        
        let decoder = JSONDecoder()
        let response = try decoder.decode(GeminiQuotaResponse.self, from: data)
        
        XCTAssertEqual(response.buckets.count, 5)
        
        XCTAssertEqual(response.buckets[0].modelId, "gemini-2.0-flash")
        XCTAssertEqual(response.buckets[0].remainingFraction, 1.0)
        XCTAssertEqual(response.buckets[0].resetTime, "2026-01-30T17:05:02Z")
        
        XCTAssertEqual(response.buckets[1].modelId, "gemini-2.5-flash")
        XCTAssertEqual(response.buckets[1].remainingFraction, 1.0)
        
        XCTAssertEqual(response.buckets[2].modelId, "gemini-2.5-pro")
        XCTAssertEqual(response.buckets[2].remainingFraction, 0.85)
        
        XCTAssertEqual(response.buckets[3].modelId, "gemini-3-flash-preview")
        XCTAssertEqual(response.buckets[3].remainingFraction, 0.95)
        
        XCTAssertEqual(response.buckets[4].modelId, "gemini-3-pro-preview")
        XCTAssertEqual(response.buckets[4].remainingFraction, 0.80)
    }
    
    func testMinimumRemainingFractionCalculation() throws {
        let fixture = try loadFixture(named: "gemini_response")
        let data = try JSONSerialization.data(withJSONObject: fixture, options: [])
        
        let decoder = JSONDecoder()
        let response = try decoder.decode(GeminiQuotaResponse.self, from: data)
        
        let minFraction = response.buckets.map(\.remainingFraction).min()
        
        XCTAssertEqual(minFraction, 0.80)
        
        let remainingPercentage = (minFraction ?? 0.0) * 100.0
        XCTAssertEqual(remainingPercentage, 80.0)
    }
    
    func testResetTimeParsingFromISO8601() throws {
        let fixture = try loadFixture(named: "gemini_response")
        let data = try JSONSerialization.data(withJSONObject: fixture, options: [])
        
        let decoder = JSONDecoder()
        let response = try decoder.decode(GeminiQuotaResponse.self, from: data)
        
        let formatter = ISO8601DateFormatter()
        let resetDates = response.buckets.compactMap { bucket -> Date? in
            formatter.date(from: bucket.resetTime)
        }
        
        XCTAssertEqual(resetDates.count, 5)
        
        let earliestReset = resetDates.min()
        XCTAssertNotNil(earliestReset)
    }
    
    private func loadFixture(named: String) throws -> Any {
        let testBundle = Bundle(for: type(of: self))
        
        guard let url = testBundle.url(forResource: named, withExtension: "json") else {
            throw NSError(domain: "FixtureError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture file not found: \(named)"])
        }
        
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        return json
    }
}
