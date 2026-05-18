import Foundation
import os.log

private let grokLogger = Logger(subsystem: "com.opencodeproviders", category: "GrokProvider")

struct GrokAuthSelection: Equatable {
    let scope: String
    let accessToken: String
    let email: String?
    let teamID: String?
    let userID: String?
    let authMode: String?
    let expiresAt: Date?
    let source: String

    var loginMethod: String? {
        guard let authMode, !authMode.isEmpty else { return nil }
        return authMode.lowercased() == "oidc" ? "SuperGrok" : authMode
    }

    var normalizedEmail: String? {
        Self.normalized(email)
    }

    var accountIdentifier: String? {
        normalizedEmail ?? Self.normalized(userID) ?? Self.normalized(teamID)
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }
}

struct GrokBillingUsage: Equatable {
    let monthlyUsedPercent: Double
    let resetsAt: Date?
}

struct GrokLocalSessionSummary: Equatable {
    let sessionCount: Int
    let totalTokens: Int
    let lastSessionAt: Date?
    let modelCounts: [String: Int]

    var sortedModelCounts: [(String, Int)] {
        modelCounts.sorted { lhs, rhs in
            if lhs.value != rhs.value {
                return lhs.value > rhs.value
            }
            return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
        }
    }
}

private struct GrokProtoScan {
    struct VarintField {
        let path: [Int]
        let value: UInt64
    }

    struct Fixed32Field {
        let path: [Int]
        let value: Double
        let order: Int
    }

    var varints: [VarintField] = []
    var fixed32: [Fixed32Field] = []
}

