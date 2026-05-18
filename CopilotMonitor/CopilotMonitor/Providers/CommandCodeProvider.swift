import Foundation
import Foundation
import os.log

private let commandCodeLogger = Logger(subsystem: "com.opencodeproviders", category: "CommandCodeProvider")

struct CommandCodePlan: Equatable {
    let id: String
    let displayName: String
    let monthlyCreditsUSD: Double
}

enum CommandCodePlanCatalog {
    static let plans: [String: CommandCodePlan] = [
        "individual-go": CommandCodePlan(id: "individual-go", displayName: "Go", monthlyCreditsUSD: 10),
        "individual-pro": CommandCodePlan(id: "individual-pro", displayName: "Pro", monthlyCreditsUSD: 30),
        "individual-max": CommandCodePlan(id: "individual-max", displayName: "Max", monthlyCreditsUSD: 150),
        "individual-ultra": CommandCodePlan(id: "individual-ultra", displayName: "Ultra", monthlyCreditsUSD: 300)
    ]

    static func plan(for id: String?) -> CommandCodePlan? {
        guard let id else { return nil }
        return plans[id.lowercased()]
    }
}

struct CommandCodeCookieHeader: Equatable {
    static let supportedCookieNames = [
        "__Host-better-auth.session_token",
        "__Secure-better-auth.session_token",
        "better-auth.session_token"
    ]
    static let productionCookieName = "__Secure-better-auth.session_token"

    let name: String
    let token: String

    var headerValue: String { "\(name)=\(token)" }

    static func override(from rawValue: String?) -> CommandCodeCookieHeader? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else {
            return nil
        }

        let parts = rawValue.split(separator: ";", omittingEmptySubsequences: true)
        for part in parts {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard supportedCookieNames.contains(name) else { continue }
            let token = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            return CommandCodeCookieHeader(name: name, token: token)
        }

        guard !rawValue.contains(";") && !rawValue.contains("=") else { return nil }
        return CommandCodeCookieHeader(name: productionCookieName, token: rawValue)
    }
}

enum CommandCodeProviderError: LocalizedError {
    case missingCredentials
    case invalidCredentials
    case apiError(Int)
    case parseFailed(String)
    case unknownPlan(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Command Code session cookie not found. Sign in to commandcode.ai or start OpenCommand."
        case .invalidCredentials:
            return "Command Code session cookie is invalid or expired."
        case .apiError(let status):
            return "Command Code API returned HTTP \(status)."
        case .parseFailed(let message):
            return "Command Code response could not be parsed: \(message)"
        case .unknownPlan(let planID):
            return "Command Code returned an unknown active plan: \(planID)"
        }
    }
}

struct CommandCodeUsageSnapshot: Equatable {
    let monthlyCreditsRemaining: Double
    let purchasedCredits: Double
    let premiumMonthlyCredits: Double
    let opensourceMonthlyCredits: Double
    let plan: CommandCodePlan?
    let billingPeriodEnd: Date?
    let subscriptionStatus: String?
    let authSource: String

    var monthlyCreditsTotal: Double? { plan?.monthlyCreditsUSD }

    var monthlyCreditsUsed: Double? {
        guard let monthlyCreditsTotal else { return nil }
        return max(0, monthlyCreditsTotal - monthlyCreditsRemaining)
    }

    var usagePercent: Double {
        guard let monthlyCreditsTotal, monthlyCreditsTotal > 0, let monthlyCreditsUsed else { return 0 }
        return min(max((monthlyCreditsUsed / monthlyCreditsTotal) * 100.0, 0), 999)
    }

    var usageSummary: String? {
        guard let monthlyCreditsTotal, let monthlyCreditsUsed else { return nil }
        let planDisplay = plan?.displayName ?? "Free"
        return String(format: "%@ · $%.2f of $%.2f", planDisplay, monthlyCreditsUsed, monthlyCreditsTotal)
    }
}

