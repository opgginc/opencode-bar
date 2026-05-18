import XCTest
@testable import OpenCode_Bar

final class GrokProviderTests: XCTestCase {
    func testProviderIdentifier() {
        let provider = GrokProvider()
        XCTAssertEqual(provider.identifier, .grok)
    }

    func testProviderType() {
        let provider = GrokProvider()
        XCTAssertEqual(provider.type, .quotaBased)
    }

    func testSelectAuthEntryPrefersOIDCAndKeepsEmail() throws {
        let root: [String: Any] = [
            "https://accounts.x.ai/sign-in": [
                "key": "legacy-token",
                "email": "legacy@example.com",
                "auth_mode": "browser"
            ],
            "https://auth.x.ai::profile": [
                "key": "oidc-token",
                "email": "User@Example.COM",
                "team_id": "team-1",
                "user_id": "user-1",
                "auth_mode": "oidc",
                "expires_at": "2026-06-01T00:00:00Z"
            ]
        ]

        let selection = try GrokProvider.selectAuthEntry(from: root, source: "/tmp/auth.json")

        XCTAssertEqual(selection.accessToken, "oidc-token")
        XCTAssertEqual(selection.email, "User@Example.COM")
        XCTAssertEqual(selection.normalizedEmail, "user@example.com")
        XCTAssertEqual(selection.accountIdentifier, "user@example.com")
        XCTAssertEqual(selection.loginMethod, "SuperGrok")
        XCTAssertEqual(selection.source, "/tmp/auth.json")
    }

    func testParseGrpcWebBillingResponseReadsPercentAndPreferredReset() throws {
        let resetEpoch: UInt64 = 1_800_000_000
        var inner = Data()
        inner.append(13)
        inner.append(float32LittleEndian(42.5))

        var resetMessage = Data()
        resetMessage.append(8)
        resetMessage.append(encodeVarint(resetEpoch))

        inner.append(42)
        inner.append(encodeVarint(UInt64(resetMessage.count)))
        inner.append(resetMessage)

        var message = Data()
        message.append(10)
        message.append(encodeVarint(UInt64(inner.count)))
        message.append(inner)

        let response = grpcWebFrame(message)
        let parsed = try GrokProvider.parseGrpcWebBillingResponse(
            response,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(parsed.monthlyUsedPercent, 42.5, accuracy: 0.001)
        XCTAssertEqual(parsed.resetsAt, Date(timeIntervalSince1970: TimeInterval(resetEpoch)))
    }

    func testSummarizeLocalSessionsReadsRecentSignals() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-provider-tests-\(UUID().uuidString)")
        let sessionDir = root.appendingPathComponent("project/session")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let signalsURL = sessionDir.appendingPathComponent("signals.json")
        let json = """
        {
          "totalTokensBeforeCompaction": 100,
          "contextTokensUsed": 25,
          "primaryModelId": "grok-build",
          "modelsUsed": ["grok-build", "grok-code-fast"]
        }
        """
        try Data(json.utf8).write(to: signalsURL)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: signalsURL.path)

        let summary = GrokProvider.summarizeLocalSessions(root: root, now: now)

        XCTAssertEqual(summary.sessionCount, 1)
        XCTAssertEqual(summary.totalTokens, 125)
        XCTAssertEqual(summary.modelCounts["grok-build"], 2)
        XCTAssertEqual(summary.modelCounts["grok-code-fast"], 1)
    }

    func testAccountSubscriptionIDPrefersEmail() {
        let usage = ProviderUsage.quotaBased(remaining: 80, entitlement: 100, overagePermitted: false)
        let details = DetailedUsage(email: "User@Example.COM")
        let account = ProviderAccountResult(
            accountIndex: 0,
            accountId: "xai-user-id",
            usage: usage,
            details: details
        )

        XCTAssertEqual(account.subscriptionId, "user@example.com")
    }

    private func encodeVarint(_ value: UInt64) -> Data {
        var value = value
        var data = Data()
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
        return data
    }

    private func float32LittleEndian(_ value: Float) -> Data {
        let bits = value.bitPattern
        return Data([
            UInt8(bits & 0xFF),
            UInt8((bits >> 8) & 0xFF),
            UInt8((bits >> 16) & 0xFF),
            UInt8((bits >> 24) & 0xFF)
        ])
    }

    private func grpcWebFrame(_ payload: Data) -> Data {
        var frame = Data([0])
        frame.append(UInt8((payload.count >> 24) & 0xFF))
        frame.append(UInt8((payload.count >> 16) & 0xFF))
        frame.append(UInt8((payload.count >> 8) & 0xFF))
        frame.append(UInt8(payload.count & 0xFF))
        frame.append(payload)
        return frame
    }
}
