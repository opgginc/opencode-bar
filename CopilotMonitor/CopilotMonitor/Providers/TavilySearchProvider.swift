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
    private let keySource: KeySource

    init(tokenManager: TokenManager = .shared,
         session: URLSession = .shared,
         keySource: KeySource = AIInfraYamlKeySource()) {
        self.tokenManager = tokenManager
        self.session = session
        self.keySource = keySource
    }

    struct TavilyParsedUsage {
        let keyName: String
        let used: Int
        let limit: Int
        let remaining: Int
        let planName: String?
        let usage: ProviderUsage
    }

    static func parseUsage(from data: Data, keyName: String) throws -> TavilyParsedUsage {
        let decoded: TavilyUsageResponse
        do {
            decoded = try JSONDecoder().decode(TavilyUsageResponse.self, from: data)
        } catch {
            throw ProviderError.decodingError("Invalid Tavily usage response")
        }
        let used = decoded.account?.planUsage ?? decoded.account?.paygoUsage ?? decoded.key?.usage
        let limit = decoded.account?.planLimit ?? decoded.account?.paygoLimit ?? decoded.key?.limit
        guard let resolvedUsed = used, let resolvedLimit = limit, resolvedLimit > 0 else {
            throw ProviderError.decodingError("Missing Tavily usage or limit")
        }
        let remaining = max(0, resolvedLimit - resolvedUsed)
        let usage = ProviderUsage.quotaBased(remaining: remaining, entitlement: resolvedLimit, overagePermitted: false)
        return TavilyParsedUsage(
            keyName: keyName,
            used: resolvedUsed,
            limit: resolvedLimit,
            remaining: remaining,
            planName: decoded.account?.currentPlan,
            usage: usage
        )
    }

    func fetch() async throws -> ProviderResult {
        let namedKeys = (try? keySource.keys(forProvider: "tavily")) ?? []

        var keysToQuery: [NamedKey] = namedKeys
        if keysToQuery.isEmpty, let single = tokenManager.getTavilyAPIKeyWithSource() {
            keysToQuery = [NamedKey(name: "default", value: single.key)]
        }
        guard !keysToQuery.isEmpty else {
            throw ProviderError.authenticationFailed("No Tavily API key available")
        }

        var accountResults: [ProviderAccountResult] = []
        var firstUsage: ProviderUsage?
        var firstDetails: DetailedUsage?

        for (index, namedKey) in keysToQuery.enumerated() {
            do {
                let parsed = try await fetchOne(key: namedKey)
                let resetText = formatEstimatedMonthlyResetText()
                let details = DetailedUsage(
                    monthlyUsage: Double(parsed.used),
                    limit: Double(parsed.limit),
                    limitRemaining: Double(parsed.remaining),
                    resetPeriod: resetText,
                    authSource: "ai-infra:tavily.\(namedKey.name)",
                    authUsageSummary: parsed.planName ?? "Auto refresh",
                    mcpUsagePercent: normalizedTavilyQuotaUsagePercent(used: parsed.used, limit: parsed.limit)
                )
                accountResults.append(ProviderAccountResult(
                    accountIndex: index,
                    accountId: namedKey.name,
                    usage: parsed.usage,
                    details: details
                ))
                if firstUsage == nil {
                    firstUsage = parsed.usage
                    firstDetails = details
                }
                tavilyLogger.info("Tavily[\(namedKey.name)]: used=\(parsed.used)/\(parsed.limit)")
            } catch {
                tavilyLogger.error("Tavily[\(namedKey.name)] fetch failed: \(error.localizedDescription)")
            }
        }

        guard let topUsage = firstUsage else {
            throw ProviderError.networkError("All Tavily keys failed")
        }
        return ProviderResult(usage: topUsage, details: firstDetails, accounts: accountResults)
    }

    private func fetchOne(key namedKey: NamedKey) async throws -> TavilyParsedUsage {
        guard let url = URL(string: "https://api.tavily.com/usage") else {
            throw ProviderError.networkError("Invalid Tavily usage endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let apiKey = namedKey.value
        let authValue = apiKey.lowercased().hasPrefix("bearer ") ? apiKey : "Bearer \(apiKey)"
        request.setValue(authValue, forHTTPHeaderField: "Authorization")
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
        return try Self.parseUsage(from: data, keyName: namedKey.name)
    }

    private func formatEstimatedMonthlyResetText(referenceDate: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: referenceDate)) ?? referenceDate
        let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: startOfMonth) ?? referenceDate

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm z"
        formatter.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        return "Resets: \(formatter.string(from: nextMonthStart)) (estimated monthly)"
    }
}
