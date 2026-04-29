import Foundation
import Foundation
import os.log

private let cursorLogger = Logger(subsystem: "com.opencodeproviders", category: "CursorProvider")

struct CursorUsageSummaryResponse: Decodable {
    struct UsageBucket: Decodable {
        let plan: UsagePlan?
        let onDemand: UsagePlan?

        private enum CodingKeys: String, CodingKey {
            case plan
            case onDemand
            case onDemandSnake = "on_demand"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            plan = try container.decodeIfPresent(UsagePlan.self, forKey: .plan)
            onDemand = try container.decodeIfPresent(UsagePlan.self, forKeys: [.onDemand, .onDemandSnake])
        }
    }

    struct UsagePlan: Decodable {
        let totalPercentUsed: Double?
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
        let used: Double?
        let limit: Double?

        private enum CodingKeys: String, CodingKey {
            case totalPercentUsed
            case totalPercentUsedSnake = "total_percent_used"
            case autoPercentUsed
            case autoPercentUsedSnake = "auto_percent_used"
            case apiPercentUsed
            case apiPercentUsedSnake = "api_percent_used"
            case used
            case limit
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            totalPercentUsed = try container.decodeFlexibleDoubleIfPresent(forKeys: [.totalPercentUsed, .totalPercentUsedSnake])
            autoPercentUsed = try container.decodeFlexibleDoubleIfPresent(forKeys: [.autoPercentUsed, .autoPercentUsedSnake])
            apiPercentUsed = try container.decodeFlexibleDoubleIfPresent(forKeys: [.apiPercentUsed, .apiPercentUsedSnake])
            used = try container.decodeFlexibleDoubleIfPresent(forKey: .used)
            limit = try container.decodeFlexibleDoubleIfPresent(forKey: .limit)
        }
    }

    let membershipType: String?
    let limitType: String?
    let billingCycleEnd: String?
    let individualUsage: UsageBucket?
    let teamUsage: UsageBucket?

    private enum CodingKeys: String, CodingKey {
        case membershipType
        case membershipTypeSnake = "membership_type"
        case limitType
        case limitTypeSnake = "limit_type"
        case billingCycleEnd
        case billingCycleEndSnake = "billing_cycle_end"
        case individualUsage
        case individualUsageSnake = "individual_usage"
        case teamUsage
        case teamUsageSnake = "team_usage"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        membershipType = try container.decodeIfPresent(String.self, forKeys: [.membershipType, .membershipTypeSnake])
        limitType = try container.decodeIfPresent(String.self, forKeys: [.limitType, .limitTypeSnake])
        billingCycleEnd = try container.decodeIfPresent(String.self, forKeys: [.billingCycleEnd, .billingCycleEndSnake])
        individualUsage = try container.decodeIfPresent(UsageBucket.self, forKeys: [.individualUsage, .individualUsageSnake])
        teamUsage = try container.decodeIfPresent(UsageBucket.self, forKeys: [.teamUsage, .teamUsageSnake])
    }
}

struct CursorNormalizedUsage {
    let membershipType: String?
    let primaryUsagePercent: Double
    let autoUsagePercent: Double?
    let apiUsagePercent: Double?
    let resetDate: Date?
}

