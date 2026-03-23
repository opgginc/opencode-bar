import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "ChutesProvider")

// MARK: - Chutes API Response Models

struct ChutesUserProfile: Codable {
    let userId: String
    let username: String
    let paymentAddress: String?
    let imageCount: Int?
    let chuteCount: Int?
    let balance: Double

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case username
        case paymentAddress = "payment_address"
        case imageCount = "image_count"
        case chuteCount = "chute_count"
        case balance
    }
}

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
/// Uses quota-based model with short-window daily limits and monthly 5× value cap tracking.
/// Combines data from /users/me, /users/me/quotas, /users/me/quota_usage/*, and /users/{user_id}/usage.
final class ChutesProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .chutes
    let type: ProviderType = .quotaBased

    private let tokenManager: TokenManager
    private let session: URLSession

    static let monthlyValueMultiplier = 5.0

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

        async let userProfileTask = fetchUserProfile(apiKey: apiKey)
        let quotaItems = try await fetchQuotas(apiKey: apiKey)

        guard let quotaItem = quotaItems.first(where: { $0.isDefault }) ?? quotaItems.first else {
            logger.error("No quota information found in Chutes response")
            throw ProviderError.decodingError("No quota data available")
        }

        logger.debug("Using Chutes quota_usage for chute_id: \(quotaItem.chuteId, privacy: .public)")

        let usage = try await fetchQuotaUsage(apiKey: apiKey, chuteId: quotaItem.chuteId)
        let userProfile = try await userProfileTask

        let quota = quotaItem.quota
        let used = usage.used
        let remaining = max(0, quota - used)
        let dailyUsedPercent = quota > 0 ? min((Double(used) / Double(quota)) * 100.0, 999.0) : 0

        let planTier = Self.getPlanTier(from: quota)
        let monthlySubscriptionCost = Self.inferredMonthlySubscriptionCost(planTier: planTier)
        let monthlyValueCapUSD = monthlySubscriptionCost.map { $0 * Self.monthlyValueMultiplier }
        let monthlyValueUsedUSD = await resolveMonthlyValueUsedUSD(
            apiKey: apiKey,
            userId: userProfile.userId,
            monthlyValueCapUSD: monthlyValueCapUSD,
            balance: userProfile.balance
        )
        let monthlyValueUsedPercent = Self.calculateMonthlyValueUsedPercent(
            usedUSD: monthlyValueUsedUSD,
            capUSD: monthlyValueCapUSD
        )
        let representativeUsedPercent = monthlyValueUsedPercent ?? dailyUsedPercent
        let remainingPercentage = max(0, 100 - Int(representativeUsedPercent.rounded()))

        logger.info(
            "Chutes fetched: \(used)/\(quota) daily requests used (\(Int(dailyUsedPercent.rounded()))%), tier: \(planTier), monthly cap: \(monthlyValueCapUSD ?? 0), monthly value used: \(monthlyValueUsedUSD ?? -1), balance: \(userProfile.balance)"
        )

        let providerUsage = ProviderUsage.quotaBased(
            remaining: remainingPercentage,
            entitlement: 100,
            overagePermitted: true
        )

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
            creditsBalance: userProfile.balance,
            planType: planTier,
            chutesMonthlyValueCapUSD: monthlyValueCapUSD,
            chutesMonthlyValueUsedUSD: monthlyValueUsedUSD,
            chutesMonthlyValueUsedPercent: monthlyValueUsedPercent,
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

    /// Fetches usage from /users/me/quota_usage/{chute_id}
    private func fetchQuotaUsage(apiKey: String, chuteId: String) async throws -> ChutesQuotaUsage {
        let encodedChuteId = chuteId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? chuteId
        guard let url = URL(string: "https://api.chutes.ai/users/me/quota_usage/\(encodedChuteId)") else {
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

    private func fetchUserProfile(apiKey: String) async throws -> ChutesUserProfile {
        guard let url = URL(string: "https://api.chutes.ai/users/me") else {
            throw ProviderError.networkError("Invalid users/me URL")
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
            return try JSONDecoder().decode(ChutesUserProfile.self, from: data)
        } catch {
            logger.error("Failed to decode user profile: \(error.localizedDescription)")
            throw ProviderError.decodingError("Invalid user profile format")
        }
    }

    private func fetchMonthlyUsageSummary(apiKey: String, userId: String, startDate: String, endDate: String) async throws -> Any {
        let encodedUserId = userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userId
        var components = URLComponents(string: "https://api.chutes.ai/users/\(encodedUserId)/usage")
        components?.queryItems = [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "limit", value: "500"),
            URLQueryItem(name: "start_date", value: startDate),
            URLQueryItem(name: "end_date", value: endDate)
        ]

        guard let url = components?.url else {
            throw ProviderError.networkError("Invalid usage summary URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid usage summary response type")
        }

        if httpResponse.statusCode == 401 {
            throw ProviderError.authenticationFailed("API key invalid")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw ProviderError.networkError("Usage summary HTTP \(httpResponse.statusCode)")
        }

        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            logger.error("Failed to decode Chutes usage summary JSON: \(error.localizedDescription)")
            throw ProviderError.decodingError("Invalid usage summary format")
        }
    }

    private func resolveMonthlyValueUsedUSD(
        apiKey: String,
        userId: String,
        monthlyValueCapUSD: Double?,
        balance: Double
    ) async -> Double? {
        guard let monthlyValueCapUSD, monthlyValueCapUSD > 0 else {
            return nil
        }

        do {
            let (startDate, endDate) = Self.currentMonthDateRangeStrings()
            let usageSummary = try await fetchMonthlyUsageSummary(
                apiKey: apiKey,
                userId: userId,
                startDate: startDate,
                endDate: endDate
            )

            if let extractedValue = Self.extractMonthlyValueUsedUSD(from: usageSummary) {
                logger.debug("Using Chutes usage endpoint for monthly value used: \(extractedValue, privacy: .public)")
                return max(0, extractedValue)
            }

            logger.warning("Chutes usage summary did not expose a recognized monthly USD field")
        } catch {
            logger.warning("Failed to load Chutes monthly usage summary: \(error.localizedDescription, privacy: .public)")
        }

        if balance >= 0, balance <= monthlyValueCapUSD {
            let inferredUsed = max(0, monthlyValueCapUSD - balance)
            logger.debug(
                "Using Chutes balance fallback for monthly value used: cap=\(monthlyValueCapUSD, privacy: .public), balance=\(balance, privacy: .public), used=\(inferredUsed, privacy: .public)"
            )
            return inferredUsed
        }

        return nil
    }

    private static func getPlanTier(from quota: Int) -> String {
        switch quota {
        case 300:
            return "Base"
        case 2000:
            return "Plus"
        case 5000:
            return "Pro"
        default:
            return "\(quota)/day"
        }
    }

    static func inferredMonthlySubscriptionCost(planTier: String) -> Double? {
        switch planTier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "base":
            return 3
        case "plus":
            return 10
        case "pro":
            return 20
        default:
            return nil
        }
    }

    static func calculateMonthlyValueUsedPercent(usedUSD: Double?, capUSD: Double?) -> Double? {
        guard let usedUSD, let capUSD, capUSD > 0 else { return nil }
        return min(max((usedUSD / capUSD) * 100.0, 0), 999)
    }

    static func extractMonthlyValueUsedUSD(from json: Any) -> Double? {
        if let dictionary = json as? [String: Any] {
            if let aggregate = numericValue(
                forAnyOf: [
                    "total_cost_usd", "total_cost", "cost_usd", "cost",
                    "paygo_equivalent_usd", "paygo_equivalent",
                    "amount_usd", "billable_usd", "value_received_usd"
                ],
                in: dictionary
            ) {
                return aggregate
            }

            for key in ["summary", "totals", "aggregate", "aggregates", "usage_summary", "result"] {
                if let nested = dictionary[key], let value = extractMonthlyValueUsedUSD(from: nested) {
                    return value
                }
            }

            for key in ["items", "results", "data", "usage", "rows", "entries"] {
                if let array = dictionary[key] as? [Any], let value = sumMonthlyValueUsedUSD(in: array) {
                    return value
                }
            }

            return nil
        }

        if let array = json as? [Any] {
            return sumMonthlyValueUsedUSD(in: array)
        }

        return nil
    }

    private static func sumMonthlyValueUsedUSD(in array: [Any]) -> Double? {
        var total: Double = 0
        var found = false

        for element in array {
            guard let dictionary = element as? [String: Any] else { continue }
            if let value = numericValue(
                forAnyOf: [
                    "total_cost_usd", "total_cost", "cost_usd", "cost",
                    "paygo_equivalent_usd", "paygo_equivalent",
                    "amount_usd", "billable_usd", "value_received_usd"
                ],
                in: dictionary
            ) {
                total += value
                found = true
            }
        }

        return found ? total : nil
    }

    private static func numericValue(forAnyOf keys: [String], in dictionary: [String: Any]) -> Double? {
        for key in keys {
            if let value = numericValue(from: dictionary[key]) {
                return value
            }
        }
        return nil
    }

    private static func numericValue(from value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    static func currentMonthDateRangeStrings(referenceDate: Date = Date()) -> (String, String) {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: referenceDate)) ?? referenceDate
        return (formatter.string(from: startOfMonth), formatter.string(from: referenceDate))
    }

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
