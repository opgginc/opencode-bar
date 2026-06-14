import Foundation
import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "ZaiCodingPlanProvider")

private struct ZaiEnvelope<T: Decodable>: Decodable {
    let data: T?
}

private struct ZaiQuotaLimitResponse: Decodable {
    let limits: [ZaiQuotaLimitItem]?
}

private struct ZaiQuotaLimitItem: Decodable {
    let type: String
    let percentage: Double?
    let currentValue: Int?
    let total: Int?
    let nextResetTime: Int64?

    var computedPercentage: Double? {
        guard let currentValue = currentValue, let total = total, total > 0 else { return nil }
        return (Double(currentValue) / Double(total)) * 100
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case percentage
        case currentValue
        case total
        case nextResetTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? container.decode(String.self, forKey: .type)) ?? ""
        percentage = Self.decodeDouble(container, forKey: .percentage)
        currentValue = Self.decodeInt(container, forKey: .currentValue)
        total = Self.decodeInt(container, forKey: .total)
        nextResetTime = Self.decodeInt64(container, forKey: .nextResetTime)
    }

    private static func decodeDouble(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(value)
        }
        return nil
    }

    private static func decodeInt(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    private static func decodeInt64(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int64? {
        if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Int64(value)
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int64(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int64(value)
        }
        return nil
    }
}

private struct ZaiModelUsageResponse: Decodable {
    let totalUsage: ZaiModelUsageTotals?
}

private struct ZaiModelUsageTotals: Decodable {
    let totalTokensUsage: Int?
    let totalModelCallCount: Int?

    private enum CodingKeys: String, CodingKey {
        case totalTokensUsage
        case totalModelCallCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalTokensUsage = Self.decodeInt(container, forKey: .totalTokensUsage)
        totalModelCallCount = Self.decodeInt(container, forKey: .totalModelCallCount)
    }

    private static func decodeInt(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }
}

private struct ZaiToolUsageResponse: Decodable {
    let totalUsage: ZaiToolUsageTotals?
}

private struct ZaiToolUsageTotals: Decodable {
    let totalNetworkSearchCount: Int?
    let totalWebReadMcpCount: Int?
    let totalZreadMcpCount: Int?

    private enum CodingKeys: String, CodingKey {
        case totalNetworkSearchCount
        case totalWebReadMcpCount
        case totalZreadMcpCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalNetworkSearchCount = Self.decodeInt(container, forKey: .totalNetworkSearchCount)
        totalWebReadMcpCount = Self.decodeInt(container, forKey: .totalWebReadMcpCount)
        totalZreadMcpCount = Self.decodeInt(container, forKey: .totalZreadMcpCount)
    }

    private static func decodeInt(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }
}

final class ZaiCodingPlanProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .zaiCodingPlan
    let type: ProviderType = .quotaBased
    let fetchTimeout: TimeInterval = 30.0

    private let tokenManager: TokenManager
    private let session: URLSession

    init(tokenManager: TokenManager = .shared, session: URLSession = .shared) {
        self.tokenManager = tokenManager
        self.session = session
    }

    func fetch() async throws -> ProviderResult {
        logger.info("Z.AI Coding Plan fetch started")

        guard let apiKey = tokenManager.getZaiCodingPlanAPIKey() else {
            logger.error("Z.AI Coding Plan API key not found")
            throw ProviderError.authenticationFailed("Z.AI Coding Plan API key not available")
        }

        let quotaResponse = try await fetchQuotaLimits(apiKey: apiKey)
        guard let limits = quotaResponse.limits, !limits.isEmpty else {
            logger.error("Z.AI Coding Plan quota response missing limits")
            throw ProviderError.decodingError("Missing quota limits")
        }

        let tokenLimit = limits.first { $0.type.uppercased() == "TOKENS_LIMIT" }
        let mcpLimit = limits.first { $0.type.uppercased() == "TIME_LIMIT" }

        let tokenUsagePercent = tokenLimit?.percentage ?? tokenLimit?.computedPercentage
        let mcpUsagePercent = mcpLimit?.percentage ?? mcpLimit?.computedPercentage

        guard tokenUsagePercent != nil || mcpUsagePercent != nil else {
            logger.error("Z.AI Coding Plan quota limits missing percentage values")
            throw ProviderError.decodingError("Missing usage percentages")
        }

        let overallUsed = max(tokenUsagePercent ?? 0, mcpUsagePercent ?? 0)
        let remainingPercent = Int((100.0 - overallUsed).rounded())

        let usage = ProviderUsage.quotaBased(
            remaining: remainingPercent,
            entitlement: 100,
            overagePermitted: false
        )

        let now = Date()
        let startDate = now.addingTimeInterval(-24 * 60 * 60)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        let startTimeStr = dateFormatter.string(from: startDate)
        let endTimeStr = dateFormatter.string(from: now)

        var modelUsageTotals: ZaiModelUsageTotals?
        do {
            let modelUsage = try await fetchModelUsage(apiKey: apiKey, startTime: startTimeStr, endTime: endTimeStr)
            modelUsageTotals = modelUsage.totalUsage
        } catch {
            logger.warning("Z.AI Coding Plan model usage fetch failed: \(error.localizedDescription)")
        }

        var toolUsageTotals: ZaiToolUsageTotals?
        do {
            let toolUsage = try await fetchToolUsage(apiKey: apiKey, startTime: startTimeStr, endTime: endTimeStr)
            toolUsageTotals = toolUsage.totalUsage
        } catch {
            logger.warning("Z.AI Coding Plan tool usage fetch failed: \(error.localizedDescription)")
        }

        let details = DetailedUsage(
            authSource: "~/.local/share/opencode/auth.json",
            tokenUsagePercent: tokenUsagePercent,
            tokenUsageReset: dateFromMilliseconds(tokenLimit?.nextResetTime),
            tokenUsageUsed: tokenLimit?.currentValue,
            tokenUsageTotal: tokenLimit?.total,
            mcpUsagePercent: mcpUsagePercent,
            mcpUsageReset: dateFromMilliseconds(mcpLimit?.nextResetTime),
            mcpUsageUsed: mcpLimit?.currentValue,
            mcpUsageTotal: mcpLimit?.total,
            modelUsageTokens: modelUsageTotals?.totalTokensUsage,
            modelUsageCalls: modelUsageTotals?.totalModelCallCount,
            toolNetworkSearchCount: toolUsageTotals?.totalNetworkSearchCount,
            toolWebReadCount: toolUsageTotals?.totalWebReadMcpCount,
            toolZreadCount: toolUsageTotals?.totalZreadMcpCount
        )

        logger.info("Z.AI Coding Plan usage fetched: tokens=\(tokenUsagePercent?.description ?? "n/a")% used, mcp=\(mcpUsagePercent?.description ?? "n/a")% used")
        return ProviderResult(usage: usage, details: details)
    }

    // MARK: - API Helpers

    private func fetchQuotaLimits(apiKey: String) async throws -> ZaiQuotaLimitResponse {
        let endpoint = "https://api.z.ai/api/monitor/usage/quota/limit"
        guard let url = URL(string: endpoint) else {
            throw ProviderError.networkError("Invalid Z.AI Coding Plan quota endpoint")
        }

        let data = try await fetchData(url: url, apiKey: apiKey)
        return try decodeResponse(ZaiQuotaLimitResponse.self, from: data)
    }

    private func fetchModelUsage(apiKey: String, startTime: String, endTime: String) async throws -> ZaiModelUsageResponse {
        guard var components = URLComponents(string: "https://api.z.ai/api/monitor/usage/model-usage") else {
            throw ProviderError.networkError("Invalid Z.AI Coding Plan model usage endpoint")
        }
        components.queryItems = [
            URLQueryItem(name: "startTime", value: startTime),
            URLQueryItem(name: "endTime", value: endTime)
        ]
        guard let url = components.url else {
            throw ProviderError.networkError("Invalid Z.AI Coding Plan model usage URL")
        }

        let data = try await fetchData(url: url, apiKey: apiKey)
        return try decodeResponse(ZaiModelUsageResponse.self, from: data)
    }

    private func fetchToolUsage(apiKey: String, startTime: String, endTime: String) async throws -> ZaiToolUsageResponse {
        guard var components = URLComponents(string: "https://api.z.ai/api/monitor/usage/tool-usage") else {
            throw ProviderError.networkError("Invalid Z.AI Coding Plan tool usage endpoint")
        }
        components.queryItems = [
            URLQueryItem(name: "startTime", value: startTime),
            URLQueryItem(name: "endTime", value: endTime)
        ]
        guard let url = components.url else {
            throw ProviderError.networkError("Invalid Z.AI Coding Plan tool usage URL")
        }

        let data = try await fetchData(url: url, apiKey: apiKey)
        return try decodeResponse(ZaiToolUsageResponse.self, from: data)
    }

    private func fetchData(url: URL, apiKey: String) async throws -> Data {
        let maxAttempts = 3
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await fetchDataOnce(url: url, apiKey: apiKey)
            } catch {
                lastError = error

                guard attempt < maxAttempts, isTransientNetworkError(error) else {
                    throw error
                }

                logger.warning("Z.AI Coding Plan request failed with transient error on attempt \(attempt)/\(maxAttempts): \(error.localizedDescription)")
                try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
            }
        }

        throw lastError ?? ProviderError.networkError("Z.AI Coding Plan request failed")
    }

    private func fetchDataOnce(url: URL, apiKey: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response type")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw ProviderError.authenticationFailed("Z.AI Coding Plan access token invalid or missing")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }

        return data
    }

    private func isTransientNetworkError(_ error: Error) -> Bool {
        if let providerError = error as? ProviderError {
            switch providerError {
            case .networkError(let message):
                return message.contains("HTTP 5") || message.localizedCaseInsensitiveContains("tls")
            default:
                return false
            }
        }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }

        switch nsError.code {
        case NSURLErrorNetworkConnectionLost,
             NSURLErrorTimedOut,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid:
            return true
        default:
            return false
        }
    }

    private func decodeResponse<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(ZaiEnvelope<T>.self, from: data), let payload = envelope.data {
            return payload
        }
        return try decoder.decode(T.self, from: data)
    }

    private func dateFromMilliseconds(_ value: Int64?) -> Date? {
        guard let value = value else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value) / 1000)
    }
}
