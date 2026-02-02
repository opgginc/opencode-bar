import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "CopilotCLIProvider")

/// CLI-compatible Copilot provider using HTTP requests with browser cookies
/// Avoids WebView dependency by using URLSession with extracted cookies
actor CopilotCLIProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .copilot
    let type: ProviderType = .quotaBased
    
    private var cachedCustomerId: String?
    
    // MARK: - ProviderProtocol Implementation
    
    /// Fetches Copilot usage data using HTTP requests with browser cookies
    /// - Returns: ProviderResult with quota-based usage and daily history
    /// - Throws: ProviderError if cookies unavailable or fetch fails
    func fetch() async throws -> ProviderResult {
        logger.info("CopilotCLIProvider: Starting fetch")
        
        // Get GitHub cookies from browser
        let cookies: GitHubCookies
        do {
            cookies = try BrowserCookieService.shared.getGitHubCookies()
            logger.info("CopilotCLIProvider: Cookies obtained successfully")
        } catch {
            logger.error("CopilotCLIProvider: Failed to get cookies - \(error.localizedDescription)")
            throw ProviderError.authenticationFailed("No GitHub cookies found. Please sign in to GitHub in Chrome/Brave/Arc/Edge.")
        }
        
        // Fetch customer ID
        let customerId: String
        do {
            customerId = try await fetchCustomerId(cookies: cookies)
            logger.info("CopilotCLIProvider: Customer ID obtained - \(customerId)")
        } catch {
            logger.error("CopilotCLIProvider: Failed to get customer ID - \(error.localizedDescription)")
            throw ProviderError.providerError("Failed to fetch customer ID: \(error.localizedDescription)")
        }
        
        // Fetch usage data
        let usage: CopilotUsage
        do {
            usage = try await fetchUsageData(customerId: customerId, cookies: cookies)
            logger.info("CopilotCLIProvider: Usage data fetched - used: \(usage.usedRequests), limit: \(usage.limitRequests)")
        } catch {
            logger.error("CopilotCLIProvider: Failed to fetch usage - \(error.localizedDescription)")
            throw ProviderError.networkError("Failed to fetch usage data: \(error.localizedDescription)")
        }
        
        // Fetch daily history (with graceful fallback)
        var dailyHistory: [DailyUsage]?
        do {
            dailyHistory = try await CopilotHistoryService.shared.fetchHistory()
            logger.info("CopilotCLIProvider: History fetched - \(dailyHistory?.count ?? 0) days")
        } catch {
            logger.warning("CopilotCLIProvider: Failed to fetch history (non-fatal): \(error.localizedDescription)")
        }
        
        let remaining = usage.limitRequests - usage.usedRequests
        
        let providerUsage = ProviderUsage.quotaBased(
            remaining: remaining,
            entitlement: usage.limitRequests,
            overagePermitted: true
        )
        
        return ProviderResult(
            usage: providerUsage,
            details: DetailedUsage(
                dailyHistory: dailyHistory,
                authSource: "Browser Cookies (Chrome/Brave/Arc/Edge)"
            )
        )
    }
    
    // MARK: - Customer ID Extraction
    
    /// Fetches customer_id from GitHub billing page HTML
    /// Uses cached value if available
    /// - Parameter cookies: Valid GitHub cookies
    /// - Returns: Customer ID string
    /// - Throws: ProviderError if extraction fails
    private func fetchCustomerId(cookies: GitHubCookies) async throws -> String {
        if let cached = cachedCustomerId {
            return cached
        }
        
        guard let url = URL(string: "https://github.com/settings/billing") else {
            throw ProviderError.providerError("Invalid billing URL")
        }
        
        var request = URLRequest(url: url)
        request.setValue(cookies.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                logger.error("CopilotCLIProvider: Session expired or invalid (HTTP \(httpResponse.statusCode))")
                throw ProviderError.authenticationFailed("GitHub session expired. Please sign in again.")
            }
        }
        
        guard let html = String(data: data, encoding: .utf8) else {
            logger.error("CopilotCLIProvider: Failed to decode billing page HTML")
            throw ProviderError.decodingError("Failed to decode billing page")
        }
        
        // Try multiple regex patterns for robustness (different HTML encodings)
        let patterns = [
            #""customerId":\s*(\d+)"#,      // JSON in script
            #""customerId&quot;:(\d+)"#,    // HTML-encoded JSON
            #"customer_id=(\d+)"#,          // URL parameter
            #"customerId":(\d+)"#           // Without quotes
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let customerId = String(html[range])
                cachedCustomerId = customerId
                return customerId
            }
        }
        
        logger.error("CopilotCLIProvider: Could not find customer ID in billing page")
        throw ProviderError.decodingError("Customer ID not found in billing page")
    }
    
    // MARK: - Usage Data Fetching
    
    /// Fetches usage data from GitHub Copilot API
    /// - Parameters:
    ///   - customerId: GitHub customer ID
    ///   - cookies: Valid GitHub cookies
    /// - Returns: Parsed CopilotUsage
    /// - Throws: ProviderError if fetch or parsing fails
    private func fetchUsageData(customerId: String, cookies: GitHubCookies) async throws -> CopilotUsage {
        let urlString = "https://github.com/settings/billing/copilot_usage_card?customer_id=\(customerId)&period=3"
        
        guard let url = URL(string: urlString) else {
            throw ProviderError.providerError("Invalid usage API URL")
        }
        
        var request = URLRequest(url: url)
        request.setValue(cookies.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                logger.error("CopilotCLIProvider: Session expired during usage fetch (HTTP \(httpResponse.statusCode))")
                throw ProviderError.authenticationFailed("GitHub session expired")
            }
            
            if httpResponse.statusCode != 200 {
                logger.error("CopilotCLIProvider: Unexpected status code: \(httpResponse.statusCode)")
                throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
            }
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("CopilotCLIProvider: Failed to parse JSON response")
            throw ProviderError.decodingError("Invalid JSON response")
        }
        
        return try parseUsageFromResponse(json)
    }
    
    // MARK: - Response Parsing
    
    /// Parses CopilotUsage from API response dictionary
    /// - Parameter rootDict: Raw response from API
    /// - Returns: Parsed CopilotUsage
    /// - Throws: ProviderError if required fields missing
    private func parseUsageFromResponse(_ rootDict: [String: Any]) throws -> CopilotUsage {
        // Unwrap payload or data wrapper if present
        var dict = rootDict
        if let payload = rootDict["payload"] as? [String: Any] {
            dict = payload
        } else if let data = rootDict["data"] as? [String: Any] {
            dict = data
        }
        
        logger.info("CopilotCLIProvider: Parsing data (Keys: \(dict.keys.joined(separator: ", ")))")
        
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
    
    // MARK: - Helper Methods
    
    /// Extracts Double value from dictionary with multiple possible keys
    /// - Parameters:
    ///   - dict: Source dictionary
    ///   - keys: Array of possible key names to try
    /// - Returns: Extracted Double value or 0.0 if not found
    private func parseDoubleValue(from dict: [String: Any], keys: [String]) -> Double {
        for key in keys {
            if let value = dict[key] as? Double {
                return value
            }
            if let value = dict[key] as? Int {
                return Double(value)
            }
            if let value = dict[key] as? String, let doubleValue = Double(value) {
                return doubleValue
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
            if let value = dict[key] as? String, let intValue = Int(value) {
                return intValue
            }
        }
        return 0
    }
}

// MARK: - Supporting Types

/// Represents Copilot usage data from GitHub API
struct CopilotUsage {
    let netBilledAmount: Double
    let netQuantity: Double
    let discountQuantity: Double
    let userPremiumRequestEntitlement: Int
    let filteredUserPremiumRequestEntitlement: Int
    
    /// Total requests used (billed + discounted)
    var usedRequests: Int {
        return Int(netQuantity + discountQuantity)
    }
    
    /// Monthly request limit
    var limitRequests: Int {
        return filteredUserPremiumRequestEntitlement > 0
            ? filteredUserPremiumRequestEntitlement
            : userPremiumRequestEntitlement
    }
}
