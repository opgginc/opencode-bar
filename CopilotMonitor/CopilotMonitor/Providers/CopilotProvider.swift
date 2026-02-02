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
    private var cachedUserEmail: String?
    private var cachedCustomerId: String?

    init() {
        logger.info("CopilotProvider: Initialized (cookie-based authentication)")
    }

    // MARK: - ProviderProtocol Implementation

    func fetch() async throws -> ProviderResult {
        let cookies: GitHubCookies
        do {
            cookies = try BrowserCookieService.shared.getGitHubCookies()
        } catch {
            logger.warning("CopilotProvider: Failed to get cookies: \(error.localizedDescription)")
            return try loadCachedUsageWithEmail()
        }

        guard cookies.isValid else {
            logger.warning("CopilotProvider: Invalid cookies, trying cache")
            return try loadCachedUsageWithEmail()
        }

        guard let customerId = await fetchCustomerId(cookies: cookies) else {
            logger.warning("CopilotProvider: Failed to get customer ID, trying cache")
            return try loadCachedUsageWithEmail()
        }

        logger.info("CopilotProvider: Customer ID obtained - \(customerId)")

        guard let usage = await fetchUsageData(customerId: customerId, cookies: cookies) else {
            logger.warning("CopilotProvider: Failed to fetch usage data, trying cache")
            return try loadCachedUsageWithEmail()
        }

        saveCache(usage: usage)

        let remaining = usage.limitRequests - usage.usedRequests

        logger.info("CopilotProvider: Fetch successful - used: \(usage.usedRequests), limit: \(usage.limitRequests), remaining: \(remaining)")

        // Fetch history via cookies (with graceful fallback)
        var dailyHistory: [DailyUsage]?
        do {
            dailyHistory = try await CopilotHistoryService.shared.fetchHistory()
            logger.info("CopilotProvider: History fetched successfully - \(dailyHistory?.count ?? 0) days")
        } catch {
            // Graceful fallback: history unavailable, but current usage still works
            logger.warning("CopilotProvider: Failed to fetch history: \(error.localizedDescription)")
        }

        let providerUsage = ProviderUsage.quotaBased(
            remaining: remaining,
            entitlement: usage.limitRequests,
            overagePermitted: true
        )
        return ProviderResult(
            usage: providerUsage,
            details: DetailedUsage(
                email: cachedUserEmail,
                dailyHistory: dailyHistory,
                authSource: "Browser Cookies (Chrome/Brave/Arc/Edge)",
                copilotOverageCost: usage.netBilledAmount,
                copilotOverageRequests: usage.netQuantity,
                copilotUsedRequests: usage.usedRequests,
                copilotLimitRequests: usage.limitRequests
            )
        )
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
                email: cachedUserEmail,
                authSource: "Browser Cookies (Chrome/Brave/Arc/Edge)"
            )
        )
    }
}