final class GrokProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .grok
    let type: ProviderType = .quotaBased
    let fetchTimeout: TimeInterval = 15
    let minimumFetchInterval: TimeInterval = 60

    private static let oidcScopePrefix = "https://auth.x.ai::"
    private static let legacyScope = "https://accounts.x.ai/sign-in"
    private static let endpoint = URL(
        string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"
    )!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch() async throws -> ProviderResult {
        grokLogger.info("Grok fetch started")

        let authFile = resolveAuthFile()
        let auth = try Self.loadAuth(from: authFile)
        if auth.isExpired {
            grokLogger.warning("Grok auth token is expired; attempting billing fetch before reporting failure")
        }

        let billing = try await fetchWebBilling(accessToken: auth.accessToken)
        let sessionsRoot = authFile.deletingLastPathComponent().appendingPathComponent("sessions")
        let localSessions = Self.summarizeLocalSessions(root: sessionsRoot)
        let usedPercent = min(max(billing.monthlyUsedPercent, 0), 999)
        let remaining = max(0, 100 - UsagePercentDisplayFormatter.wholePercent(from: usedPercent))

        let usage = ProviderUsage.quotaBased(
            remaining: remaining,
            entitlement: 100,
            overagePermitted: false
        )

        let modelBreakdown = Dictionary(
            uniqueKeysWithValues: localSessions.sortedModelCounts.map { model, count in
                (model, Double(count))
            }
        )

        let details = DetailedUsage(
            monthlyUsage: usedPercent,
            modelBreakdown: modelBreakdown.isEmpty ? nil : modelBreakdown,
            primaryReset: billing.resetsAt,
            planType: auth.loginMethod,
            sessions: localSessions.sessionCount,
            messages: localSessions.totalTokens,
            email: auth.email,
            authSource: auth.source,
            authUsageSummary: "Grok CLI"
        )

        let account = ProviderAccountResult(
            accountIndex: 0,
            accountId: auth.accountIdentifier,
            usage: usage,
            details: details
        )

        grokLogger.info(
            "Grok usage fetched: monthly=\(usedPercent, privacy: .public)% localSessions=\(localSessions.sessionCount, privacy: .public)"
        )
        return ProviderResult(usage: usage, details: details, accounts: [account])
    }

    static func loadAuth(from authFile: URL) throws -> GrokAuthSelection {
        guard FileManager.default.fileExists(atPath: authFile.path) else {
            throw ProviderError.authenticationFailed("Grok auth file not found. Run `grok login`.")
        }
        guard FileManager.default.isReadableFile(atPath: authFile.path) else {
            throw ProviderError.authenticationFailed("Grok auth file is not readable")
        }

        let data = try Data(contentsOf: authFile)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw ProviderError.decodingError("Grok auth JSON root is not an object")
        }

        return try selectAuthEntry(from: root, source: authFile.path)
    }

    static func selectAuthEntry(from root: [String: Any], source: String = "") throws -> GrokAuthSelection {
        if let token = nonEmptyString(root["key"]) {
            return authSelection(scope: "direct", entry: root, token: token, source: source)
        }

        var oidc: (String, [String: Any], String)?
        var legacy: (String, [String: Any], String)?
        var fallback: (String, [String: Any], String)?

        for (scope, rawEntry) in root {
            guard let entry = rawEntry as? [String: Any],
                  let token = nonEmptyString(entry["key"]) else {
                continue
            }

            if scope.hasPrefix(oidcScopePrefix) {
                oidc = (scope, entry, token)
            } else if scope == legacyScope || scope.contains("/sign-in") {
                legacy = (scope, entry, token)
            } else if fallback == nil {
                fallback = (scope, entry, token)
            }
        }

        guard let selected = oidc ?? legacy ?? fallback else {
            throw ProviderError.authenticationFailed("Grok auth file contains no access token")
        }

        return authSelection(scope: selected.0, entry: selected.1, token: selected.2, source: source)
    }

    static func parseGrpcWebBillingResponse(_ data: Data, now: Date = Date()) throws -> GrokBillingUsage {
        let frames = grpcWebDataFrames(data)
        guard !frames.isEmpty else {
            throw ProviderError.decodingError("Grok billing response contained no protobuf data frames")
        }

        var scan = GrokProtoScan()
        var order = 0
        for frame in frames {
            scanProtobuf(frame, path: [], depth: 0, order: &order, scan: &scan)
        }

        let usageCandidates = scan.fixed32
            .filter { field in
                guard field.path.last == 1 else { return false }
                return (0...100).contains(field.value)
            }
            .sorted { lhs, rhs in
                if lhs.path.count != rhs.path.count {
                    return lhs.path.count < rhs.path.count
                }
                return lhs.order < rhs.order
            }

        let resetCandidates = scan.varints.compactMap { field -> ([Int], Date)? in
            guard (1_700_000_000...2_100_000_000).contains(field.value) else { return nil }
            let date = Date(timeIntervalSince1970: TimeInterval(field.value))
            return date > now ? (field.path, date) : nil
        }

        let preferredResets = resetCandidates
            .filter { $0.0 == [1, 5, 1] }
            .map(\.1)
        let allResets = resetCandidates.map(\.1)
        let resetAt = (preferredResets.isEmpty ? allResets : preferredResets).min()

        let hasLocalResetMarker = scan.varints.contains { field in
            Array(field.path.prefix(2)) == [1, 6]
        }
        let usedPercent: Double?
        if let first = usageCandidates.first {
            usedPercent = first.value
        } else if scan.fixed32.isEmpty, resetAt != nil, hasLocalResetMarker {
            usedPercent = 0
        } else {
            usedPercent = nil
        }

        guard let usedPercent else {
            throw ProviderError.decodingError("Could not parse Grok billing usage")
        }

        return GrokBillingUsage(monthlyUsedPercent: usedPercent, resetsAt: resetAt)
    }

    static func validateGrpcStatus(data: Data, headers: [String: String]) throws {
        if let status = headers["grpc-status"], status != "0" {
            let message = headers["grpc-message"]?.removingPercentEncoding ?? ""
            throw ProviderError.networkError("gRPC status \(status): \(message)")
        }

        let trailers = grpcWebTrailerFields(data)
        if let status = trailers["grpc-status"], status != "0" {
            let message = trailers["grpc-message"]?.removingPercentEncoding ?? ""
            throw ProviderError.networkError("gRPC status \(status): \(message)")
        }
    }

    static func summarizeLocalSessions(root: URL, now: Date = Date()) -> GrokLocalSessionSummary {
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return GrokLocalSessionSummary(sessionCount: 0, totalTokens: 0, lastSessionAt: nil, modelCounts: [:])
        }

        var sessionCount = 0
        var totalTokens = 0
        var lastSessionAt: Date?
        var modelCounts: [String: Int] = [:]

        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "signals.json" {
            let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date.distantPast
            guard mtime >= cutoff else { continue }

            guard let data = try? Data(contentsOf: fileURL),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dict = object as? [String: Any] else {
                continue
            }

            sessionCount += 1
            totalTokens += intValue(dict["totalTokensBeforeCompaction"])
            totalTokens += intValue(dict["contextTokensUsed"])
            if lastSessionAt == nil || mtime > (lastSessionAt ?? Date.distantPast) {
                lastSessionAt = mtime
            }

            if let primaryModel = nonEmptyString(dict["primaryModelId"]) {
                modelCounts[primaryModel, default: 0] += 1
            }
            if let models = dict["modelsUsed"] as? [Any] {
                for rawModel in models {
                    guard let model = nonEmptyString(rawModel) else { continue }
                    modelCounts[model, default: 0] += 1
                }
            }
        }

        return GrokLocalSessionSummary(
            sessionCount: sessionCount,
            totalTokens: totalTokens,
            lastSessionAt: lastSessionAt,
            modelCounts: modelCounts
        )
    }

    private func resolveAuthFile() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["GROK_AUTH_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }

        let grokHome = environment["GROK_HOME"].flatMap { value -> String? in
            value.isEmpty ? nil : value
        } ?? "~/.grok"
        return URL(fileURLWithPath: NSString(string: grokHome).expandingTildeInPath)
            .appendingPathComponent("auth.json")
    }

    private func fetchWebBilling(accessToken: String) async throws -> GrokBillingUsage {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data([0, 0, 0, 0, 0])
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
        request.setValue("OpenCode Bar GrokProvider", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderError.networkError("Invalid Grok billing response")
            }

            let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                guard let key = pair.key as? String else { return }
                result[key.lowercased()] = "\(pair.value)"
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let body = String(data: Data(data.prefix(400)), encoding: .utf8) ?? ""
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    throw ProviderError.authenticationFailed(body.isEmpty ? "Invalid Grok auth token" : body)
                }
                throw ProviderError.networkError("HTTP \(httpResponse.statusCode) \(body)")
            }

            try Self.validateGrpcStatus(data: data, headers: headers)
            return try Self.parseGrpcWebBillingResponse(data)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.networkError(error.localizedDescription)
        }
    }

    private static func authSelection(
        scope: String,
        entry: [String: Any],
        token: String,
        source: String
    ) -> GrokAuthSelection {
        GrokAuthSelection(
            scope: scope,
            accessToken: token,
            email: nonEmptyString(entry["email"]),
            teamID: nonEmptyString(entry["team_id"]),
            userID: nonEmptyString(entry["user_id"]),
            authMode: nonEmptyString(entry["auth_mode"]),
            expiresAt: parseDate(entry["expires_at"]),
            source: source
        )
    }

    private static func grpcWebDataFrames(_ data: Data) -> [Data] {
        var frames: [Data] = []
        var index = 0

        while index + 5 <= data.count {
            let flags = data[index]
            let length = Int(data[index + 1]) << 24
                | Int(data[index + 2]) << 16
                | Int(data[index + 3]) << 8
                | Int(data[index + 4])
            let start = index + 5
            let end = start + length
            guard end <= data.count else { break }

            if flags & 0x80 == 0 {
                frames.append(Data(data[start..<end]))
            }
            index = end
        }

        return frames
    }

    private static func grpcWebTrailerFields(_ data: Data) -> [String: String] {
        var fields: [String: String] = [:]
        var index = 0

        while index + 5 <= data.count {
            let flags = data[index]
            let length = Int(data[index + 1]) << 24
                | Int(data[index + 2]) << 16
                | Int(data[index + 3]) << 8
                | Int(data[index + 4])
            let start = index + 5
            let end = start + length
            guard end <= data.count else { break }

            if flags & 0x80 != 0,
               let text = String(data: Data(data[start..<end]), encoding: .utf8) {
                for line in text.components(separatedBy: .newlines) where line.contains(":") {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    fields[String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
                        String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            index = end
        }

        return fields
    }

    private static func scanProtobuf(
        _ data: Data,
        path: [Int],
        depth: Int,
        order: inout Int,
        scan: inout GrokProtoScan
    ) {
        var index = 0
        while index < data.count {
            let fieldStart = index
            guard let key = readVarint(data, index: &index), key != 0 else {
                index = min(fieldStart + 1, data.count)
                continue
            }

            let fieldNumber = Int(key >> 3)
            let wireType = Int(key & 0x07)
            let fieldPath = path + [fieldNumber]

            switch wireType {
            case 0:
                guard let value = readVarint(data, index: &index) else {
                    index = min(fieldStart + 1, data.count)
                    continue
                }
                scan.varints.append(GrokProtoScan.VarintField(path: fieldPath, value: value))
            case 1:
                guard index + 8 <= data.count else { return }
                index += 8
            case 2:
                guard let lengthValue = readVarint(data, index: &index) else {
                    index = min(fieldStart + 1, data.count)
                    continue
                }
                let length = Int(lengthValue)
                guard length >= 0, length <= data.count - index else {
                    index = min(fieldStart + 1, data.count)
                    continue
                }
                let start = index
                let end = index + length
                if depth < 4 {
                    scanProtobuf(Data(data[start..<end]), path: fieldPath, depth: depth + 1, order: &order, scan: &scan)
                }
                index = end
            case 5:
                guard index + 4 <= data.count else { return }
                let bits = UInt32(data[index])
                    | UInt32(data[index + 1]) << 8
                    | UInt32(data[index + 2]) << 16
                    | UInt32(data[index + 3]) << 24
                index += 4
                let value = Double(Float(bitPattern: bits))
                if value.isFinite {
                    scan.fixed32.append(GrokProtoScan.Fixed32Field(path: fieldPath, value: value, order: order))
                    order += 1
                }
            default:
                index = min(fieldStart + 1, data.count)
            }
        }
    }

    private static func readVarint(_ data: Data, index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0

        while index < data.count && shift < 64 {
            let byte = data[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return value
            }
            shift += 7
        }

        return nil
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        guard let value = nonEmptyString(raw) else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: value) {
            return date
        }

        return nil
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func intValue(_ value: Any?) -> Int {
        switch value {
        case let int as Int:
            return int
        case let double as Double:
            return Int(double)
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string) ?? 0
        default:
            return 0
        }
    }
}
