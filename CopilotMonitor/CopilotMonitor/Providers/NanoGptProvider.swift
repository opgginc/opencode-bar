import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "NanoGptProvider")

private struct NanoGptSubscriptionUsageResponse: Decodable {
    struct Limits: Decodable {
        let daily: Int?
        let weeklyInputTokens: Int?
        let monthly: Int?

        private enum CodingKeys: String, CodingKey {
            case daily
            case weeklyInputTokens
            case weeklyInputTokensSnake = "weekly_input_tokens"
            case weekly
            case weeklyInputToken
            case weeklyInputTokenSnake = "weekly_input_token"
            case weeklyInputTokensLimit
            case weeklyInputTokensLimitSnake = "weekly_input_tokens_limit"
            case monthly
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            daily = NanoGptSubscriptionUsageResponse.decodeInt(container, forKey: .daily)
            weeklyInputTokens = NanoGptSubscriptionUsageResponse.decodeInt(
                container,
                forKeys: [
                    .weeklyInputTokens,
                    .weeklyInputTokensSnake,
                    .weekly,
                    .weeklyInputToken,
                    .weeklyInputTokenSnake,
                    .weeklyInputTokensLimit,
                    .weeklyInputTokensLimitSnake
                ]
            )
            monthly = NanoGptSubscriptionUsageResponse.decodeInt(container, forKey: .monthly)
        }
    }

    struct WindowUsage: Decodable {
        let used: Int?
        let remaining: Int?
        let percentUsed: Double?
        let resetAt: Int64?

        private enum CodingKeys: String, CodingKey {
            case used
            case usage
            case inputTokensUsed
            case inputTokensUsedSnake = "input_tokens_used"
            case usedTokens
            case usedTokensSnake = "used_tokens"
            case remaining
            case left
            case percentUsed
            case percentUsedSnake = "percent_used"
            case usagePercent
            case usagePercentSnake = "usage_percent"
            case resetAt
            case resetAtSnake = "reset_at"
            case nextResetAt
            case nextResetAtSnake = "next_reset_at"
        }

        init(used: Int?, remaining: Int?, percentUsed: Double?, resetAt: Int64?) {
            self.used = used
            self.remaining = remaining
            self.percentUsed = percentUsed
            self.resetAt = resetAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            used = NanoGptSubscriptionUsageResponse.decodeInt(
                container,
                forKeys: [.used, .usage, .inputTokensUsed, .inputTokensUsedSnake, .usedTokens, .usedTokensSnake]
            )
            remaining = NanoGptSubscriptionUsageResponse.decodeInt(container, forKeys: [.remaining, .left])
            percentUsed = NanoGptSubscriptionUsageResponse.decodeDouble(
                container,
                forKeys: [.percentUsed, .percentUsedSnake, .usagePercent, .usagePercentSnake]
            )
            resetAt = NanoGptSubscriptionUsageResponse.decodeInt64(
                container,
                forKeys: [.resetAt, .resetAtSnake, .nextResetAt, .nextResetAtSnake]
            )
        }
    }

    struct Period: Decodable {
        let currentPeriodEnd: String?
    }

    let active: Bool?
    let limits: Limits?
    let daily: WindowUsage?
    let weeklyInputTokens: WindowUsage?
    let monthly: WindowUsage?
    let period: Period?
    let state: String?
    let graceUntil: String?

    private enum CodingKeys: String, CodingKey {
        case active
        case limits
        case daily
        case weekly
        case weeklyInputTokens
        case weeklyInputTokensSnake = "weekly_input_tokens"
        case weeklyInputToken
        case weeklyInputTokenSnake = "weekly_input_token"
        case monthly
        case inputTokens
        case inputTokensSnake = "input_tokens"
        case weeklyInputTokensUsed
        case weeklyInputTokensUsedSnake = "weekly_input_tokens_used"
        case weeklyInputTokensRemaining
        case weeklyInputTokensRemainingSnake = "weekly_input_tokens_remaining"
        case weeklyInputTokensPercentUsed
        case weeklyInputTokensPercentUsedSnake = "weekly_input_tokens_percent_used"
        case weeklyInputTokensResetAt
        case weeklyInputTokensResetAtSnake = "weekly_input_tokens_reset_at"
        case period
        case state
        case graceUntil
    }

