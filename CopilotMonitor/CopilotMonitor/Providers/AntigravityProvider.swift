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

private enum AntigravityProtobufValue {
    case varint(UInt64)
    case fixed64(Data)
    case lengthDelimited(Data)
    case fixed32(Data)
}

private typealias AntigravityProtobufMessage = [Int: [AntigravityProtobufValue]]

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

    private let cacheDBPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Application Support")
        .appendingPathComponent("Antigravity")
        .appendingPathComponent("User")
        .appendingPathComponent("globalStorage")
        .appendingPathComponent("state.vscdb")
        .path

    func fetch() async throws -> ProviderResult {
        logger.info("Antigravity cache fetch started")

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

    private func loadCachedAuthStatus() async throws -> AntigravityCachedAuthStatus {
        guard FileManager.default.fileExists(atPath: cacheDBPath) else {
            logger.error("Antigravity cache DB not found at \(self.cacheDBPath, privacy: .public)")
            throw ProviderError.providerError("Antigravity cache DB not found")
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
                guard let remainingFraction = extractRemainingFraction(from: quotaMessage[1]) else { continue }

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

    private func parseTimestampMessage(_ data: Data) throws -> Date {
        let timestampMessage = try parseProtobufMessage(data)
        guard let seconds = extractFirstVarint(from: timestampMessage[1]) else {
            throw ProviderError.decodingError("Timestamp seconds missing")
        }

        let nanos = extractFirstVarint(from: timestampMessage[2]) ?? 0
        return Date(timeIntervalSince1970: TimeInterval(seconds) + (TimeInterval(nanos) / 1_000_000_000))
    }

    private func parseProtobufMessage(_ data: Data) throws -> AntigravityProtobufMessage {
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

    private func readVarint(from bytes: [UInt8], index: inout Int) throws -> UInt64 {
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