final class CursorProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .cursor
    let type: ProviderType = .quotaBased
    let fetchTimeout: TimeInterval = 30.0

    private let fileManager: FileManager
    private let homeDirectory: URL

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    func fetch() async throws -> ProviderResult {
        debugLog("🔵 fetch started")
        cursorLogger.info("Cursor fetch started")

        let paths = resolvePaths()
        guard fileManager.fileExists(atPath: paths.appDirectory.path) else {
            debugLog("🔴 Cursor application support directory not found")
            throw ProviderError.authenticationFailed("Cursor is not installed or has not created its support directory")
        }

        guard fileManager.fileExists(atPath: paths.stateDatabase.path) else {
            debugLog("🔴 Cursor state database not found at \(paths.stateDatabase.path)")
            throw ProviderError.authenticationFailed("Cursor session database not found. Log in to Cursor first.")
        }

        guard fileManager.isReadableFile(atPath: paths.stateDatabase.path) else {
            debugLog("🔴 Cursor state database is not readable at \(paths.stateDatabase.path)")
            throw ProviderError.authenticationFailed("Cursor session database is not readable")
        }

        let token = try await extractSessionToken(paths: paths)
        debugLog("🟢 Cursor session token extracted for userId=\(token.userId)")

        let response = try await fetchUsageSummary(cookie: token.cookie)
        let normalized = try Self.normalizeUsageSummary(response)
        debugLog("🟢 Cursor usage normalized: plan=\(normalized.primaryUsagePercent), auto=\(normalized.autoUsagePercent ?? -1), api=\(normalized.apiUsagePercent ?? -1)")

        let usedPercent = UsagePercentDisplayFormatter.wholePercent(from: normalized.primaryUsagePercent)
        let remaining = max(0, 100 - usedPercent)
        let usage = ProviderUsage.quotaBased(remaining: remaining, entitlement: 100, overagePermitted: false)
        let details = DetailedUsage(
            planType: normalized.membershipType,
            authSource: paths.stateDatabase.path,
            authUsageSummary: "Cursor",
            cursorPlanUsage: normalized.primaryUsagePercent,
            cursorPlanReset: normalized.resetDate,
            cursorAutoUsage: normalized.autoUsagePercent,
            cursorAutoReset: normalized.resetDate,
            cursorApiUsage: normalized.apiUsagePercent,
            cursorApiReset: normalized.resetDate
        )

        debugLog("🟢 fetch completed")
        cursorLogger.info("Cursor fetch completed")
        return ProviderResult(usage: usage, details: details)
    }

    static func normalizeUsageSummary(_ response: CursorUsageSummaryResponse) throws -> CursorNormalizedUsage {
        let plan = response.individualUsage?.plan
        let individualOnDemand = response.individualUsage?.onDemand
        let teamOnDemand = response.teamUsage?.onDemand
        let autoPercent = clampPercent(plan?.autoPercentUsed)
        let apiPercent = clampPercent(plan?.apiPercentUsed)

        var planPercent = clampPercent(plan?.totalPercentUsed)
        if planPercent == nil, let autoPercent, let apiPercent {
            planPercent = (autoPercent + apiPercent) / 2.0
        }
        if planPercent == nil {
            planPercent = apiPercent ?? autoPercent
        }
        if planPercent == nil {
            planPercent = percentFromUsedLimit(used: plan?.used, limit: plan?.limit)
        }
        if planPercent == nil {
            planPercent = percentFromUsedLimit(used: individualOnDemand?.used, limit: individualOnDemand?.limit)
        }
        if planPercent == nil {
            planPercent = percentFromUsedLimit(used: teamOnDemand?.used, limit: teamOnDemand?.limit)
        }

        let individualOnDemandPercent = percentFromUsedLimit(used: individualOnDemand?.used, limit: individualOnDemand?.limit)
        let teamOnDemandPercent = percentFromUsedLimit(used: teamOnDemand?.used, limit: teamOnDemand?.limit)
        if (planPercent ?? 0) == 0, let individualOnDemandPercent, individualOnDemandPercent > 0 {
            planPercent = individualOnDemandPercent
        }
        if (planPercent ?? 0) == 0, let teamOnDemandPercent, teamOnDemandPercent > 0 {
            planPercent = teamOnDemandPercent
        }

        let membershipType = response.membershipType?.lowercased()
        let limitType = response.limitType?.lowercased()
        let shouldPreferTeamPool = limitType == "team" || membershipType == "enterprise" || membershipType == "team"
        if shouldPreferTeamPool,
           let teamOnDemandPercent,
           teamOnDemandPercent > 0,
           planPercent == nil || planPercent == 0 {
            planPercent = teamOnDemandPercent
        }

        guard let primaryUsagePercent = planPercent else {
            throw ProviderError.decodingError("Cursor usage summary did not contain quota windows")
        }

        return CursorNormalizedUsage(
            membershipType: response.membershipType,
            primaryUsagePercent: primaryUsagePercent,
            autoUsagePercent: autoPercent,
            apiUsagePercent: apiPercent,
            resetDate: parseResetDate(response.billingCycleEnd)
        )
    }

    static func cursorPercentFromUsedLimit(used: Double?, limit: Double?) -> Double? {
        percentFromUsedLimit(used: used, limit: limit)
    }

    static func extractUserId(fromCLIConfigData data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authInfo = object["authInfo"] as? [String: Any],
              let authId = authInfo["authId"] as? String else {
            return nil
        }
        return extractUserId(from: authId)
    }

    static func extractUserId(fromJWT jwt: String) -> String? {
        let parts = jwt.components(separatedBy: ".")
        guard parts.count >= 2, let payloadData = decodeBase64URL(parts[1]),
              let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let subject = object["sub"] as? String else {
            return nil
        }
        return extractUserId(from: subject)
    }

    private struct CursorPaths {
        let appDirectory: URL
        let stateDatabase: URL
        let cliConfig: URL
    }

    private struct CursorSessionToken {
        let cookie: String
        let userId: String
    }

    private func resolvePaths() -> CursorPaths {
        let appDirectory = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Cursor", isDirectory: true)
        return CursorPaths(
            appDirectory: appDirectory,
            stateDatabase: appDirectory
                .appendingPathComponent("User", isDirectory: true)
                .appendingPathComponent("globalStorage", isDirectory: true)
                .appendingPathComponent("state.vscdb"),
            cliConfig: homeDirectory
                .appendingPathComponent(".cursor", isDirectory: true)
                .appendingPathComponent("cli-config.json")
        )
    }

    private func extractSessionToken(paths: CursorPaths) async throws -> CursorSessionToken {
        let jwt = try await runSQLiteQuery(
            databasePath: paths.stateDatabase.path,
            query: "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken';"
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !jwt.isEmpty else {
            debugLog("🔴 Cursor access token missing from state database")
            throw ProviderError.authenticationFailed("Cursor session token not found. Log in to Cursor to refresh it.")
        }

        let userId = userIdFromCLIConfig(paths.cliConfig) ?? Self.extractUserId(fromJWT: jwt)
        guard let userId, !userId.isEmpty else {
            debugLog("🔴 Cursor user ID could not be extracted")
            throw ProviderError.authenticationFailed("Cursor user ID not found. Log in to Cursor to refresh it.")
        }

        return CursorSessionToken(cookie: "WorkosCursorSessionToken=\(userId)%3A%3A\(jwt)", userId: userId)
    }

    private func userIdFromCLIConfig(_ configURL: URL) -> String? {
        guard fileManager.fileExists(atPath: configURL.path), fileManager.isReadableFile(atPath: configURL.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: configURL) else {
            return nil
        }
        return Self.extractUserId(fromCLIConfigData: data)
    }

    private func fetchUsageSummary(cookie: String) async throws -> CursorUsageSummaryResponse {
        var request = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://www.cursor.com/settings", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = fetchTimeout

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid Cursor API response")
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            debugLog("🔴 Cursor API authentication failed with status \(httpResponse.statusCode)")
            throw ProviderError.authenticationFailed("Cursor session expired. Log in to Cursor again.")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            debugLog("🔴 Cursor API returned status \(httpResponse.statusCode)")
            throw ProviderError.networkError("Cursor API returned HTTP \(httpResponse.statusCode)")
        }

        do {
            return try JSONDecoder().decode(CursorUsageSummaryResponse.self, from: data)
        } catch {
            debugLog("🔴 Cursor usage summary decoding failed: \(error.localizedDescription)")
            throw ProviderError.decodingError("Failed to parse Cursor usage summary: \(error.localizedDescription)")
        }
    }

    private func runSQLiteQuery(databasePath: String, query: String) async throws -> String {
        guard fileManager.fileExists(atPath: "/usr/bin/sqlite3") else {
            throw ProviderError.providerError("sqlite3 is not available at /usr/bin/sqlite3")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databasePath, query]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        nonisolated(unsafe) var outputData = Data()
        nonisolated(unsafe) var errorData = Data()

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            outputData.append(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            errorData.append(handle.availableData)
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                if process.terminationStatus == 0 {
                    let output = String(data: outputData, encoding: .utf8) ?? ""
                    continuation.resume(returning: output)
                } else {
                    let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown sqlite3 error"
                    continuation.resume(throwing: ProviderError.providerError("Failed to read Cursor session database: \(errorOutput)"))
                }
            }

            do {
                try process.run()
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: ProviderError.providerError("Failed to start sqlite3: \(error.localizedDescription)"))
            }
        }
    }

    private static func percentFromUsedLimit(used: Double?, limit: Double?) -> Double? {
        guard let used, let limit, limit > 0, used.isFinite, limit.isFinite else {
            return nil
        }
        return clampPercent((used / limit) * 100.0)
    }

    private static func clampPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0.0), 100.0)
    }

    private static func parseResetDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        return ISO8601DateFormatter().date(from: value)
    }

    private static func extractUserId(from value: String) -> String? {
        guard let range = value.range(of: #"user_[A-Za-z0-9_]+"#, options: .regularExpression) else {
            return nil
        }
        return String(value[range])
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: 4 - padding)
        }
        return Data(base64Encoded: base64)
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        let msg = "[\(Date())] CursorProvider: \(message)\n"
        guard let data = msg.data(using: .utf8) else { return }
        let path = "/tmp/provider_debug.log"
        if fileManager.fileExists(atPath: path), let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        #endif
    }
}

private extension KeyedDecodingContainer {
    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKeys keys: [Key]) throws -> T? {
        for key in keys {
            if let value = try decodeIfPresent(type, forKey: key) {
                return value
            }
        }
        return nil
    }

    func decodeFlexibleDoubleIfPresent(forKey key: Key) throws -> Double? {
        try decodeFlexibleDoubleIfPresent(forKeys: [key])
    }

    func decodeFlexibleDoubleIfPresent(forKeys keys: [Key]) throws -> Double? {
        for key in keys {
            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return value
            }
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return Double(value)
            }
            if let value = try? decodeIfPresent(String.self, forKey: key), let parsed = Double(value) {
                return parsed
            }
        }
        return nil
    }
}