    private enum InputTokensCodingKeys: String, CodingKey {
        case weekly
        case weeklyInputTokens
        case weeklyInputTokensSnake = "weekly_input_tokens"
        case weeklyInputToken
        case weeklyInputTokenSnake = "weekly_input_token"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        active = try container.decodeIfPresent(Bool.self, forKey: .active)
        limits = try container.decodeIfPresent(Limits.self, forKey: .limits)
        daily = try container.decodeIfPresent(WindowUsage.self, forKey: .daily)

        let weeklyWindowFromRoot = NanoGptSubscriptionUsageResponse.decodeWindowUsage(
            container,
            forKeys: [.weeklyInputTokens, .weeklyInputTokensSnake, .weekly, .weeklyInputToken, .weeklyInputTokenSnake]
        )

        let weeklyWindowFromInputTokens = NanoGptSubscriptionUsageResponse.decodeWindowUsageFromInputTokens(
            container,
            inputTokensKey: .inputTokens
        ) ?? NanoGptSubscriptionUsageResponse.decodeWindowUsageFromInputTokens(
            container,
            inputTokensKey: .inputTokensSnake
        )

        let weeklyWindowFromFlatFields = WindowUsage(
            used: NanoGptSubscriptionUsageResponse.decodeInt(
                container,
                forKeys: [.weeklyInputTokensUsed, .weeklyInputTokensUsedSnake]
            ),
            remaining: NanoGptSubscriptionUsageResponse.decodeInt(
                container,
                forKeys: [.weeklyInputTokensRemaining, .weeklyInputTokensRemainingSnake]
            ),
            percentUsed: NanoGptSubscriptionUsageResponse.decodeDouble(
                container,
                forKeys: [.weeklyInputTokensPercentUsed, .weeklyInputTokensPercentUsedSnake]
            ),
            resetAt: NanoGptSubscriptionUsageResponse.decodeInt64(
                container,
                forKeys: [.weeklyInputTokensResetAt, .weeklyInputTokensResetAtSnake]
            )
        )

        if weeklyWindowFromFlatFields.used != nil
            || weeklyWindowFromFlatFields.remaining != nil
            || weeklyWindowFromFlatFields.percentUsed != nil
            || weeklyWindowFromFlatFields.resetAt != nil {
            weeklyInputTokens = weeklyWindowFromRoot ?? weeklyWindowFromInputTokens ?? weeklyWindowFromFlatFields
        } else {
            weeklyInputTokens = weeklyWindowFromRoot ?? weeklyWindowFromInputTokens
        }

        monthly = try container.decodeIfPresent(WindowUsage.self, forKey: .monthly)
        period = try container.decodeIfPresent(Period.self, forKey: .period)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        graceUntil = try container.decodeIfPresent(String.self, forKey: .graceUntil)
    }
}

private struct NanoGptBalanceResponse: Decodable {
    let usdBalance: String?
    let nanoBalance: String?

    private enum CodingKeys: String, CodingKey {
        case usdBalance = "usd_balance"
        case nanoBalance = "nano_balance"
    }
}

