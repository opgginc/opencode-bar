import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "KimiCNProvider")

final class KimiCNProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .kimiCN
    let type: ProviderType = .quotaBased

    private let tokenManager: TokenManager
    private let session: URLSession

    init(tokenManager: TokenManager = .shared, session: URLSession = .shared) {
        self.tokenManager = tokenManager
        self.session = session
    }

    func fetch() async throws -> ProviderResult {
        guard let apiKey = tokenManager.getKimiCNAPIKey() else {
            logger.error("Kimi CN API key not found")
            throw ProviderError.authenticationFailed("Kimi CN API key not available")
        }

        return try await fetchKimiUsage(
            apiKey: apiKey,
            identifier: identifier,
            logger: logger,
            session: session
        )
    }
}

func fetchKimiUsage(
    apiKey: String,
    identifier: ProviderIdentifier,
    logger: Logger,
    session: URLSession
) async throws -> ProviderResult {
    guard let url = URL(string: "https://api.kimi.com/coding/v1/usages") else {
        logger.error("Invalid Kimi API URL")
        throw ProviderError.networkError("Invalid API endpoint")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
        logger.error("Invalid response type from Kimi API")
        throw ProviderError.networkError("Invalid response type")
    }

    if httpResponse.statusCode == 401 {
        logger.warning("Kimi API returned 401 - token expired")
        throw ProviderError.authenticationFailed("Token expired or invalid")
    }

    guard (200...299).contains(httpResponse.statusCode) else {
        logger.error("Kimi API returned status \(httpResponse.statusCode)")
        throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
    }

    do {
        let decoder = JSONDecoder()
        let kimiResponse = try decoder.decode(KimiUsageResponse.self, from: data)

        guard let usage = kimiResponse.usage else {
            logger.error("Kimi API response missing usage")
            throw ProviderError.decodingError("Missing usage data")
        }

        let weeklyLimit = Int(usage.limit ?? "0") ?? 0
        let weeklyUsed: Int
        if let usedString = usage.used, !usedString.isEmpty, let parsed = Int(usedString) {
            weeklyUsed = max(0, parsed)
        } else {
            let weeklyRemaining = Int(usage.remaining ?? "0") ?? 0
            weeklyUsed = max(0, weeklyLimit - weeklyRemaining)
        }

        func parseISO8601Date(_ string: String) -> Date? {
            let formatterWithFrac = ISO8601DateFormatter()
            formatterWithFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatterWithFrac.date(from: string) {
                return date
            }
            let formatterWithoutFrac = ISO8601DateFormatter()
            formatterWithoutFrac.formatOptions = [.withInternetDateTime]
            return formatterWithoutFrac.date(from: string)
        }

        let weeklyReset = usage.resetTime.flatMap { parseISO8601Date($0) }

        var fiveHourUsage: Double?
        var fiveHourReset: Date?

        if let limits = kimiResponse.limits, !limits.isEmpty {
            let limit = limits[0]
            if let detail = limit.detail {
                let detailLimit = Double(detail.limit ?? "0") ?? 0
                let detailUsed: Double
                if let usedString = detail.used, !usedString.isEmpty, let parsed = Double(usedString) {
                    detailUsed = max(0, parsed)
                } else {
                    let detailRemaining = Double(detail.remaining ?? "0") ?? 0
                    detailUsed = max(0, detailLimit - detailRemaining)
                }
                if detailLimit > 0 {
                    fiveHourUsage = (detailUsed / detailLimit) * 100
                }
                fiveHourReset = detail.resetTime.flatMap { parseISO8601Date($0) }
            }
        }

        let weeklyUsagePercent = weeklyLimit > 0 ? (Double(weeklyUsed) / Double(weeklyLimit)) * 100 : 0
        let weeklyRemaining = Int(usage.remaining ?? "0") ?? 0
        let remainingPercent = weeklyLimit > 0 ? (Double(weeklyRemaining) / Double(weeklyLimit)) * 100 : 100

        logger.info("Kimi usage fetched: weekly=\(weeklyUsagePercent)% used, 5h=\(fiveHourUsage?.description ?? "N/A")% used")

        let providerUsage = ProviderUsage.quotaBased(
            remaining: Int(remainingPercent),
            entitlement: 100,
            overagePermitted: false
        )

        let membershipLevel = kimiResponse.user?.membership?.level
        let planType = KimiPlanMapper.presetName(
            for: membershipLevel,
            limit: usage.limit,
            region: kimiResponse.user?.region
        )

        let details = DetailedUsage(
            fiveHourUsage: fiveHourUsage,
            fiveHourReset: fiveHourReset,
            sevenDayUsage: weeklyUsagePercent,
            sevenDayReset: weeklyReset,
            planType: planType,
            email: kimiResponse.user?.userId,
            authSource: "~/.local/share/opencode/auth.json"
        )

        return ProviderResult(usage: providerUsage, details: details)
    } catch let error as DecodingError {
        logger.error("Failed to decode Kimi response: \(error.localizedDescription)")
        throw ProviderError.decodingError("Invalid response format: \(error.localizedDescription)")
    } catch {
        logger.error("Unexpected error parsing Kimi response: \(error.localizedDescription)")
        throw ProviderError.providerError("Failed to parse response: \(error.localizedDescription)")
    }
}