final class CommandCodeProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .commandCode
    let type: ProviderType = .quotaBased
    let fetchTimeout: TimeInterval = 15.0
    let minimumFetchInterval: TimeInterval = 60.0

    private let session: URLSession
    private let fileManager: FileManager
    private let environment: [String: String]

    init(
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.session = session
        self.fileManager = fileManager
        self.environment = environment
    }

    func fetch() async throws -> ProviderResult {
        debugLog("fetch started")

        if let proxyURL = loadOpenCommandProxyURL() {
            do {
                try await validateOpenCommandProxy(proxyURL: proxyURL)
                let snapshot = try await fetchOpenCommandUsage(proxyURL: proxyURL)
                commandCodeLogger.info("Command Code usage fetched through OpenCommand local proxy")
                debugLog("fetch completed through OpenCommand local proxy")
                return Self.makeResult(from: snapshot)
            } catch {
                commandCodeLogger.warning("OpenCommand proxy fetch failed: \(error.localizedDescription, privacy: .public)")
                debugLog("OpenCommand proxy fetch failed: \(error.localizedDescription); falling back to direct Command Code API")
            }
        }

        guard let cookieHeader = loadCookieHeader() else {
            debugLog("fetch failed: no Command Code credentials found")
            throw ProviderError.authenticationFailed(CommandCodeProviderError.missingCredentials.localizedDescription)
        }

        do {
            let snapshot = try await fetchDirectUsage(cookieHeader: cookieHeader.headerValue)
            commandCodeLogger.info("Command Code usage fetched through direct billing API")
            debugLog("fetch completed through direct Command Code API")
            return Self.makeResult(from: snapshot)
        } catch let error as CommandCodeProviderError {
            if case .invalidCredentials = error {
                throw ProviderError.authenticationFailed(error.localizedDescription)
            }
            throw ProviderError.providerError(error.localizedDescription)
        } catch {
            throw ProviderError.networkError(error.localizedDescription)
        }
    }

    // MARK: - Mapping

    static func makeResult(from snapshot: CommandCodeUsageSnapshot) -> ProviderResult {
        let totalUSD = snapshot.monthlyCreditsTotal ?? max(snapshot.monthlyCreditsRemaining, 0)
        let remainingUSD = snapshot.monthlyCreditsRemaining
        let entitlementCents = max(Int((totalUSD * 100.0).rounded()), 1)
        let remainingCents = Int((remainingUSD * 100.0).rounded())

        let details = DetailedUsage(
            primaryReset: snapshot.billingPeriodEnd,
            creditsBalance: snapshot.purchasedCredits,
            planType: snapshot.plan?.displayName ?? snapshot.subscriptionStatus,
            monthlyCost: snapshot.monthlyCreditsUsed,
            creditsRemaining: snapshot.monthlyCreditsRemaining,
            creditsTotal: snapshot.monthlyCreditsTotal,
            authSource: snapshot.authSource,
            authUsageSummary: snapshot.usageSummary
        )

        return ProviderResult(
            usage: .quotaBased(remaining: remainingCents, entitlement: entitlementCents, overagePermitted: false),
            details: details
        )
    }

    static func snapshotFromOpenCommandUsage(_ data: Data, authSource: String) throws -> CommandCodeUsageSnapshot {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CommandCodeProviderError.parseFailed("Expected JSON object")
        }

        let remaining = parseDouble(from: object, keys: ["credits_remaining", "creditsRemaining"])
        let monthlySpend = parseDouble(from: object, keys: ["monthly_spend", "monthlySpend"])
        var monthlyLimit = parseDouble(from: object, keys: ["monthly_limit", "monthlyLimit"])
        if monthlyLimit <= 0 {
            monthlyLimit = monthlySpend + remaining
        }
        guard monthlyLimit > 0 else {
            throw CommandCodeProviderError.parseFailed("monthly_limit is missing")
        }

        let resetDate = parseDate(from: object["reset_date"] as? String ?? object["resetDate"] as? String)
        let plan = CommandCodePlan(id: "opencommand", displayName: "OpenCommand", monthlyCreditsUSD: monthlyLimit)

        return CommandCodeUsageSnapshot(
            monthlyCreditsRemaining: remaining,
            purchasedCredits: 0,
            premiumMonthlyCredits: 0,
            opensourceMonthlyCredits: remaining,
            plan: plan,
            billingPeriodEnd: resetDate,
            subscriptionStatus: "OpenCommand",
            authSource: authSource
        )
    }

    static func snapshotFromDirectAPI(creditsData: Data, subscriptionData: Data, authSource: String) throws -> CommandCodeUsageSnapshot {
        let credits = try parseCreditsPayload(creditsData)
        let subscription = try parseSubscriptionPayload(subscriptionData)
        let plan = CommandCodePlanCatalog.plan(for: subscription.planID)

        if let planID = subscription.planID,
           subscription.status?.lowercased() == "active",
           plan == nil {
            throw CommandCodeProviderError.unknownPlan(planID)
        }

        return CommandCodeUsageSnapshot(
            monthlyCreditsRemaining: credits.monthlyCredits,
            purchasedCredits: credits.purchasedCredits,
            premiumMonthlyCredits: credits.premiumMonthlyCredits,
            opensourceMonthlyCredits: credits.opensourceMonthlyCredits,
            plan: plan,
            billingPeriodEnd: subscription.currentPeriodEnd,
            subscriptionStatus: subscription.status,
            authSource: authSource
        )
    }

    // MARK: - OpenCommand proxy

    private func loadOpenCommandProxyURL() -> URL? {
        let configURL = openCommandDirectory().appendingPathComponent("proxy-config.json")
        guard fileManager.fileExists(atPath: configURL.path), fileManager.isReadableFile(atPath: configURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: configURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawURL = object["url"] as? String,
                  let proxyURL = URL(string: rawURL) else {
                debugLog("OpenCommand proxy config found but could not be parsed")
                return nil
            }
            debugLog("OpenCommand proxy config found")
            return proxyURL
        } catch {
            debugLog("OpenCommand proxy config read failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func validateOpenCommandProxy(proxyURL: URL) async throws {
        let healthURL = proxyURL.appendingPathComponent("healthz")
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 3
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw ProviderError.networkError("OpenCommand health check failed")
        }
    }

    private func fetchOpenCommandUsage(proxyURL: URL) async throws -> CommandCodeUsageSnapshot {
        let usageURL = proxyURL.appendingPathComponent("v1/account/usage")
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = fetchTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid OpenCommand response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ProviderError.networkError("OpenCommand usage returned HTTP \(httpResponse.statusCode)")
        }

        return try Self.snapshotFromOpenCommandUsage(data, authSource: "OpenCommand local proxy")
    }

    // MARK: - Direct Command Code API

    private func fetchDirectUsage(cookieHeader: String) async throws -> CommandCodeUsageSnapshot {
        async let creditsTask = sendDirectRequest(path: "/internal/billing/credits", cookieHeader: cookieHeader)
        async let subscriptionTask = sendDirectRequest(path: "/internal/billing/subscriptions", cookieHeader: cookieHeader)
        let (creditsData, subscriptionData) = try await (creditsTask, subscriptionTask)
        return try Self.snapshotFromDirectAPI(
            creditsData: creditsData,
            subscriptionData: subscriptionData,
            authSource: "Command Code browser session cookie"
        )
    }

    private func sendDirectRequest(path: String, cookieHeader: String) async throws -> Data {
        guard let url = URL(string: "https://api.commandcode.ai\(path)") else {
            throw CommandCodeProviderError.parseFailed("Invalid Command Code URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = fetchTimeout
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://commandcode.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://commandcode.ai/studio", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CommandCodeProviderError.parseFailed("Invalid Command Code response")
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw CommandCodeProviderError.invalidCredentials
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw CommandCodeProviderError.apiError(httpResponse.statusCode)
        }
        return data
    }

    private func loadCookieHeader() -> CommandCodeCookieHeader? {
        for key in ["CC_SESSION_COOKIE", "COMMANDCODE_SESSION_COOKIE", "COMMAND_CODE_SESSION_COOKIE"] {
            if let header = CommandCodeCookieHeader.override(from: environment[key]) {
                debugLog("Command Code cookie loaded from environment key \(key)")
                return header
            }
        }

        if let header = loadCookieHeaderFromOpenCommandSecrets() {
            return header
        }

        do {
            let headerValue = try BrowserCookieService.shared.getCommandCodeCookieHeader()
            if let header = CommandCodeCookieHeader.override(from: headerValue) {
                debugLog("Command Code cookie loaded from browser cookie store")
                return header
            }
        } catch {
            debugLog("Browser cookie lookup failed: \(error.localizedDescription)")
        }

        return nil
    }

    private func loadCookieHeaderFromOpenCommandSecrets() -> CommandCodeCookieHeader? {
        let secretsURL = openCommandDirectory().appendingPathComponent("opencommand-secrets.json")
        guard fileManager.fileExists(atPath: secretsURL.path), fileManager.isReadableFile(atPath: secretsURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: secretsURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            for key in ["opencommand.cc_session_cookie", "opencommand.cc_session_token"] {
                if let header = CommandCodeCookieHeader.override(from: object[key] as? String) {
                    debugLog("Command Code cookie loaded from OpenCommand secrets")
                    return header
                }
            }
        } catch {
            debugLog("OpenCommand secrets read failed: \(error.localizedDescription)")
        }

        return nil
    }

    private func openCommandDirectory() -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".opencommand", isDirectory: true)
    }

    // MARK: - Parsing helpers

    private struct CreditsPayload {
        let monthlyCredits: Double
        let purchasedCredits: Double
        let premiumMonthlyCredits: Double
        let opensourceMonthlyCredits: Double
    }

    private struct SubscriptionPayload {
        let planID: String?
        let status: String?
        let currentPeriodEnd: Date?
    }

    private static func parseCreditsPayload(_ data: Data) throws -> CreditsPayload {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let credits = root["credits"] as? [String: Any] else {
            throw CommandCodeProviderError.parseFailed("Missing credits object")
        }

        return CreditsPayload(
            monthlyCredits: parseDouble(from: credits, keys: ["monthlyCredits"]),
            purchasedCredits: parseDouble(from: credits, keys: ["purchasedCredits"]),
            premiumMonthlyCredits: parseDouble(from: credits, keys: ["premiumMonthlyCredits"]),
            opensourceMonthlyCredits: parseDouble(from: credits, keys: ["opensourceMonthlyCredits"])
        )
    }

    private static func parseSubscriptionPayload(_ data: Data) throws -> SubscriptionPayload {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CommandCodeProviderError.parseFailed("Missing subscription object")
        }

        if let success = root["success"] as? Bool, !success {
            return SubscriptionPayload(planID: nil, status: nil, currentPeriodEnd: nil)
        }

        guard let dataObject = root["data"] as? [String: Any] else {
            return SubscriptionPayload(planID: nil, status: nil, currentPeriodEnd: nil)
        }

        let planID = dataObject["planId"] as? String ?? dataObject["planID"] as? String
        let status = dataObject["status"] as? String ?? "unknown"
        let currentPeriodEnd = parseDate(from: dataObject["currentPeriodEnd"] as? String)

        return SubscriptionPayload(planID: planID, status: status, currentPeriodEnd: currentPeriodEnd)
    }

    static func parseDouble(from dict: [String: Any], keys: [String]) -> Double {
        for key in keys {
            if let value = dict[key] as? Double { return value }
            if let value = dict[key] as? Int { return Double(value) }
            if let value = dict[key] as? NSNumber { return value.doubleValue }
            if let value = dict[key] as? String, let parsed = Double(value) { return parsed }
        }
        return 0
    }

    static func parseDate(from rawValue: String?) -> Date? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else {
            return nil
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: rawValue) { return date }

        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]
        if let date = plainFormatter.date(from: rawValue) { return date }

        let dateOnlyFormatter = DateFormatter()
        dateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
        if let utc = TimeZone(identifier: "UTC") {
            dateOnlyFormatter.timeZone = utc
        }
        return dateOnlyFormatter.date(from: rawValue)
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        let msg = "[\(Date())] CommandCodeProvider: \(message)\n"
        if let data = msg.data(using: .utf8) {
            let path = "/tmp/provider_debug.log"
            if fileManager.fileExists(atPath: path), let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
        #endif
    }
}
