import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "ChutesProvider")

// MARK: - Chutes API Response Models

/// Response from /users/me/quotas endpoint (returns array)
struct ChutesQuotaItem: Codable {
    let updatedAt: String
    let userId: String
    let chuteId: String
    let isDefault: Bool
    let paymentRefreshDate: String?
    let quota: Int

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case userId = "user_id"
        case chuteId = "chute_id"
        case isDefault = "is_default"
        case paymentRefreshDate = "payment_refresh_date"
        case quota
    }
}

/// Response from /users/me/quota_usage/{chute_id} endpoint
struct ChutesQuotaUsage: Codable {
    let quota: Int
    let used: Int
}

// MARK: - ChutesProvider Implementation

/// Provider for Chutes AI API usage tracking
/// Uses quota-based model with daily limits (300/2000/5000 per day)
/// Combines data from /users/me/quotas and /users/me/quota_usage/* endpoints
final class ChutesProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .chutes
    let type: ProviderType = .quotaBased

    private let tokenManager: TokenManager
    private let session: URLSession

    init(tokenManager: TokenManager = .shared, session: URLSession = .shared) {
        self.tokenManager = tokenManager
        self.session = session
    }

    // MARK: - ProviderProtocol Implementation

    /// Fetches Chutes quota usage from both API endpoints
    /// 1. Gets quota info from /users/me/quotas
    /// 2. Gets usage from /users/me/quota_usage/*
    /// - Returns: ProviderResult with combined quota and usage data
    /// - Throws: ProviderError if fetch fails
    func fetch() async throws -> ProviderResult {
        guard let apiKey = tokenManager.getChutesAPIKey() else {
            logger.error("Chutes API key not found")
            throw ProviderError.authenticationFailed("Chutes API key not available")
        }

        // Fetch both endpoints in parallel
        async let quotasTask = fetchQuotas(apiKey: apiKey)
        async let usageTask = fetchQuotaUsage(apiKey: apiKey)

        let quotaItems = try await quotasTask
        let usage = try await usageTask

        // Find the default quota (is_default: true) or first item
        guard let quotaItem = quotaItems.first(where: { $0.isDefault }) ?? quotaItems.first else {
            logger.error("No quota information found in Chutes response")
            throw ProviderError.decodingError("No quota data available")
        }

        let quota = quotaItem.quota
        let used = usage.used
        let remaining = max(0, quota - used)
        let remainingPercentage = Int((Double(remaining) / Double(quota)) * 100)

        logger.info("Chutes usage fetched: \(used)/\(quota) used, \(remaining) remaining (\(remainingPercentage)%)")

        let providerUsage = ProviderUsage.quotaBased(
            remaining: remainingPercentage,
            entitlement: 100,
            overagePermitted: false
        )

        // Parse payment refresh date if available
        let resetPeriod: String
        if let paymentDate = quotaItem.paymentRefreshDate,
           let date = Self.parseISO8601Date(paymentDate) {
            resetPeriod = Self.formatResetTime(date)
        } else {
            resetPeriod = Self.formatResetTime(Self.calculateNextUTCReset())
        }

        let details = DetailedUsage(
            dailyUsage: Double(used),
            limit: Double(quota),
            limitRemaining: Double(remaining),
            resetPeriod: resetPeriod,
            planType: "\(quota)/day",
            authSource: tokenManager.lastFoundAuthPath?.path ?? "~/.local/share/opencode/auth.json"
        )

        return ProviderResult(usage: providerUsage, details: details)
    }

    // MARK: - Private Helpers

    /// Fetches quota information from /users/me/quotas
    private func fetchQuotas(apiKey: String) async throws -> [ChutesQuotaItem] {
        guard let url = URL(string: "https://api.chutes.ai/users/me/quotas") else {
            throw ProviderError.networkError("Invalid quotas URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response type")
        }

        if httpResponse.statusCode == 401 {
            throw ProviderError.authenticationFailed("API key invalid")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }

        do {
            return try JSONDecoder().decode([ChutesQuotaItem].self, from: data)
        } catch {
            logger.error("Failed to decode quotas: \(error.localizedDescription)")
            throw ProviderError.decodingError("Invalid quotas format")
        }
    }

    /// Fetches usage from /users/me/quota_usage/*
    private func fetchQuotaUsage(apiKey: String) async throws -> ChutesQuotaUsage {
        guard let url = URL(string: "https://api.chutes.ai/users/me/quota_usage/*") else {
            throw ProviderError.networkError("Invalid quota_usage URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response type")
        }

        if httpResponse.statusCode == 401 {
            throw ProviderError.authenticationFailed("API key invalid")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }

        do {
            return try JSONDecoder().decode(ChutesQuotaUsage.self, from: data)
        } catch {
            logger.error("Failed to decode quota_usage: \(error.localizedDescription)")
            throw ProviderError.decodingError("Invalid quota_usage format")
        }
    }

    /// Parses ISO8601 date string
    private static func parseISO8601Date(_ string: String) -> Date? {
        let formatterWithFrac = ISO8601DateFormatter()
        formatterWithFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatterWithFrac.date(from: string) {
            return date
        }

        let formatterWithoutFrac = ISO8601DateFormatter()
        formatterWithoutFrac.formatOptions = [.withInternetDateTime]
        return formatterWithoutFrac.date(from: string)
    }

    /// Calculates the next 00:00 UTC reset time
    private static func calculateNextUTCReset() -> Date {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current

        let now = Date()
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 0
        components.minute = 0
        components.second = 0

        guard let todayMidnight = calendar.date(from: components) else {
            return now.addingTimeInterval(24 * 60 * 60)
        }

        if now > todayMidnight {
            return calendar.date(byAdding: .day, value: 1, to: todayMidnight) ?? now.addingTimeInterval(24 * 60 * 60)
        }

        return todayMidnight
    }

    /// Formats reset time for display
    private static func formatResetTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
