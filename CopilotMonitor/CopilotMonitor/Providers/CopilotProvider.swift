import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "CopilotProvider")

// MARK: - CopilotProvider Implementation

/// Provider for GitHub Copilot usage tracking
/// Uses quota-based model with overage cost calculation
/// Authentication via browser cookies (Chrome/Brave/Arc/Edge)
final class CopilotProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .copilot
    let type: ProviderType = .quotaBased

    private let cacheKey = "cached_copilot_usage"
    private let cacheQueue = DispatchQueue(label: "com.opencodeproviders.CopilotProvider.cache")
    private var _cachedUserEmail: String?
    private var _cachedCustomerId: String?

    private var cachedUserEmail: String? {
        get { cacheQueue.sync { _cachedUserEmail } }
        set { cacheQueue.sync { _cachedUserEmail = newValue } }
    }

    private var cachedCustomerId: String? {
        get { cacheQueue.sync { _cachedCustomerId } }
        set { cacheQueue.sync { _cachedCustomerId = newValue } }
    }

    init() {
        logger.info("CopilotProvider: Initialized (cookie-based authentication)")
    }

    // MARK: - ProviderProtocol Implementation

    func fetch() async throws -> ProviderResult {
        let tokenAccounts = TokenManager.shared.getGitHubCopilotAccounts()
        var tokenInfos = await fetchTokenInfos(tokenAccounts)

        var candidates: [CopilotAccountCandidate] = []
        var cookieCandidate: CopilotAccountCandidate?

        let cookies: GitHubCookies?
        do {
            cookies = try BrowserCookieService.shared.getGitHubCookies()
        } catch {
            logger.warning("CopilotProvider: Failed to get cookies: \(error.localizedDescription)")
            cookies = nil
        }

        if let cookies = cookies, cookies.isValid {
            let cookieLogin = cookies.dotcomUser?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let login = cookieLogin, !login.isEmpty {
                cachedUserEmail = login
            }

            let matchedToken = matchTokenInfo(login: cookieLogin, tokenInfos: &tokenInfos)
            let planInfo = matchedToken?.planInfo

            if let customerId = await fetchCustomerId(cookies: cookies) {
                logger.info("CopilotProvider: Customer ID obtained - \(customerId)")

                if var usage = await fetchUsageData(customerId: customerId, cookies: cookies) {
                    if let planInfo {
                        usage = CopilotUsage(
                            netBilledAmount: usage.netBilledAmount,
                            netQuantity: usage.netQuantity,
                            discountQuantity: usage.discountQuantity,
                            userPremiumRequestEntitlement: usage.userPremiumRequestEntitlement,
                            filteredUserPremiumRequestEntitlement: usage.filteredUserPremiumRequestEntitlement,
                            copilotPlan: planInfo.plan,
                            quotaResetDateUTC: planInfo.quotaResetDateUTC
                        )
                        if let resetDate = planInfo.quotaResetDateUTC {
                            logger.info("CopilotProvider: Plan info merged - \(planInfo.plan ?? "unknown"), reset: \(resetDate)")
                        } else {
                            logger.info("CopilotProvider: Plan info merged - \(planInfo.plan ?? "unknown"), reset: unknown")
                        }
                    }

                    saveCache(usage: usage)

                    let remaining = usage.limitRequests - usage.usedRequests
                    logger.info("CopilotProvider: Fetch successful - used: \(usage.usedRequests), limit: \(usage.limitRequests), remaining: \(remaining)")

                    var dailyHistory: [DailyUsage]?
                    do {
                        dailyHistory = try await CopilotHistoryService.shared.fetchHistory()
                        logger.info("CopilotProvider: History fetched successfully - \(dailyHistory?.count ?? 0) days")
                    } catch {
                        logger.warning("CopilotProvider: Failed to fetch history: \(error.localizedDescription)")
                    }

                    let priority = sourcePriority(matchedToken?.source)
                    cookieCandidate = buildCandidateFromUsage(
                        usage: usage,
                        login: cookieLogin,
                        authSource: "Browser Cookies (Chrome/Brave/Arc/Edge)",
                        sourcePriority: priority,
                        dailyHistory: dailyHistory
                    )

                    if let cookieCandidate {
                        candidates.append(cookieCandidate)
                    }
                } else {
                    logger.warning("CopilotProvider: Failed to fetch usage data, trying cache")
                    cookieCandidate = try? buildCandidateFromCache()
                    if let cookieCandidate {
                        candidates.append(cookieCandidate)
                    }
                }
            } else {
                logger.warning("CopilotProvider: Failed to get customer ID, trying cache")
                cookieCandidate = try? buildCandidateFromCache()
                if let cookieCandidate {
                    candidates.append(cookieCandidate)
                }
            }
        } else {
            logger.warning("CopilotProvider: Invalid or missing cookies, trying cache")
            cookieCandidate = try? buildCandidateFromCache()
            if let cookieCandidate {
                candidates.append(cookieCandidate)
            }
        }

        for info in tokenInfos {
            if let tokenCandidate = buildCandidateFromToken(info) {
                candidates.append(tokenCandidate)
            }
        }

        if candidates.isEmpty {
            logger.error("CopilotProvider: No usable Copilot data found")
            throw ProviderError.authenticationFailed("No Copilot data available")
        }

        return finalizeResult(candidates: candidates, cookieCandidate: cookieCandidate)
    }

    private func formatResetDate(_ date: Date?) -> String? {
        guard let date = date else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    // MARK: - Token & Account Helpers

    private struct CopilotTokenInfo {
        let accountId: String?
        let login: String?
        let planInfo: CopilotPlanInfo?
        let authSource: String
        let source: CopilotAuthSource

        var quotaLimit: Int? { planInfo?.quotaLimit }
        var quotaRemaining: Int? { planInfo?.quotaRemaining }
        var plan: String? { planInfo?.plan }
        var resetDate: Date? { planInfo?.quotaResetDateUTC }
    }

    private struct CopilotAccountCandidate {
        let accountId: String?
        let usage: ProviderUsage
        let details: DetailedUsage
        let sourcePriority: Int
    }

    private func sourcePriority(_ source: CopilotAuthSource?) -> Int {
        switch source {
        case .opencodeAuth:
            return 3
        case .vscodeHosts:
            return 2
        case .vscodeApps:
            return 1
        case .none:
            return 0
        }
    }

    private func fetchTokenInfos(_ accounts: [CopilotAuthAccount]) async -> [CopilotTokenInfo] {
        var infos: [CopilotTokenInfo] = []

        for account in accounts {
            let planInfo = await TokenManager.shared.fetchCopilotPlanInfo(accessToken: account.accessToken)
            var login = account.login

            if login == nil {
                login = await fetchCopilotUserLogin(accessToken: account.accessToken)
            }

            let accountId = account.accountId ?? planInfo?.userId ?? login
            infos.append(
                CopilotTokenInfo(
                    accountId: accountId,
                    login: login,
                    planInfo: planInfo,
                    authSource: account.authSource,
                    source: account.source
                )
            )
        }

        return dedupeTokenInfos(infos)
    }

    private func dedupeTokenInfos(_ infos: [CopilotTokenInfo]) -> [CopilotTokenInfo] {
        var results: [CopilotTokenInfo] = []

        for info in infos {
            if let accountId = info.accountId,
               let index = results.firstIndex(where: { $0.accountId == accountId }) {
                if sourcePriority(info.source) > sourcePriority(results[index].source) {
                    results[index] = info
                }
                continue
            }

            if let login = info.login,
               let index = results.firstIndex(where: { $0.login == login }) {
                if sourcePriority(info.source) > sourcePriority(results[index].source) {
                    results[index] = info
                }
                continue
            }

            results.append(info)
        }

        return results
    }

    private func matchTokenInfo(login: String?, tokenInfos: inout [CopilotTokenInfo]) -> CopilotTokenInfo? {
        guard let login = login, !login.isEmpty else { return nil }
        if let index = tokenInfos.firstIndex(where: { $0.login?.caseInsensitiveCompare(login) == .orderedSame }) {
            return tokenInfos.remove(at: index)
        }
        return nil
    }

    private func fetchCopilotUserLogin(accessToken: String) async -> String? {
        guard let url = URL(string: "https://api.github.com/user") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("token \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-Github-Api-Version")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return json["login"] as? String
        } catch {
            logger.warning("CopilotProvider: Failed to fetch user login: \(error.localizedDescription)")
            return nil
        }
    }

    private func buildCandidateFromUsage(
        usage: CopilotUsage,
        login: String?,
        authSource: String,
        sourcePriority: Int,
        dailyHistory: [DailyUsage]?
    ) -> CopilotAccountCandidate {
        let remaining = usage.limitRequests - usage.usedRequests
        let providerUsage = ProviderUsage.quotaBased(
            remaining: remaining,
            entitlement: usage.limitRequests,
            overagePermitted: true
        )

        let details = DetailedUsage(
            resetPeriod: formatResetDate(usage.quotaResetDateUTC),
            planType: usage.copilotPlan,
            email: login,
            dailyHistory: dailyHistory,
            authSource: authSource,
            copilotOverageCost: usage.netBilledAmount,
            copilotOverageRequests: usage.netQuantity,
            copilotUsedRequests: usage.usedRequests,
            copilotLimitRequests: usage.limitRequests,
            copilotQuotaResetDateUTC: usage.quotaResetDateUTC
        )

        return CopilotAccountCandidate(
            accountId: login,
            usage: providerUsage,
            details: details,
            sourcePriority: sourcePriority
        )
    }

    private func buildCandidateFromToken(_ info: CopilotTokenInfo) -> CopilotAccountCandidate? {
        if info.planInfo == nil && info.login == nil && info.accountId == nil {
            return nil
        }
        let limit = info.quotaLimit
        let remaining = info.quotaRemaining
        let used: Int? = {
            guard let limit = limit, let remaining = remaining else { return nil }
            return max(0, limit - remaining)
        }()

        let providerUsage: ProviderUsage
        if let limit = limit, let remaining = remaining, limit > 0 {
            providerUsage = ProviderUsage.quotaBased(
                remaining: max(0, remaining),
                entitlement: limit,
                overagePermitted: true
            )
        } else {
            providerUsage = ProviderUsage.quotaBased(
                remaining: 0,
                entitlement: 0,
                overagePermitted: true
            )
        }

        let details = DetailedUsage(
            planType: info.plan,
            email: info.login,
            authSource: info.authSource,
            copilotUsedRequests: used,
            copilotLimitRequests: limit,
            copilotQuotaResetDateUTC: info.resetDate
        )

        return CopilotAccountCandidate(
            accountId: info.accountId ?? info.login,
            usage: providerUsage,
            details: details,
            sourcePriority: sourcePriority(info.source)
        )
    }

    private func buildCandidateFromCache() throws -> CopilotAccountCandidate? {
        let cachedResult = try loadCachedUsageWithEmail()
        guard let details = cachedResult.details else { return nil }
        return CopilotAccountCandidate(
            accountId: details.email,
            usage: cachedResult.usage,
            details: details,
            sourcePriority: 0
        )
    }

    private func finalizeResult(
        candidates: [CopilotAccountCandidate],
        cookieCandidate: CopilotAccountCandidate?
    ) -> ProviderResult {
        let merged = CandidateDedupe.merge(
            candidates,
            accountId: { $0.accountId },
            isSameUsage: isSameUsage,
            priority: { $0.sourcePriority }
        )
        let sorted = merged.sorted { $0.sourcePriority > $1.sourcePriority }

        let accountResults: [ProviderAccountResult] = sorted.enumerated().map { index, candidate in
            ProviderAccountResult(
                accountIndex: index,
                accountId: candidate.accountId,
                usage: candidate.usage,
                details: candidate.details
            )
        }

        let usageCandidates = accountResults.filter { ($0.usage.totalEntitlement ?? 0) > 0 }
        let minRemaining = usageCandidates.compactMap { $0.usage.remainingQuota }.min() ?? 0
        let entitlement = usageCandidates.first?.usage.totalEntitlement ?? 0
        let aggregateUsage = ProviderUsage.quotaBased(
            remaining: minRemaining,
            entitlement: entitlement,
            overagePermitted: true
        )

        let primaryDetails = cookieCandidate?.details ?? accountResults.first?.details

        return ProviderResult(
            usage: aggregateUsage,
            details: primaryDetails,
            accounts: accountResults
        )
    }

    private func isSameUsage(_ lhs: CopilotAccountCandidate, _ rhs: CopilotAccountCandidate) -> Bool {
        guard let leftUsed = lhs.details.copilotUsedRequests,
              let rightUsed = rhs.details.copilotUsedRequests,
              let leftLimit = lhs.details.copilotLimitRequests,
              let rightLimit = rhs.details.copilotLimitRequests else {
            return false
        }

        let resetMatch = sameDate(lhs.details.copilotQuotaResetDateUTC, rhs.details.copilotQuotaResetDateUTC)
        return leftUsed == rightUsed && leftLimit == rightLimit && resetMatch
    }

    private func sameDate(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (left?, right?):
            return Int(left.timeIntervalSince1970) == Int(right.timeIntervalSince1970)
        default:
            return false
        }
    }

    // MARK: - Customer ID Fetching

    private func fetchCustomerId(cookies: GitHubCookies) async -> String? {
        if let cached = cachedCustomerId {
            return cached
        }

        if let htmlId = await fetchCustomerIdFromBillingPage(cookies: cookies) {
            cachedCustomerId = htmlId
            return htmlId
        }

        logger.warning("CopilotProvider: All customer ID strategies failed")
        return nil
    }

    // MARK: - Billing Page Customer ID Extraction
    /// - Parameter cookies: Valid GitHub cookies
    /// - Returns: Customer ID or nil
    private func fetchCustomerIdFromBillingPage(cookies: GitHubCookies) async -> String? {
        logger.info("CopilotProvider: [Step 2] Trying billing page HTML extraction")

        guard let url = URL(string: "https://github.com/settings/billing") else { return nil }

        var request = URLRequest(url: url)
        request.setValue(cookies.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    logger.warning("CopilotProvider: Billing page auth failed (HTTP \(httpResponse.statusCode))")
                    return nil
                }
            }

            guard let html = String(data: data, encoding: .utf8) else { return nil }

            // Try multiple regex patterns for robustness
            let patterns = [
                #""customerId":\s*(\d+)"#,      // JSON in script
                #""customerId&quot;:(\d+)"#,    // HTML-encoded JSON
                #"customer_id=(\d+)"#,          // URL parameter
                #"customerId":(\d+)"#           // Without quotes
            ]

            for pattern in patterns {
                if let customerId = extractCustomerIdWithPattern(pattern, from: html) {
                    logger.info("CopilotProvider: Billing page extraction successful - \(customerId)")
                    return customerId
                }
            }
        } catch {
            logger.error("CopilotProvider: Billing page fetch error - \(error.localizedDescription)")
        }

        return nil
    }

    /// Extract customer ID using regex pattern
    private func extractCustomerIdWithPattern(_ pattern: String, from html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[range])
    }

    // MARK: - Usage Data Fetching

    /// Fetch usage data from GitHub billing API using cookies
    /// - Parameters:
    ///   - customerId: GitHub customer ID
    ///   - cookies: Valid GitHub cookies
    /// - Returns: CopilotUsage or nil if fetch fails
    private func fetchUsageData(customerId: String, cookies: GitHubCookies) async -> CopilotUsage? {
        let urlString = "https://github.com/settings/billing/copilot_usage_card?customer_id=\(customerId)&period=3"

        guard let url = URL(string: urlString) else {
            logger.error("CopilotProvider: Invalid usage URL")
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue(cookies.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    logger.warning("CopilotProvider: Usage API auth failed (HTTP \(httpResponse.statusCode))")
                    return nil
                }

                if httpResponse.statusCode != 200 {
                    logger.warning("CopilotProvider: Usage API returned HTTP \(httpResponse.statusCode)")
                    return nil
                }
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.error("CopilotProvider: Failed to parse usage JSON")
                return nil
            }

            if let usage = parseUsageFromResponse(json) {
                logger.info("CopilotProvider: Usage data parsed - used: \(usage.usedRequests), limit: \(usage.limitRequests)")
                return usage
            }
        } catch {
            logger.error("CopilotProvider: Usage fetch error - \(error.localizedDescription)")
        }

        return nil
    }

    /// Parse CopilotUsage from API response dictionary
    /// - Parameter rootDict: Raw response from API
    /// - Returns: Parsed CopilotUsage or nil if parsing fails
    private func parseUsageFromResponse(_ rootDict: [String: Any]) -> CopilotUsage? {
        // Unwrap payload or data wrapper if present
        var dict = rootDict
        if let payload = rootDict["payload"] as? [String: Any] {
            dict = payload
        } else if let data = rootDict["data"] as? [String: Any] {
            dict = data
        }

        logger.info("CopilotProvider: Parsing data (Keys: \(dict.keys.joined(separator: ", ")))")

        // Extract values with fallback key names
        let netBilledAmount = parseDoubleValue(from: dict, keys: ["netBilledAmount", "net_billed_amount"])
        let netQuantity = parseDoubleValue(from: dict, keys: ["netQuantity", "net_quantity"])
        let discountQuantity = parseDoubleValue(from: dict, keys: ["discountQuantity", "discount_quantity"])
        let limit = parseIntValue(from: dict, keys: ["userPremiumRequestEntitlement", "user_premium_request_entitlement", "quantity"])
        let filteredLimit = parseIntValue(from: dict, keys: ["filteredUserPremiumRequestEntitlement"])

        return CopilotUsage(
            netBilledAmount: netBilledAmount,
            netQuantity: netQuantity,
            discountQuantity: discountQuantity,
            userPremiumRequestEntitlement: limit,
            filteredUserPremiumRequestEntitlement: filteredLimit
        )
    }

    /// Parse double value from dictionary with multiple possible keys
    private func parseDoubleValue(from dict: [String: Any], keys: [String]) -> Double {
        for key in keys {
            if let value = dict[key] as? Double {
                return value
            }
            if let value = dict[key] as? Int {
                return Double(value)
            }
            if let value = dict[key] as? NSNumber {
                return value.doubleValue
            }
        }
        return 0.0
    }

    /// Parse integer value from dictionary with multiple possible keys
    private func parseIntValue(from dict: [String: Any], keys: [String]) -> Int {
        for key in keys {
            if let value = dict[key] as? Int {
                return value
            }
            if let value = dict[key] as? Double {
                return Int(value)
            }
        }
        return 0
    }

    // MARK: - Caching

    /// Save usage data to UserDefaults cache
    private func saveCache(usage: CopilotUsage) {
        let cached = CachedUsage(usage: usage, timestamp: Date())
        if let encoded = try? JSONEncoder().encode(cached) {
            UserDefaults.standard.set(encoded, forKey: cacheKey)
            logger.info("CopilotProvider: Cache saved")
        }
    }

    /// Load cached usage data with email and convert to ProviderResult
    /// - Throws: ProviderError.providerError if no cache available
    private func loadCachedUsageWithEmail() throws -> ProviderResult {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode(CachedUsage.self, from: data) else {
            logger.error("CopilotProvider: No cached data available")
            throw ProviderError.providerError("No cached data available")
        }

        let usage = cached.usage
        let remaining = usage.limitRequests - usage.usedRequests

        logger.info("CopilotProvider: Using cached data from \(cached.timestamp)")

        let providerUsage = ProviderUsage.quotaBased(
            remaining: remaining,
            entitlement: usage.limitRequests,
            overagePermitted: true
        )
        return ProviderResult(
            usage: providerUsage,
            details: DetailedUsage(
                resetPeriod: formatResetDate(usage.quotaResetDateUTC),
                planType: usage.copilotPlan,
                email: cachedUserEmail,
                authSource: "Browser Cookies (Chrome/Brave/Arc/Edge)",
                copilotOverageCost: usage.netBilledAmount,
                copilotOverageRequests: usage.netQuantity,
                copilotUsedRequests: usage.usedRequests,
                copilotLimitRequests: usage.limitRequests,
                copilotQuotaResetDateUTC: usage.quotaResetDateUTC
            )
        )
    }
}