private extension NanoGptSubscriptionUsageResponse {
    static func decodeInt<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, forKey key: Key) -> Int? {
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

    static func decodeInt<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, forKeys keys: [Key]) -> Int? {
        for key in keys {
            if let value = decodeInt(container, forKey: key) {
                return value
            }
        }
        return nil
    }

    static func decodeInt64<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, forKey key: Key) -> Int64? {
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

    static func decodeInt64<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, forKeys keys: [Key]) -> Int64? {
        for key in keys {
            if let value = decodeInt64(container, forKey: key) {
                return value
            }
        }
        return nil
    }

    static func decodeDouble<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, forKey key: Key) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            if let parsed = Double(value) {
                return parsed
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix("%") {
                let percentless = String(trimmed.dropLast())
                if let parsedPercent = Double(percentless) {
                    return parsedPercent / 100.0
                }
            }
        }
        return nil
    }

    static func decodeDouble<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, forKeys keys: [Key]) -> Double? {
        for key in keys {
            if let value = decodeDouble(container, forKey: key) {
                return value
            }
        }
        return nil
    }

    static func decodeWindowUsage<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKeys keys: [Key]
    ) -> WindowUsage? {
        for key in keys {
            if let value = try? container.decode(WindowUsage.self, forKey: key) {
                return value
            }
        }
        return nil
    }

    private static func decodeWindowUsageFromInputTokens(
        _ container: KeyedDecodingContainer<CodingKeys>,
        inputTokensKey: CodingKeys
    ) -> WindowUsage? {
        guard let inputTokens = try? container.nestedContainer(keyedBy: InputTokensCodingKeys.self, forKey: inputTokensKey) else {
            return nil
        }

        return decodeWindowUsage(
            inputTokens,
            forKeys: [.weeklyInputTokens, .weeklyInputTokensSnake, .weekly, .weeklyInputToken, .weeklyInputTokenSnake]
        )
    }
}

