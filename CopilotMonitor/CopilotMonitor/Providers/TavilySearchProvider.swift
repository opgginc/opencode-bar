import Foundation
import os.log

private let tavilyLogger = Logger(subsystem: "com.opencodeproviders", category: "TavilySearchProvider")

private struct TavilyUsageResponse: Decodable {
    struct Account: Decodable {
        let currentPlan: String?
        let planUsage: Int?
        let planLimit: Int?
        let paygoUsage: Int?
        let paygoLimit: Int?

        enum CodingKeys: String, CodingKey {
            case currentPlan = "current_plan"
            case planUsage = "plan_usage"
            case planLimit = "plan_limit"
            case paygoUsage = "paygo_usage"
            case paygoLimit = "paygo_limit"
        }
    }

    struct KeyUsage: Decodable {
        let usage: Int?
        let limit: Int?
    }

    let account: Account?
    let key: KeyUsage?
}

private func normalizedTavilyQuotaUsagePercent(used: Int, limit: Int) -> Double? {
    guard limit > 0 else { return nil }
    let percent = (Double(used) / Double(limit)) * 100.0
    return min(max(percent, 0), 100)
}

final class TavilySearchProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .tavilySearch
    let type: ProviderType = .quotaBased

    private let tokenManager: TokenManager
    private let session: URLSession

    init(tokenManager: TokenManager = .shared, session: URLSession = .shared) {
        self.tokenManager = tokenManager
        self.session = session
    }

    func fetch() async throws -> ProviderResult {
        guard let apiKey = tokenManager.getTavilyAPIKey() else {
            tavilyLogger.error("Tavily API key not found")
            throw ProviderError.authenticationFailed("Tavily API key not available")
        }

        guard let url = URL(string: "https://api.tavily.com/usage") else {
            throw ProviderError.networkError("Invalid Tavily usage endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid Tavily response type")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw ProviderError.authenticationFailed("Invalid Tavily API key")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }

        let decoded: TavilyUsageResponse
        do {
            decoded = try JSONDecoder().decode(TavilyUsageResponse.self, from: data)
        } catch {
            throw ProviderError.decodingError("Invalid Tavily usage response")
        }

        let used = decoded.account?.planUsage ?? decoded.key?.usage
        let limit = decoded.account?.planLimit ?? decoded.key?.limit

        guard let resolvedUsed = used, let resolvedLimit = limit, resolvedLimit > 0 else {
            throw ProviderError.decodingError("Missing Tavily usage or limit")
        }

        let remaining = max(0, resolvedLimit - resolvedUsed)
        let usage = ProviderUsage.quotaBased(remaining: remaining, entitlement: resolvedLimit, overagePermitted: false)
        let mcpUsagePercent = normalizedTavilyQuotaUsagePercent(used: resolvedUsed, limit: resolvedLimit)

        let authSource = tokenManager.lastFoundOpenCodeConfigPath?.path ?? "~/.config/opencode/opencode.json"
        let resetText = formatEstimatedMonthlyResetText()
        let details = DetailedUsage(
            monthlyUsage: Double(resolvedUsed),
            limit: Double(resolvedLimit),
            limitRemaining: Double(remaining),
            resetPeriod: resetText,
            authSource: authSource,
            authUsageSummary: decoded.account?.currentPlan ?? "Auto refresh",
            mcpUsagePercent: mcpUsagePercent
        )

        let percentLogValue = mcpUsagePercent.map { String(format: "%.2f", $0) } ?? "nil"
        tavilyLogger.info("Tavily usage fetched: used=\(resolvedUsed), limit=\(resolvedLimit), usedPercent=\(percentLogValue)")
        return ProviderResult(usage: usage, details: details)
    }

    private func formatEstimatedMonthlyResetText(referenceDate: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: referenceDate)) ?? referenceDate
        let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: startOfMonth) ?? referenceDate

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm z"
        formatter.timeZone = TimeZone.current

        return "Resets: \(formatter.string(from: nextMonthStart)) (estimated monthly)"
    }
}
