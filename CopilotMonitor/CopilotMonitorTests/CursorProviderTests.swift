import Foundation
import XCTest
@testable import OpenCode_Bar

final class CursorProviderTests: XCTestCase {
    func testNormalizeUsageSummaryMapsPlanAutoApiWindows() throws {
        let response = try decodeSummary(
            #"""
            {
              "membershipType": "pro",
              "billingCycleEnd": "2026-05-01T00:00:00Z",
              "individualUsage": {
                "plan": {
                  "totalPercentUsed": 42.4,
                  "autoPercentUsed": 31.2,
                  "apiPercentUsed": 78.9
                }
              }
            }
            """#
        )

        let normalized = try CursorProvider.normalizeUsageSummary(response)

        XCTAssertEqual(normalized.membershipType, "pro")
        XCTAssertEqual(normalized.primaryUsagePercent, 42.4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(normalized.autoUsagePercent), 31.2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(normalized.apiUsagePercent), 78.9, accuracy: 0.0001)
        XCTAssertNotNil(normalized.resetDate)
    }

    func testNormalizeUsageSummaryFallsBackToUsedLimit() throws {
        let response = try decodeSummary(
            #"""
            {
              "individualUsage": {
                "plan": {
                  "used": "1250",
                  "limit": "5000"
                }
              }
            }
            """#
        )

        let normalized = try CursorProvider.normalizeUsageSummary(response)

        XCTAssertEqual(normalized.primaryUsagePercent, 25.0, accuracy: 0.0001)
    }

    func testNormalizeUsageSummaryPrefersAutoApiAverageBeforeRawPlanUsage() throws {
        let response = try decodeSummary(
            #"""
            {
              "individualUsage": {
                "plan": {
                  "autoPercentUsed": 20,
                  "apiPercentUsed": 60,
                  "used": 90,
                  "limit": 100
                }
              }
            }
            """#
        )

        let normalized = try CursorProvider.normalizeUsageSummary(response)

        XCTAssertEqual(normalized.primaryUsagePercent, 40.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(normalized.autoUsagePercent), 20.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(normalized.apiUsagePercent), 60.0, accuracy: 0.0001)
    }

    func testNormalizeUsageSummaryUsesTeamOnDemandForTeamMembership() throws {
        let response = try decodeSummary(
            #"""
            {
              "membershipType": "team",
              "limitType": "team",
              "individualUsage": {
                "plan": {
                  "totalPercentUsed": 0
                }
              },
              "teamUsage": {
                "onDemand": {
                  "used": 45,
                  "limit": 100
                }
              }
            }
            """#
        )

        let normalized = try CursorProvider.normalizeUsageSummary(response)

        XCTAssertEqual(normalized.primaryUsagePercent, 45.0, accuracy: 0.0001)
    }

    func testExtractUserIdFromCLIConfig() throws {
        let data = Data(#"{"authInfo":{"authId":"auth0|user_cursor123"}}"#.utf8)

        XCTAssertEqual(CursorProvider.extractUserId(fromCLIConfigData: data), "user_cursor123")
    }

    func testExtractUserIdFromCursorAgentAuthInfoUserId() throws {
        let data = Data(#"{"authInfo":{"userId":123456789}}"#.utf8)

        XCTAssertEqual(CursorProvider.extractUserId(fromCLIConfigData: data), "123456789")
    }

    func testExtractUserIdPrefersAuthIdOverNumericCursorAgentUserId() throws {
        let data = Data(#"{"authInfo":{"authId":"auth0|user_cursoragent","userId":123456789}}"#.utf8)

        XCTAssertEqual(CursorProvider.extractUserId(fromAuthData: data), "user_cursoragent")
    }

    func testExtractAccessTokenFromCursorAgentAuthFile() throws {
        let data = Data(#"{"accessToken":"cursor_access_token"}"#.utf8)

        XCTAssertEqual(CursorProvider.extractAccessToken(fromAuthData: data), "cursor_access_token")
    }

    func testExtractAccessTokenFromNestedCursorAgentAuthInfo() throws {
        let data = Data(#"{"authInfo":{"access_token":"nested_cursor_access_token"}}"#.utf8)

        XCTAssertEqual(CursorProvider.extractAccessToken(fromAuthData: data), "nested_cursor_access_token")
    }

    func testExtractUserIdFromJWT() throws {
        let jwt = makeJWT(payload: #"{"sub":"auth0|user_fromjwt"}"#)

        XCTAssertEqual(CursorProvider.extractUserId(fromJWT: jwt), "user_fromjwt")
    }

    func testCursorPercentClampsAndRejectsInvalidLimits() {
        XCTAssertEqual(CursorProvider.cursorPercentFromUsedLimit(used: 150, limit: 100), 100)
        XCTAssertEqual(CursorProvider.cursorPercentFromUsedLimit(used: -25, limit: 100), 0)
        XCTAssertNil(CursorProvider.cursorPercentFromUsedLimit(used: 1, limit: 0))
        XCTAssertNil(CursorProvider.cursorPercentFromUsedLimit(used: nil, limit: 100))
    }

    private func decodeSummary(_ json: String) throws -> CursorUsageSummaryResponse {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(CursorUsageSummaryResponse.self, from: data)
    }

    private func makeJWT(payload: String) -> String {
        let header = #"{"alg":"RS256","typ":"JWT"}"#
        return "\(base64URL(header)).\(base64URL(payload)).signature"
    }

    private func base64URL(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
