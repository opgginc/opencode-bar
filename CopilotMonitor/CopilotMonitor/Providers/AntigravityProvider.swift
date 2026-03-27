import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "AntigravityProvider")

private func runCommandAsync(executableURL: URL, arguments: [String], timeout: TimeInterval = 60.0) async throws -> String {
    return try await withThrowingTaskGroup(of: String.self) { group in
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        group.addTask {
            try await withCheckedThrowingContinuation { continuation in
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                // Handlers are serialized by the process lifecycle.
                nonisolated(unsafe) var outputData = Data()

                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if !data.isEmpty {
                        outputData.append(data)
                    }
                }

                process.terminationHandler = { _ in
                    pipe.fileHandleForReading.readabilityHandler = nil

                    let remainingData = pipe.fileHandleForReading.readDataToEndOfFile()
                    if !remainingData.isEmpty {
                        outputData.append(remainingData)
                    }

                    guard let output = String(data: outputData, encoding: .utf8) else {
                        continuation.resume(throwing: ProviderError.providerError("Cannot decode output"))
                        return
                    }

                    continuation.resume(returning: output)
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw ProviderError.networkError("Command timeout after \(Int(timeout))s")
        }

        guard let result = try await group.next() else {
            throw ProviderError.networkError("Task group failed")
        }

        group.cancelAll()

        if process.isRunning {
            process.terminate()
        }

        return result
    }
}

private struct AntigravityCachedAuthStatus: Codable {
    let name: String?
    let email: String?
    let apiKey: String?
    let userStatusProtoBinaryBase64: String?
}

enum AntigravityProtobufValue {
    case varint(UInt64)
    case fixed64(Data)
    case lengthDelimited(Data)
    case fixed32(Data)
}

typealias AntigravityProtobufMessage = [Int: [AntigravityProtobufValue]]

private struct AntigravityParsedCacheUsage {
    let email: String?
    let modelBreakdown: [String: Double]
    let modelResetTimes: [String: Date]
}

/// Provider for Antigravity usage tracking using local cache reverse parsing.
/// This no longer relies on the localhost language server API.
final class AntigravityProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .antigravity
    let type: ProviderType = .quotaBased

    private let tokenManager: TokenManager
    private let session: URLSession

    private let cacheDBPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Application Support")
        .appendingPathComponent("Antigravity")
        .appendingPathComponent("User")
        .appendingPathComponent("globalStorage")
        .appendingPathComponent("state.vscdb")
        .path

    init(tokenManager: TokenManager = .shared, session: URLSession = .shared) {
        self.tokenManager = tokenManager
        self.session = session
    }

    func fetch() async throws -> ProviderResult {
        logger.info("Antigravity cache fetch started")

        do {
            return try await fetchFromCache()
        } catch {
            logger.warning("Antigravity cache fetch failed, attempting accounts fallback: \(error.localizedDescription)")
            return try await fetchFromAccountsFallback(cacheError: error)
        }
    }

    private func fetchFromCache() async throws -> ProviderResult {
        let authStatus = try await loadCachedAuthStatus()

        guard let userStatusProtoBase64 = nonEmptyTrimmed(authStatus.userStatusProtoBinaryBase64),
              let payload = Data(base64Encoded: userStatusProtoBase64) else {
            logger.error("Antigravity cache payload missing userStatusProtoBinaryBase64")
            throw ProviderError.providerError("Missing cached user status payload")
        }

        logger.info("Antigravity cache payload decoded: \(payload.count) bytes")

        let parsed = try parseCachedUsage(from: payload)
        guard !parsed.modelBreakdown.isEmpty else {
            logger.error("Antigravity cache payload has no model quota data")
            throw ProviderError.providerError("No model quota data in cache")
        }

        let minRemaining = parsed.modelBreakdown.values.min() ?? 0.0
        logger.info(
            "Antigravity cache fetch succeeded: \(parsed.modelBreakdown.count) models, min remaining \(String(format: "%.1f", minRemaining))%"
        )

        let details = DetailedUsage(
            modelBreakdown: parsed.modelBreakdown,
            modelResetTimes: parsed.modelResetTimes.isEmpty ? nil : parsed.modelResetTimes,
            planType: "cached",
            email: nonEmptyTrimmed(parsed.email) ?? nonEmptyTrimmed(authStatus.email),
            authSource: "Antigravity Cache (state.vscdb)"
        )

        let usage = ProviderUsage.quotaBased(
            remaining: Int(minRemaining),
            entitlement: 100,
            overagePermitted: false
        )

        return ProviderResult(usage: usage, details: details)
    }

    private func fetchFromAccountsFallback(cacheError: Error) async throws -> ProviderResult {
        guard let account = resolveFallbackAccount() else {
            throw ProviderError.providerError(
                "Antigravity cache unavailable and no enabled antigravity-accounts.json account with project ID was found"
            )
        }

        guard let accessToken = await tokenManager.refreshGeminiAccessToken(refreshToken: account.refreshToken) else {
            throw ProviderError.authenticationFailed("Unable to refresh Antigravity fallback token")
        }

        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota") else {
            throw ProviderError.networkError("Invalid API endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{\"project\":\"\(account.projectId)\"}".data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response type")
        }

        if httpResponse.statusCode == 401 {
            throw ProviderError.authenticationFailed("Antigravity fallback token expired")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }

        let quotaResponse = try JSONDecoder().decode(GeminiQuotaResponse.self, from: data)
        guard !quotaResponse.buckets.isEmpty else {
            throw ProviderError.decodingError("Empty buckets array")
        }

        let parsed = parseQuotaBuckets(quotaResponse.buckets)
        let minRemaining = parsed.modelBreakdown.values.min() ?? 0.0
        logger.info(
            "Antigravity fallback fetch succeeded: \(parsed.modelBreakdown.count) models, min remaining \(String(format: "%.1f", minRemaining))%, email=\(account.email ?? "unknown")"
        )
        logger.info("Antigravity fallback source selected because cache path failed: \(cacheError.localizedDescription)")

        let details = DetailedUsage(
            modelBreakdown: parsed.modelBreakdown,
            modelResetTimes: parsed.modelResetTimes.isEmpty ? nil : parsed.modelResetTimes,
            planType: "accounts-fallback",
            email: account.email,
            authSource: account.authSource
        )

        let usage = ProviderUsage.quotaBased(
            remaining: Int(minRemaining),
            entitlement: 100,
            overagePermitted: false
        )

        return ProviderResult(usage: usage, details: details)
    }

    private struct AntigravityFallbackAccount {
        let email: String?
        let refreshToken: String
        let projectId: String
        let authSource: String
    }

    private func resolveFallbackAccount() -> AntigravityFallbackAccount? {
        guard let antigravityAccounts = tokenManager.readAntigravityAccounts(),
              !antigravityAccounts.accounts.isEmpty else {
            logger.warning("Antigravity fallback unavailable: antigravity-accounts.json missing or empty")
            return nil
        }

        let preferredIndexes: [Int?] = [
            antigravityAccounts.activeIndexByFamily?["gemini"],
            antigravityAccounts.activeIndex
        ]

        func accountAtPreferredIndex() -> AntigravityAccounts.Account? {
            for preferredIndex in preferredIndexes {
                guard let index = preferredIndex,
                      antigravityAccounts.accounts.indices.contains(index) else {
                    continue
                }

                let account = antigravityAccounts.accounts[index]
                if account.enabled == false {
                    continue
                }

                return account
            }

            return antigravityAccounts.accounts.first(where: { $0.enabled != false })
        }

        guard let account = accountAtPreferredIndex() else {
            logger.warning("Antigravity fallback unavailable: no enabled account found")
            return nil
        }

        let refreshToken = account.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !refreshToken.isEmpty else {
            logger.warning("Antigravity fallback unavailable: selected account is missing refresh token")
            return nil
        }

        let primaryProjectId = account.projectId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackProjectId = account.managedProjectId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let projectId = primaryProjectId.isEmpty ? fallbackProjectId : primaryProjectId
        guard !projectId.isEmpty else {
            logger.warning("Antigravity fallback unavailable: selected account is missing project ID")
            return nil
        }

        return AntigravityFallbackAccount(
            email: nonEmptyTrimmed(account.email),
            refreshToken: refreshToken,
            projectId: projectId,
            authSource: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config")
                .appendingPathComponent("opencode")
                .appendingPathComponent("antigravity-accounts.json")
                .path
        )
    }

    private func parseQuotaBuckets(_ buckets: [GeminiQuotaResponse.Bucket]) -> AntigravityParsedCacheUsage {
        var modelBreakdown: [String: Double] = [:]
        var modelResetTimes: [String: Date] = [:]

        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso8601FormatterNoFrac = ISO8601DateFormatter()
        iso8601FormatterNoFrac.formatOptions = [.withInternetDateTime]

        for bucket in buckets {
            let clampedFraction = max(0.0, min(1.0, bucket.remainingFraction))
            modelBreakdown[bucket.modelId] = clampedFraction * 100.0

            if let resetDate = iso8601Formatter.date(from: bucket.resetTime)
                ?? iso8601FormatterNoFrac.date(from: bucket.resetTime) {
                modelResetTimes[bucket.modelId] = resetDate
            }
        }

        return AntigravityParsedCacheUsage(
            email: nil,
            modelBreakdown: modelBreakdown,
            modelResetTimes: modelResetTimes
        )
    }

    private func loadCachedAuthStatus() async throws -> AntigravityCachedAuthStatus {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: cacheDBPath),
              fileManager.isReadableFile(atPath: cacheDBPath) else {
            logger.error("Antigravity cache DB not readable at \(self.cacheDBPath, privacy: .public)")
            throw ProviderError.providerError("Antigravity cache DB not readable")
        }

        let query = "SELECT CAST(value AS TEXT) FROM ItemTable WHERE key='antigravityAuthStatus';"
        let output = try await runCommandAsync(
            executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: [cacheDBPath, query],
            timeout: 10
        )

        let jsonText = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jsonText.isEmpty else {
            logger.error("antigravityAuthStatus not found in cache DB")
            throw ProviderError.providerError("antigravityAuthStatus not found in cache DB")
        }

        guard let data = jsonText.data(using: .utf8) else {
            logger.error("Failed to convert cached auth JSON text to UTF-8 data")
            throw ProviderError.decodingError("Invalid cache auth JSON encoding")
        }

        do {
            return try JSONDecoder().decode(AntigravityCachedAuthStatus.self, from: data)
        } catch {
            logger.error("Failed to decode antigravityAuthStatus JSON: \(error.localizedDescription)")
            throw ProviderError.decodingError("Invalid antigravityAuthStatus JSON")
        }
    }

    private func parseCachedUsage(from payload: Data) throws -> AntigravityParsedCacheUsage {
        let root = try parseProtobufMessage(payload)
        let email = extractFirstString(from: root[7])

        var modelBreakdown: [String: Double] = [:]
        var modelResetTimes: [String: Date] = [:]

        for groupValue in root[33] ?? [] {
            guard case .lengthDelimited(let groupData) = groupValue else { continue }
            let groupMessage = try parseProtobufMessage(groupData)

            for modelValue in groupMessage[1] ?? [] {
                guard case .lengthDelimited(let modelData) = modelValue else { continue }
                let modelMessage = try parseProtobufMessage(modelData)

                guard let label = nonEmptyTrimmed(extractFirstString(from: modelMessage[1])) else { continue }
                guard let quotaPayload = extractFirstLengthDelimited(from: modelMessage[15]) else { continue }

                let quotaMessage = try parseProtobufMessage(quotaPayload)
                guard let remainingFraction = extractRemainingFraction(from: quotaMessage[1]),
                      remainingFraction.isFinite else {
                    logger.warning("Antigravity cache has non-finite remaining fraction for \(label, privacy: .public)")
                    continue
                }

                let clampedFraction = max(0.0, min(1.0, remainingFraction))
                modelBreakdown[label] = clampedFraction * 100.0

                if let resetPayload = extractFirstLengthDelimited(from: quotaMessage[2]),
                   let resetDate = try? parseTimestampMessage(resetPayload) {
                    modelResetTimes[label] = resetDate
                }
            }
        }

        return AntigravityParsedCacheUsage(
            email: email,
            modelBreakdown: modelBreakdown,
            modelResetTimes: modelResetTimes
        )
    }

    func parseTimestampMessage(_ data: Data) throws -> Date {
        let timestampMessage = try parseProtobufMessage(data)
        guard let seconds = extractFirstVarint(from: timestampMessage[1]) else {
            throw ProviderError.decodingError("Timestamp seconds missing")
        }

        let nanos = extractFirstVarint(from: timestampMessage[2]) ?? 0
        return Date(timeIntervalSince1970: TimeInterval(seconds) + (TimeInterval(nanos) / 1_000_000_000))
    }

    func parseProtobufMessage(_ data: Data) throws -> AntigravityProtobufMessage {
        let bytes = [UInt8](data)
        var index = 0
        var fields: AntigravityProtobufMessage = [:]

        while index < bytes.count {
            let key = try readVarint(from: bytes, index: &index)
            let fieldNumber = Int(key >> 3)
            let wireType = UInt8(key & 0x07)

            switch wireType {
            case 0:
                let value = try readVarint(from: bytes, index: &index)
                fields[fieldNumber, default: []].append(.varint(value))
            case 1:
                guard index + 8 <= bytes.count else {
                    throw ProviderError.decodingError("Malformed protobuf fixed64 field")
                }
                let valueData = Data(bytes[index..<(index + 8)])
                index += 8
                fields[fieldNumber, default: []].append(.fixed64(valueData))
            case 2:
                let lengthUInt64 = try readVarint(from: bytes, index: &index)
                guard let length = Int(exactly: lengthUInt64), index + length <= bytes.count else {
                    throw ProviderError.decodingError("Malformed protobuf length-delimited field")
                }
                let valueData = Data(bytes[index..<(index + length)])
                index += length
                fields[fieldNumber, default: []].append(.lengthDelimited(valueData))
            case 5:
                guard index + 4 <= bytes.count else {
                    throw ProviderError.decodingError("Malformed protobuf fixed32 field")
                }
                let valueData = Data(bytes[index..<(index + 4)])
                index += 4
                fields[fieldNumber, default: []].append(.fixed32(valueData))
            default:
                throw ProviderError.decodingError("Unsupported protobuf wire type: \(wireType)")
            }
        }

        return fields
    }

    func readVarint(from bytes: [UInt8], index: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        for _ in 0..<10 {
            guard index < bytes.count else {
                throw ProviderError.decodingError("Unexpected end of protobuf varint")
            }

            let byte = bytes[index]
            index += 1

            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 {
                return result
            }

            shift += 7
        }

        throw ProviderError.decodingError("Protobuf varint too long")
    }

    private func extractFirstVarint(from values: [AntigravityProtobufValue]?) -> UInt64? {
        guard let values else { return nil }
        for value in values {
            if case .varint(let raw) = value {
                return raw
            }
        }
        return nil
    }

    private func extractFirstLengthDelimited(from values: [AntigravityProtobufValue]?) -> Data? {
        guard let values else { return nil }
        for value in values {
            if case .lengthDelimited(let raw) = value {
                return raw
            }
        }
        return nil
    }

    private func extractFirstString(from values: [AntigravityProtobufValue]?) -> String? {
        guard let data = extractFirstLengthDelimited(from: values) else { return nil }
        guard let decoded = String(data: data, encoding: .utf8) else { return nil }
        return nonEmptyTrimmed(decoded)
    }

    private func extractRemainingFraction(from values: [AntigravityProtobufValue]?) -> Double? {
        guard let values else { return nil }

        for value in values {
            switch value {
            case .fixed32(let data):
                guard let raw = decodeUInt32LittleEndian(data) else { continue }
                return Double(Float(bitPattern: raw))
            case .fixed64(let data):
                guard let raw = decodeUInt64LittleEndian(data) else { continue }
                return Double(bitPattern: raw)
            case .varint(let raw):
                return Double(raw)
            case .lengthDelimited:
                continue
            }
        }

        return nil
    }

    private func decodeUInt32LittleEndian(_ data: Data) -> UInt32? {
        guard data.count == 4 else { return nil }
        var value: UInt32 = 0
        for (index, byte) in data.enumerated() {
            value |= UInt32(byte) << UInt32(index * 8)
        }
        return value
    }

    private func decodeUInt64LittleEndian(_ data: Data) -> UInt64? {
        guard data.count == 8 else { return nil }
        var value: UInt64 = 0
        for (index, byte) in data.enumerated() {
            value |= UInt64(byte) << UInt64(index * 8)
        }
        return value
    }

    private func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