final class NanoGptProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .nanoGpt
    let type: ProviderType = .quotaBased

    private let tokenManager: TokenManager
    private let session: URLSession

    init(tokenManager: TokenManager = .shared, session: URLSession = .shared) {
        self.tokenManager = tokenManager
        self.session = session
    }

    func fetch() async throws -> ProviderResult {
        logger.info("Nano-GPT fetch started")

        guard let apiKey = tokenManager.getNanoGptAPIKey() else {
            logger.error("Nano-GPT API key not found")
            throw ProviderError.authenticationFailed("Nano-GPT API key not available")
        }

        async let usageResponseTask = fetchSubscriptionUsage(apiKey: apiKey)
        async let balanceResponseTask = fetchBalance(apiKey: apiKey)

        let usageResponse = try await usageResponseTask
        let balanceResponse = try? await balanceResponseTask

        guard let monthlyLimit = usageResponse.limits?.monthly,
              monthlyLimit > 0 else {
            logger.error("Nano-GPT monthly limit missing")
            throw ProviderError.decodingError("Missing Nano-GPT monthly limit")
        }

        let monthlyUsed = usageResponse.monthly?.used ?? 0
        let monthlyRemaining = usageResponse.monthly?.remaining ?? max(0, monthlyLimit - monthlyUsed)
        let monthlyPercentUsed = normalizedPercent(
            usageResponse.monthly?.percentUsed,
            used: monthlyUsed,
            total: monthlyLimit
        )

        let usage = ProviderUsage.quotaBased(
            remaining: max(0, monthlyRemaining),
            entitlement: monthlyLimit,
            overagePermitted: false
        )

        let dailyLimit = usageResponse.limits?.daily
        let dailyUsed = usageResponse.daily?.used
        let dailyPercentUsed = normalizedPercent(
            usageResponse.daily?.percentUsed,
            used: dailyUsed,
            total: dailyLimit
        )

        let weeklyInputTokenLimit = usageResponse.limits?.weeklyInputTokens
        let weeklyInputTokenUsed = usageResponse.weeklyInputTokens?.used
        let weeklyInputTokenPercentUsed = normalizedPercent(
            usageResponse.weeklyInputTokens?.percentUsed,
            used: weeklyInputTokenUsed,
            total: weeklyInputTokenLimit
        )

        let details = DetailedUsage(
            totalCredits: parseDouble(balanceResponse?.nanoBalance),
            resetPeriod: formatISO8601(usageResponse.period?.currentPeriodEnd),
            sevenDayUsage: weeklyInputTokenPercentUsed,
            sevenDayReset: dateFromMilliseconds(usageResponse.weeklyInputTokens?.resetAt),
            creditsBalance: parseDouble(balanceResponse?.usdBalance),
            authSource: tokenManager.lastFoundAuthPath?.path ?? "~/.local/share/opencode/auth.json",
            tokenUsagePercent: dailyPercentUsed,
            tokenUsageReset: dateFromMilliseconds(usageResponse.daily?.resetAt),
            tokenUsageUsed: dailyUsed,
            tokenUsageTotal: dailyLimit,
            mcpUsagePercent: monthlyPercentUsed,
            mcpUsageReset: dateFromMilliseconds(usageResponse.monthly?.resetAt),
            mcpUsageUsed: monthlyUsed,
            mcpUsageTotal: monthlyLimit
        )

        logger.info(
            "Nano-GPT usage fetched: daily=\(dailyPercentUsed?.description ?? "n/a")% used, weeklyInputTokens=\(weeklyInputTokenPercentUsed?.description ?? "n/a")% used, monthly=\(monthlyPercentUsed?.description ?? "n/a")% used"
        )

        return ProviderResult(usage: usage, details: details)
    }

    private func fetchSubscriptionUsage(apiKey: String) async throws -> NanoGptSubscriptionUsageResponse {
        guard let url = URL(string: "https://nano-gpt.com/api/subscription/v1/usage") else {
            throw ProviderError.networkError("Invalid Nano-GPT usage endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response: response, data: data)

        do {
            return try JSONDecoder().decode(NanoGptSubscriptionUsageResponse.self, from: data)
        } catch {
            logger.error("Failed to decode Nano-GPT usage: \(error.localizedDescription)")
            throw ProviderError.decodingError("Invalid Nano-GPT usage response")
        }
    }

    private func fetchBalance(apiKey: String) async throws -> NanoGptBalanceResponse {
        guard let url = URL(string: "https://nano-gpt.com/api/check-balance") else {
            throw ProviderError.networkError("Invalid Nano-GPT balance endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response: response, data: data)

        do {
            return try JSONDecoder().decode(NanoGptBalanceResponse.self, from: data)
        } catch {
            logger.error("Failed to decode Nano-GPT balance: \(error.localizedDescription)")
            throw ProviderError.decodingError("Invalid Nano-GPT balance response")
        }
    }

    private func validateHTTP(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response type")
        }

        if httpResponse.statusCode == 401 {
            throw ProviderError.authenticationFailed("Invalid Nano-GPT API key")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("Nano-GPT HTTP \(httpResponse.statusCode): \(body, privacy: .public)")
            throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }
    }

    private func normalizedPercent(_ percentValue: Double?, used: Int?, total: Int?) -> Double? {
        if let percentValue {
            if percentValue <= 1.0 {
                return min(max(percentValue * 100.0, 0), 100)
            }
            return min(max(percentValue, 0), 100)
        }

        guard let used, let total, total > 0 else {
            return nil
        }

        return min(max((Double(used) / Double(total)) * 100.0, 0), 100)
    }

    private func dateFromMilliseconds(_ milliseconds: Int64?) -> Date? {
        guard let milliseconds else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000.0)
    }

    private func formatISO8601(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }

        let formatterWithFractional = ISO8601DateFormatter()
        formatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let formatterWithoutFractional = ISO8601DateFormatter()
        formatterWithoutFractional.formatOptions = [.withInternetDateTime]

        let date = formatterWithFractional.date(from: value) ?? formatterWithoutFractional.date(from: value)
        guard let date else { return nil }

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "yyyy-MM-dd HH:mm z"
        displayFormatter.timeZone = TimeZone.current
        return displayFormatter.string(from: date)
    }

    private func parseDouble(_ value: String?) -> Double? {
        guard let value, !value.isEmpty else { return nil }
        return Double(value)
    }
}
