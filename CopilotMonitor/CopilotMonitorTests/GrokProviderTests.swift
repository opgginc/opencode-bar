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
        inner.append(fixed32Field(1, 42.5))

        var resetMessage = Data()
        resetMessage.append(varintField(1, resetEpoch))

        inner.append(lengthDelimitedField(5, resetMessage))

        var message = Data()
        message.append(lengthDelimitedField(1, inner))

        let response = grpcWebFrame(message)
        let parsed = try GrokProvider.parseGrpcWebBillingResponse(
            response,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(parsed.monthlyUsedPercent, 42.5, accuracy: 0.001)
        XCTAssertEqual(parsed.resetsAt, Date(timeIntervalSince1970: TimeInterval(resetEpoch)))
    }

    func testParseGrpcWebBillingResponsePrefersObservedUsagePath() throws {
        let resetEpoch: UInt64 = 1_800_000_000
        var inner = Data()
        inner.append(fixed32Field(1, 42.5))
        inner.append(lengthDelimitedField(5, varintField(1, resetEpoch)))

        var message = Data()
        message.append(fixed32Field(1, 99.0))
        message.append(lengthDelimitedField(1, inner))

        let parsed = try GrokProvider.parseGrpcWebBillingResponse(
            grpcWebFrame(message),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(parsed.monthlyUsedPercent, 42.5, accuracy: 0.001)
    }

    func testParseGrpcWebBillingResponseUsesResetMarkerFallback() throws {
        let resetEpoch: UInt64 = 1_800_000_000
        var inner = Data()
        inner.append(lengthDelimitedField(5, varintField(1, resetEpoch)))
        inner.append(lengthDelimitedField(6, varintField(1, 1)))

        let parsed = try GrokProvider.parseGrpcWebBillingResponse(
            grpcWebFrame(lengthDelimitedField(1, inner)),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(parsed.monthlyUsedPercent, 0)
        XCTAssertEqual(parsed.resetsAt, Date(timeIntervalSince1970: TimeInterval(resetEpoch)))
    }

    func testValidateGrpcStatusThrowsForHeaderStatus() {
        XCTAssertThrowsError(try GrokProvider.validateGrpcStatus(
            data: Data(),
            headers: ["grpc-status": "16", "grpc-message": "Invalid%20token"]
        )) { error in
            guard case ProviderError.networkError(let message) = error else {
                return XCTFail("Expected networkError, got \(error)")
            }
            XCTAssertTrue(message.contains("Invalid token"))
        }
    }

    func testValidateGrpcStatusThrowsForTrailerStatus() {
        let trailer = grpcWebFrame(Data("grpc-status: 13\r\ngrpc-message: bad%20status\r\n".utf8), flags: 0x80)

        XCTAssertThrowsError(try GrokProvider.validateGrpcStatus(data: trailer, headers: [:])) { error in
            guard case ProviderError.networkError(let message) = error else {
                return XCTFail("Expected networkError, got \(error)")
            }
            XCTAssertTrue(message.contains("bad status"))
        }
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

    func testSummarizeLocalSessionsSkipsStaleSignals() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-provider-tests-\(UUID().uuidString)")
        let recentSessionDir = root.appendingPathComponent("project/recent")
        let staleSessionDir = root.appendingPathComponent("project/stale")
        try FileManager.default.createDirectory(at: recentSessionDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staleSessionDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let json = """
        {
          "totalTokensBeforeCompaction": 100,
          "contextTokensUsed": 25,
          "primaryModelId": "grok-build"
        }
        """
        let recentSignalsURL = recentSessionDir.appendingPathComponent("signals.json")
        let staleSignalsURL = staleSessionDir.appendingPathComponent("signals.json")
        try Data(json.utf8).write(to: recentSignalsURL)
        try Data(json.utf8).write(to: staleSignalsURL)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let staleDate = now.addingTimeInterval(-31 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: recentSignalsURL.path)
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: staleSignalsURL.path)

        let summary = GrokProvider.summarizeLocalSessions(root: root, now: now)

        XCTAssertEqual(summary.sessionCount, 1)
        XCTAssertEqual(summary.totalTokens, 125)
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

    private func varintField(_ fieldNumber: UInt8, _ value: UInt64) -> Data {
        var data = Data([(fieldNumber << 3) | 0])
        data.append(encodeVarint(value))
        return data
    }

    private func lengthDelimitedField(_ fieldNumber: UInt8, _ payload: Data) -> Data {
        var data = Data([(fieldNumber << 3) | 2])
        data.append(encodeVarint(UInt64(payload.count)))
        data.append(payload)
        return data
    }

    private func fixed32Field(_ fieldNumber: UInt8, _ value: Float) -> Data {
        var data = Data([(fieldNumber << 3) | 5])
        data.append(float32LittleEndian(value))
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

    private func grpcWebFrame(_ payload: Data, flags: UInt8 = 0) -> Data {
        var frame = Data([flags])
        frame.append(UInt8((payload.count >> 24) & 0xFF))
        frame.append(UInt8((payload.count >> 16) & 0xFF))
        frame.append(UInt8((payload.count >> 8) & 0xFF))
        frame.append(UInt8(payload.count & 0xFF))
        frame.append(payload)
        return frame
    }
}
