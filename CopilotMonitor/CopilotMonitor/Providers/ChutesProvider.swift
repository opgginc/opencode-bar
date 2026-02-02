import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "ChutesProvider")

// MARK: - Chutes API Response Models

/// Response structure from Chutes quota API
struct ChutesQuotaResponse: Codable {
    let quota: Int?
    let used: Int?
    let remaining: Int?
    let resetAt: String?
    let tier: String?

    enum CodingKeys: String, CodingKey {
        case quota
        case used
        case remaining
        case resetAt = "reset_at"
        case tier
    }
}

// MARK: - ChutesProvider Implementation

/// Provider for Chutes AI API usage tracking
/// Uses quota-based model with daily limits (300/2000/5000 per day)
/// Resets at 00:00 UTC daily
final class ChutesProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .chutes
    let type: ProviderType = .quotaBased

    private let tokenManager: TokenManager
    private let session: URLSession

    /// Known quota tiers for Chutes
    private static let quotaTiers = [300, 2000, 5000]

    init(tokenManager: TokenManager = .shared, session: URLSession = .shared) {
        self.tokenManager = tokenManager
        self.session = session
    }

    // MARK: - ProviderProtocol Implementation

    /// Fetches Chutes quota usage from API
    /// - Returns: ProviderResult with remaining quota
    /// - Throws: ProviderError if fetch fails
    func fetch() async throws -> ProviderResult {
        // Get API key from TokenManager
        guard let apiKey = tokenManager.getChutesAPIKey() else {
            logger.error("Chutes API key not found")
            throw ProviderError.authenticationFailed("Chutes API key not available")
        }

        // Build request
        guard let url = URL(string: "https://api.chutes.ai/users/me/quotas") else {
            logger.error("Invalid Chutes API URL")
            throw ProviderError.networkError("Invalid API endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Execute request
        let (data, response) = try await session.data(for: request)

        // Check HTTP status
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type from Chutes API")
            throw ProviderError.networkError("Invalid response type")
        }

        // Handle authentication errors
        if httpResponse.statusCode == 401 {
            logger.warning("Chutes API returned 401 - API key invalid or expired")
            throw ProviderError.authenticationFailed("API key invalid or expired")
        }

        // Handle other HTTP errors
        guard (200...299).contains(httpResponse.statusCode) else {
            logger.error("Chutes API returned status \(httpResponse.statusCode)")
            throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }

        // Parse response
        do {
            let decoder = JSONDecoder()
            let quotaResponse = try decoder.decode(ChutesQuotaResponse.self, from: data)

            // Extract quota information
            let quota = quotaResponse.quota ?? 0
            let used = quotaResponse.used ?? 0
            let remaining = quotaResponse.remaining ?? max(0, quota - used)

            // Determine entitlement (total quota)
            let entitlement: Int
            if quota > 0 {
                entitlement = quota
            } else if let tier = quotaResponse.tier,
                      let tierQuota = Self.parseTierToQuota(tier) {
                entitlement = tierQuota
            } else {
                // Fallback: infer from remaining + used or default to highest tier
                entitlement = max(remaining + used, Self.quotaTiers.last ?? 5000)
            }

            // Calculate remaining percentage
            let remainingPercentage = entitlement > 0
                ? Int((Double(remaining) / Double(entitlement)) * 100)
                : 0

            // Parse reset time - defaults to next 00:00 UTC if not provided
            let resetDate: Date
            if let resetAtString = quotaResponse.resetAt {
                resetDate = Self.parseResetTime(resetAtString) ?? Self.calculateNextUTCReset()
            } else {
                resetDate = Self.calculateNextUTCReset()
            }

            logger.info("Chutes usage fetched: \(used)/\(entitlement) used, \(remainingPercentage)% remaining")

            let usage = ProviderUsage.quotaBased(
                remaining: remainingPercentage,
                entitlement: 100,
                overagePermitted: false
            )

            let details = DetailedUsage(
                dailyUsage: Double(used),
                limit: Double(entitlement),
                limitRemaining: Double(remaining),
                resetPeriod: Self.formatResetTime(resetDate),
                planType: quotaResponse.tier,
                authSource: tokenManager.lastFoundAuthPath?.path ?? "~/.local/share/opencode/auth.json"
            )

            return ProviderResult(usage: usage, details: details)
        } catch let error as DecodingError {
            logger.error("Failed to decode Chutes response: \(error.localizedDescription)")
            throw ProviderError.decodingError("Invalid response format: \(error.localizedDescription)")
        } catch {
            logger.error("Unexpected error parsing Chutes response: \(error.localizedDescription)")
            throw ProviderError.providerError("Failed to parse response: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    /// Parses tier string to quota amount
    /// - Parameter tier: Tier string (e.g., "300", "2000", "5000", "free", "pro", "enterprise")
    /// - Returns: Quota amount if recognized, nil otherwise
    private static func parseTierToQuota(_ tier: String) -> Int? {
        // Direct numeric tier
        if let numericQuota = Int(tier), quotaTiers.contains(numericQuota) {
            return numericQuota
        }

        // Named tiers
        switch tier.lowercased() {
        case "free", "basic":
            return 300
        case "pro", "standard":
            return 2000
        case "enterprise", "unlimited":
            return 5000
        default:
            return nil
        }
    }

    /// Parses reset time string to Date
    /// - Parameter resetString: ISO8601 date string or time string
    /// - Returns: Parsed date or nil if parsing fails
    private static func parseResetTime(_ resetString: String) -> Date? {
        // Try ISO8601 with fractional seconds first
        let formatterWithFrac = ISO8601DateFormatter()
        formatterWithFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatterWithFrac.date(from: resetString) {
            return date
        }

        // Try ISO8601 without fractional seconds
        let formatterWithoutFrac = ISO8601DateFormatter()
        formatterWithoutFrac.formatOptions = [.withInternetDateTime]
        if let date = formatterWithoutFrac.date(from: resetString) {
            return date
        }

        return nil
    }

    /// Calculates the next 00:00 UTC reset time
    /// - Returns: Date for next midnight UTC
    private static func calculateNextUTCReset() -> Date {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current

        let now = Date()
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 0
        components.minute = 0
        components.second = 0

        // Get start of today in UTC
        guard let todayMidnight = calendar.date(from: components) else {
            return now.addingTimeInterval(24 * 60 * 60) // Fallback: 24 hours from now
        }

        // If already past midnight, return next day's midnight
        if now > todayMidnight {
            return calendar.date(byAdding: .day, value: 1, to: todayMidnight) ?? now.addingTimeInterval(24 * 60 * 60)
        }

        return todayMidnight
    }

    /// Formats reset time for display
    /// - Parameter date: The reset date
    /// - Returns: Formatted string showing time until reset
    private static func formatResetTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
