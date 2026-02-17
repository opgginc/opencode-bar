import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "CopilotCLIProvider")

/// CLI-compatible Copilot provider using TokenManager for multi-account token discovery
/// and browser cookies as a fallback source.
/// Mirrors CopilotProvider (GUI) logic: discovers accounts via OpenCode auth, Copilot CLI
/// Keychain, VS Code host/app files, and browser cookies, then deduplicates and merges.
actor CopilotCLIProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .copilot
    let type: ProviderType = .quotaBased

    private var cachedCustomerId: String?
    private var cachedUserEmail: String?

    // MARK: - Internal Types

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

    // MARK: - ProviderProtocol Implementation

    func fetch() async throws -> ProviderResult {
        logger.info("CopilotCLIProvider: Starting fetch")

        // 1. Discover token-based accounts via TokenManager
        let tokenAccounts = TokenManager.shared.getGitHubCopilotAccounts()
        var tokenInfos = await fetchTokenInfos(tokenAccounts)

        var candidates: [CopilotAccountCandidate] = []
        var cookieCandidate: CopilotAccountCandidate?

        // 2. Try browser cookies as an additional/fallback source
        let cookies: GitHubCookies?
        do {
            cookies = try BrowserCookieService.shared.getGitHubCookies()
            logger.info("CopilotCLIProvider: Cookies obtained successfully")
        } catch {
            logger.warning("CopilotCLIProvider: Failed to get cookies: \(error.localizedDescription)")
            cookies = nil
        }

        if let cookies = cookies, cookies.isValid {
            let cookieLogin = cookies.dotcomUser?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let login = cookieLogin, !login.isEmpty {
                cachedUserEmail = login
            }

            // Match cookie login against token infos to merge plan data
            let matchedToken = matchTokenInfo(login: cookieLogin, tokenInfos: &tokenInfos)
            let planInfo = matchedToken?.planInfo

            if let customerId = await fetchCustomerId(cookies: cookies) {
                logger.info("CopilotCLIProvider: Customer ID obtained - \(customerId)")

                if var usage = await fetchUsageData(customerId: customerId, cookies: cookies) {
                    // Merge plan info from token if available
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
                    }

                    // Fetch daily history (non-fatal if it fails)
                    var dailyHistory: [DailyUsage]?
                    do {
                        dailyHistory = try await CopilotHistoryService.shared.fetchHistory()
                        logger.info("CopilotCLIProvider: History fetched - \(dailyHistory?.count ?? 0) days")
                    } catch {
                        logger.warning("CopilotCLIProvider: Failed to fetch history (non-fatal): \(error.localizedDescription)")
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
                    logger.warning("CopilotCLIProvider: Failed to fetch usage data via cookies")
                }
            } else {
                logger.warning("CopilotCLIProvider: Failed to get customer ID from cookies")
            }
        } else {
            logger.info("CopilotCLIProvider: No valid browser cookies available")
        }

        // 3. Build candidates from remaining (unmatched) token infos
        for info in tokenInfos {
            if let tokenCandidate = buildCandidateFromToken(info) {
                candidates.append(tokenCandidate)
            }
        }

        if candidates.isEmpty {
            logger.error("CopilotCLIProvider: No usable Copilot data found from any source")
            throw ProviderError.authenticationFailed("No Copilot data available. Sign in via OpenCode auth, Copilot CLI, VS Code, or browser.")
        }

        return finalizeResult(candidates: candidates, cookieCandidate: cookieCandidate)
    }

    // MARK: - Token & Account Helpers

    private func sourcePriority(_ source: CopilotAuthSource?) -> Int {
        switch source {
        case .opencodeAuth:
            return 3
        case .copilotCliKeychain:
            return 2
        case .vscodeHosts:
            return 1
        case .vscodeApps:
            return 0
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
            logger.warning("CopilotCLIProvider: Failed to fetch user login: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Candidate Builders

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
        guard let limit = info.quotaLimit,
              let remaining = info.quotaRemaining,
              limit > 0 else {
            return nil
        }
        let used = max(0, limit - remaining)

        let providerUsage = ProviderUsage.quotaBased(
            remaining: max(0, remaining),
            entitlement: limit,
            overagePermitted: true
        )

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

    // MARK: - Result Finalization

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

        let usageCandidates = accountResults.compactMap { result -> (remaining: Int, entitlement: Int)? in
            guard let remaining = result.usage.remainingQuota,
                  let entitlement = result.usage.totalEntitlement,
                  entitlement > 0 else {
                return nil
            }
            return (remaining: remaining, entitlement: entitlement)
        }

        let aggregateUsage: ProviderUsage
        if let minCandidate = usageCandidates.min(by: { $0.remaining < $1.remaining }) {
            aggregateUsage = ProviderUsage.quotaBased(
                remaining: max(0, minCandidate.remaining),
                entitlement: max(0, minCandidate.entitlement),
                overagePermitted: true
            )
        } else {
            aggregateUsage = ProviderUsage.quotaBased(
                remaining: 0,
                entitlement: 0,
                overagePermitted: true
            )
        }

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

    // MARK: - Cookie-based Fetching (fallback)

    private func fetchCustomerId(cookies: GitHubCookies) async -> String? {
        if let cached = cachedCustomerId {
            return cached
        }

        guard let url = URL(string: "https://github.com/settings/billing") else { return nil }

        var request = URLRequest(url: url)
        request.setValue(cookies.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    logger.warning("CopilotCLIProvider: Billing page auth failed (HTTP \(httpResponse.statusCode))")
                    return nil
                }
            }

            guard let html = String(data: data, encoding: .utf8) else { return nil }

            let patterns = [
                #""customerId":\s*(\d+)"#,
                #""customerId&quot;:(\d+)"#,
                #"customer_id=(\d+)"#,
                #"customerId":(\d+)"#
            ]

            for pattern in patterns {
                if let customerId = extractCustomerIdWithPattern(pattern, from: html) {
                    cachedCustomerId = customerId
                    logger.info("CopilotCLIProvider: Billing page extraction successful - \(customerId)")
                    return customerId
                }
            }
        } catch {
            logger.error("CopilotCLIProvider: Billing page fetch error - \(error.localizedDescription)")
        }

        return nil
    }

    private func extractCustomerIdWithPattern(_ pattern: String, from html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[range])
    }

    private func fetchUsageData(customerId: String, cookies: GitHubCookies) async -> CopilotUsage? {
        let urlString = "https://github.com/settings/billing/copilot_usage_card?customer_id=\(customerId)&period=3"

        guard let url = URL(string: urlString) else {
            logger.error("CopilotCLIProvider: Invalid usage URL")
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
                    logger.warning("CopilotCLIProvider: Usage API auth failed (HTTP \(httpResponse.statusCode))")
                    return nil
                }

                if httpResponse.statusCode != 200 {
                    logger.warning("CopilotCLIProvider: Usage API returned HTTP \(httpResponse.statusCode)")
                    return nil
                }
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.error("CopilotCLIProvider: Failed to parse usage JSON")
                return nil
            }

            if let usage = parseUsageFromResponse(json) {
                logger.info("CopilotCLIProvider: Usage data parsed - used: \(usage.usedRequests), limit: \(usage.limitRequests)")
                return usage
            }
        } catch {
            logger.error("CopilotCLIProvider: Usage fetch error - \(error.localizedDescription)")
        }

        return nil
    }

    // MARK: - Response Parsing

    private func parseUsageFromResponse(_ rootDict: [String: Any]) -> CopilotUsage? {
        var dict = rootDict
        if let payload = rootDict["payload"] as? [String: Any] {
            dict = payload
        } else if let data = rootDict["data"] as? [String: Any] {
            dict = data
        }

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

    // MARK: - Helpers

    private func formatResetDate(_ date: Date?) -> String? {
        guard let date = date else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

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

    /// Extracts Int value from dictionary with multiple possible keys
    /// - Parameters:
    ///   - dict: Source dictionary
    ///   - keys: Array of possible key names to try
    /// - Returns: Extracted Int value or 0 if not found
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
}
