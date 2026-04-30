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
        let token = try await extractSessionToken(paths: paths)
        debugLog("🟢 Cursor session token extracted from source=\(token.authSource)")

        let response = try await fetchUsageSummary(cookie: token.cookie)
        let normalized = try Self.normalizeUsageSummary(response)
        debugLog("🟢 Cursor usage normalized: headline=\(normalized.primaryUsagePercent), auto=\(normalized.autoUsagePercent ?? -1), api=\(normalized.apiUsagePercent ?? -1)")

        let visibleUsagePercent = Self.visibleUsagePercent(from: normalized)
        let usedPercent = UsagePercentDisplayFormatter.wholePercent(from: visibleUsagePercent)
        let remaining = max(0, 100 - usedPercent)
        let usage = ProviderUsage.quotaBased(remaining: remaining, entitlement: 100, overagePermitted: false)
        let billingCycleReset = normalized.resetDate
        let details = DetailedUsage(
            planType: normalized.membershipType,
            authSource: token.authSource,
            authUsageSummary: "Cursor",
            cursorAutoUsage: normalized.autoUsagePercent,
            cursorAutoReset: billingCycleReset,
            cursorApiUsage: normalized.apiUsagePercent,
            cursorApiReset: billingCycleReset
        )

        debugLog("🟢 fetch completed")
        cursorLogger.info("Cursor fetch completed")
        return ProviderResult(usage: usage, details: details)
    }

    static func normalizeUsageSummary(_ response: CursorUsageSummaryResponse) throws -> CursorNormalizedUsage {
        let plan = response.individualUsage?.plan
        let autoPercent = clampPercent(plan?.autoPercentUsed)
        let apiPercent = clampPercent(plan?.apiPercentUsed)
        let primaryUsagePercent = primaryUsagePercent(
            response: response,
            autoPercent: autoPercent,
            apiPercent: apiPercent
        )

        guard let primaryUsagePercent else {
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

    static func visibleUsagePercent(from normalized: CursorNormalizedUsage) -> Double {
        let visiblePercents = [normalized.autoUsagePercent, normalized.apiUsagePercent].compactMap { $0 }
        return visiblePercents.max() ?? normalized.primaryUsagePercent
    }

    private static func primaryUsagePercent(
        response: CursorUsageSummaryResponse,
        autoPercent: Double?,
        apiPercent: Double?
    ) -> Double? {
        let plan = response.individualUsage?.plan
        let individualOnDemand = response.individualUsage?.onDemand
        let teamOnDemand = response.teamUsage?.onDemand
        let individualOnDemandPercent = percentFromUsedLimit(used: individualOnDemand?.used, limit: individualOnDemand?.limit)
        let teamOnDemandPercent = percentFromUsedLimit(used: teamOnDemand?.used, limit: teamOnDemand?.limit)

        var percent = headlinePlanPercent(
            plan: plan,
            autoPercent: autoPercent,
            apiPercent: apiPercent,
            individualOnDemandPercent: individualOnDemandPercent,
            teamOnDemandPercent: teamOnDemandPercent
        )

        // Cursor can report a real 0% plan headline while on-demand has active usage;
        // use on-demand as the headline in that case so the status bar shows the active bucket.
        if (percent ?? 0) == 0, let individualOnDemandPercent, individualOnDemandPercent > 0 {
            percent = individualOnDemandPercent
        }
        if shouldPreferTeamPool(response),
           let teamOnDemandPercent,
           teamOnDemandPercent > 0,
           percent == nil || percent == 0 {
            percent = teamOnDemandPercent
        }

        return percent
    }

    private static func headlinePlanPercent(
        plan: CursorUsageSummaryResponse.UsagePlan?,
        autoPercent: Double?,
        apiPercent: Double?,
        individualOnDemandPercent: Double?,
        teamOnDemandPercent: Double?
    ) -> Double? {
        if let totalPercent = clampPercent(plan?.totalPercentUsed) {
            return totalPercent
        }
        if let autoPercent, let apiPercent {
            return (autoPercent + apiPercent) / 2.0
        }
        if let apiPercent {
            return apiPercent
        }
        if let autoPercent {
            return autoPercent
        }
        if let planPercent = percentFromUsedLimit(used: plan?.used, limit: plan?.limit) {
            return planPercent
        }
        return individualOnDemandPercent ?? teamOnDemandPercent
    }

    private static func shouldPreferTeamPool(_ response: CursorUsageSummaryResponse) -> Bool {
        let membershipType = response.membershipType?.lowercased()
        let limitType = response.limitType?.lowercased()
        return limitType == "team" || membershipType == "enterprise" || membershipType == "team"
    }

    static func cursorPercentFromUsedLimit(used: Double?, limit: Double?) -> Double? {
        percentFromUsedLimit(used: used, limit: limit)
    }

    static func extractUserId(fromCLIConfigData data: Data) -> String? {
        extractUserId(fromAuthData: data)
    }

    static func extractUserId(fromAuthData data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let containers = nestedAuthContainers(in: object)
        for container in containers {
            if let authId = firstString(in: container, keys: ["authId", "auth_id"]),
               let userId = extractUserId(from: authId) {
                return userId
            }
        }

        for container in containers {
            if let userId = firstString(in: container, keys: ["userId", "user_id"]), !userId.isEmpty {
                return userId
            }
        }

        return nil
    }

    static func extractAccessToken(fromAuthData data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        for container in nestedAuthContainers(in: object) {
            if let token = firstString(
                in: container,
                keys: ["accessToken", "access_token", "access", "sessionToken", "session_token"]
            ), !token.isEmpty {
                return token
            }
        }

        return nil
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
        let stateDatabase: URL
        let authFiles: [URL]
    }

    private struct CursorSessionToken {
        let cookie: String
        let userId: String
        let authSource: String
    }

    private func resolvePaths() -> CursorPaths {
        let appDirectory = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Cursor", isDirectory: true)
        var authFiles = [
            homeDirectory
                .appendingPathComponent(".cursor", isDirectory: true)
                .appendingPathComponent("cli-config.json"),
            homeDirectory
                .appendingPathComponent(".cursor", isDirectory: true)
                .appendingPathComponent("auth.json"),
            homeDirectory
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("cursor", isDirectory: true)
                .appendingPathComponent("cli-config.json"),
            homeDirectory
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("cursor", isDirectory: true)
                .appendingPathComponent("auth.json")
        ]
        if let xdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdgConfigHome.isEmpty {
            let xdgCursorDirectory = URL(fileURLWithPath: xdgConfigHome, isDirectory: true)
                .appendingPathComponent("cursor", isDirectory: true)
            authFiles.insert(xdgCursorDirectory.appendingPathComponent("cli-config.json"), at: 0)
            authFiles.insert(xdgCursorDirectory.appendingPathComponent("auth.json"), at: 1)
        }
        return CursorPaths(
            stateDatabase: appDirectory
                .appendingPathComponent("User", isDirectory: true)
                .appendingPathComponent("globalStorage", isDirectory: true)
                .appendingPathComponent("state.vscdb"),
            authFiles: Self.uniqueURLs(authFiles)
        )
    }

    private func extractSessionToken(paths: CursorPaths) async throws -> CursorSessionToken {
        let token = try await extractAccessToken(paths: paths)
        let userId = userIdFromAuthFiles(paths.authFiles) ?? Self.extractUserId(fromJWT: token.value)
        guard let userId, !userId.isEmpty else {
            debugLog("🔴 Cursor user ID could not be extracted")
            throw ProviderError.authenticationFailed("Cursor user ID not found. Log in to Cursor to refresh it.")
        }

        return CursorSessionToken(
            cookie: "WorkosCursorSessionToken=\(userId)%3A%3A\(token.value)",
            userId: userId,
            authSource: token.source
        )
    }

    private struct CursorAccessToken {
        let value: String
        let source: String
    }

    private func extractAccessToken(paths: CursorPaths) async throws -> CursorAccessToken {
        if let databaseToken = try await accessTokenFromStateDatabase(paths.stateDatabase) {
            return databaseToken
        }
        if let authFileToken = accessTokenFromAuthFiles(paths.authFiles) {
            return authFileToken
        }
        if let keychainToken = try await accessTokenFromKeychain() {
            return keychainToken
        }

        debugLog("🔴 Cursor access token was not found in state database, auth files, or keychain")
        throw ProviderError.authenticationFailed("Cursor session token not found. Log in with Cursor or cursor-agent first.")
    }

    private func accessTokenFromStateDatabase(_ databaseURL: URL) async throws -> CursorAccessToken? {
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            debugLog("🟡 Cursor state database not found at \(databaseURL.path); trying Cursor Agent auth")
            return nil
        }
        guard fileManager.isReadableFile(atPath: databaseURL.path) else {
            debugLog("🟡 Cursor state database is not readable at \(databaseURL.path); trying Cursor Agent auth")
            return nil
        }

        do {
            let jwt = try await runSQLiteQuery(
                databasePath: databaseURL.path,
                query: "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken';"
            ).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !jwt.isEmpty else {
                debugLog("🟡 Cursor access token missing from state database; trying Cursor Agent auth")
                return nil
            }

            debugLog("🟢 Cursor access token found in state database")
            return CursorAccessToken(value: jwt, source: databaseURL.path)
        } catch {
            debugLog("🟡 Cursor state database read failed: \(error.localizedDescription); trying Cursor Agent auth")
            return nil
        }
    }

    private func accessTokenFromAuthFiles(_ authFiles: [URL]) -> CursorAccessToken? {
        for url in authFiles {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            guard fileManager.isReadableFile(atPath: url.path) else {
                debugLog("🟡 Cursor auth file is not readable at \(url.path)")
                continue
            }
            guard let data = try? Data(contentsOf: url), let token = Self.extractAccessToken(fromAuthData: data) else {
                continue
            }
            debugLog("🟢 Cursor access token found in auth file at \(url.path)")
            return CursorAccessToken(value: token, source: url.path)
        }
        return nil
    }

    private func accessTokenFromKeychain() async throws -> CursorAccessToken? {
        do {
            let token = try await runSecurityGenericPassword(service: "cursor-access-token", account: "cursor-user")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                debugLog("🟡 Cursor keychain access token is empty")
                return nil
            }
            debugLog("🟢 Cursor access token found in keychain service cursor-access-token")
            return CursorAccessToken(value: token, source: "macOS Keychain: cursor-access-token")
        } catch {
            debugLog("🟡 Cursor keychain access token not available: \(error.localizedDescription)")
            return nil
        }
    }

    private func userIdFromAuthFiles(_ authFiles: [URL]) -> String? {
        for url in authFiles {
            guard fileManager.fileExists(atPath: url.path), fileManager.isReadableFile(atPath: url.path) else {
                continue
            }
            guard let data = try? Data(contentsOf: url), let userId = Self.extractUserId(fromAuthData: data) else {
                continue
            }
            debugLog("🟢 Cursor user ID found in auth file at \(url.path)")
            return userId
        }
        return nil
    }

    private func fetchUsageSummary(cookie: String) async throws -> CursorUsageSummaryResponse {
        guard let usageSummaryURL = URL(string: "https://cursor.com/api/usage-summary") else {
            throw ProviderError.providerError("Invalid Cursor usage summary URL")
        }

        var request = URLRequest(url: usageSummaryURL)
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

        return try await runProcess(
            executablePath: "/usr/bin/sqlite3",
            arguments: [databasePath, query],
            failureMessage: "Failed to read Cursor session database",
            startFailureMessage: "Failed to start sqlite3"
        )
    }

    private func runSecurityGenericPassword(service: String, account: String) async throws -> String {
        guard fileManager.fileExists(atPath: "/usr/bin/security") else {
            throw ProviderError.providerError("security is not available at /usr/bin/security")
        }

        return try await runProcess(
            executablePath: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", service, "-a", account, "-w"],
            failureMessage: "Failed to read Cursor keychain token",
            startFailureMessage: "Failed to start security"
        )
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        failureMessage: String,
        startFailureMessage: String
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

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
                    let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown process error"
                    continuation.resume(throwing: ProviderError.providerError("\(failureMessage): \(errorOutput)"))
                }
            }

            do {
                try process.run()
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: ProviderError.providerError("\(startFailureMessage): \(error.localizedDescription)"))
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

    private static func nestedAuthContainers(in object: [String: Any]) -> [[String: Any]] {
        var containers = [object]
        for key in ["authInfo", "auth_info", "userInfo", "user_info", "credentials", "oauth"] {
            if let nested = object[key] as? [String: Any] {
                containers.append(nested)
            }
        }
        return containers
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(object[key]), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            seen.insert(url.standardizedFileURL.path).inserted
        }
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
