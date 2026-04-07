import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "CodexProvider")

final class CodexProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .codex
    let type: ProviderType = .quotaBased

    struct DecodedUsagePayload {
        let usage: ProviderUsage
        let details: DetailedUsage
    }

    // Intentionally internal for @testable unit coverage of endpoint routing
    // and payload decoding across standard and self-service Codex responses.

    private struct RateLimitWindow: Codable {
        let used_percent: Double
        let limit_window_seconds: Int?
        let reset_after_seconds: Int?
        let reset_at: Int?
    }

    private struct RateLimit: Decodable {
        struct ResolvedWindows {
            let shortKey: String
            let shortWindow: RateLimitWindow
            let longKey: String?
            let longWindow: RateLimitWindow?
            let source: String
        }

        let windows: [String: RateLimitWindow]

        var primaryWindow: RateLimitWindow? {
            windows["primary_window"]
        }

        var secondaryWindow: RateLimitWindow? {
            windows["secondary_window"]
        }

        var sparkWindows: [(String, RateLimitWindow)] {
            windows
                .filter { $0.key.lowercased().contains("spark") }
                .map { ($0.key, $0.value) }
                .sorted { lhs, rhs in
                    if let lhsSeconds = lhs.1.limit_window_seconds,
                       let rhsSeconds = rhs.1.limit_window_seconds,
                       lhsSeconds != rhsSeconds {
                        return lhsSeconds < rhsSeconds
                    }
                    return lhs.0.localizedStandardCompare(rhs.0) == .orderedAscending
                }
        }

        func resolvedWindows(excludingSpark: Bool) -> ResolvedWindows? {
            let entries = windows.filter { key, _ in
                !excludingSpark || !key.lowercased().contains("spark")
            }
            guard !entries.isEmpty else { return nil }

            // Preferred: explicit limit window duration from API.
            let byLimitSeconds = entries
                .compactMap { key, window -> (key: String, window: RateLimitWindow, seconds: Int)? in
                    guard let seconds = window.limit_window_seconds, seconds > 0 else { return nil }
                    return (key, window, seconds)
                }
                .sorted { lhs, rhs in
                    if lhs.seconds != rhs.seconds {
                        return lhs.seconds < rhs.seconds
                    }
                    return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
                }
            if let shortest = byLimitSeconds.first {
                let longest = byLimitSeconds.count > 1 ? byLimitSeconds.last : nil
                return ResolvedWindows(
                    shortKey: shortest.key,
                    shortWindow: shortest.window,
                    longKey: longest?.key,
                    longWindow: longest?.window,
                    source: "limit_window_seconds"
                )
            }

            // Fallback: infer short/long windows from remaining time only when clearly separated.
            let byResetAfterSeconds = entries
                .compactMap { key, window -> (key: String, window: RateLimitWindow, seconds: Int)? in
                    guard let seconds = window.reset_after_seconds, seconds > 0 else { return nil }
                    return (key, window, seconds)
                }
                .sorted { lhs, rhs in
                    if lhs.seconds != rhs.seconds {
                        return lhs.seconds < rhs.seconds
                    }
                    return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
                }
            if !byResetAfterSeconds.isEmpty,
               let short = byResetAfterSeconds.first(where: { $0.seconds < 86_400 }),
               let long = byResetAfterSeconds.last(where: { $0.seconds >= 86_400 }) {
                return ResolvedWindows(
                    shortKey: short.key,
                    shortWindow: short.window,
                    longKey: long.key,
                    longWindow: long.window,
                    source: "reset_after_seconds_heuristic"
                )
            }

            // Compatibility fallback for existing response shape.
            if let primary = primaryWindow {
                let secondary = secondaryWindow
                return ResolvedWindows(
                    shortKey: "primary_window",
                    shortWindow: primary,
                    longKey: secondary != nil ? "secondary_window" : nil,
                    longWindow: secondary,
                    source: "primary_secondary_fallback"
                )
            }

            // Last resort: deterministic key ordering.
            let sortedByKey = entries.sorted { lhs, rhs in
                lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
            guard let first = sortedByKey.first else { return nil }
            let last = sortedByKey.count > 1 ? sortedByKey.last : nil
            return ResolvedWindows(
                shortKey: first.key,
                shortWindow: first.value,
                longKey: last?.key,
                longWindow: last?.value,
                source: "key_order_fallback"
            )
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKey.self)
            var parsed: [String: RateLimitWindow] = [:]
            for key in container.allKeys {
                if let window = try? container.decode(RateLimitWindow.self, forKey: key) {
                    parsed[key.stringValue] = window
                }
            }
            windows = parsed
        }

        struct DynamicCodingKey: CodingKey {
            var stringValue: String
            let intValue: Int? = nil

            init?(stringValue: String) {
                self.stringValue = stringValue
            }

            init?(intValue: Int) {
                nil
            }
        }
    }

    private struct CreditsInfo: Codable {
        let has_credits: Bool?
        let unlimited: Bool?
        let balance: String?
        let approx_local_messages: [Int]?
        let approx_cloud_messages: [Int]?

        var balanceAsDouble: Double? {
            guard let balance = balance else { return nil }
            return Double(balance)
        }
    }

    private struct CodexResponse: Decodable {
        struct AdditionalRateLimit: Decodable {
            let limit_name: String?
            let metered_feature: String?
            let rate_limit: RateLimit?
        }

        let plan_type: String?
        let rate_limit: RateLimit
        let additional_rate_limits: [AdditionalRateLimit]?
        let credits: CreditsInfo?
    }

    private struct SelfServiceUsageResponse: Decodable {
        let requestCount: Int?
        let totalTokens: Int?
        let cachedInputTokens: Int?
        let totalCostUSD: Double?
        let limits: [SelfServiceLimit]

        enum CodingKeys: String, CodingKey {
            case requestCount = "request_count"
            case totalTokens = "total_tokens"
            case cachedInputTokens = "cached_input_tokens"
            case totalCostUSD = "total_cost_usd"
            case limits
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            requestCount = try container.decodeIfPresent(Int.self, forKey: .requestCount)
            totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
            cachedInputTokens = try container.decodeIfPresent(Int.self, forKey: .cachedInputTokens)
            totalCostUSD = try container.decodeIfPresent(Double.self, forKey: .totalCostUSD)
            limits = (try? container.decodeIfPresent([SelfServiceLimit].self, forKey: .limits)) ?? []
        }
    }

    private struct SelfServiceLimit: Decodable {
        let limitType: String?
        let limitWindow: String?
        let maxValue: Double?
        let currentValue: Double?
        let remainingValue: Double?
        let modelFilter: String?
        let resetAt: Date?

        enum CodingKeys: String, CodingKey {
            case limitType = "limit_type"
            case limitWindow = "limit_window"
            case maxValue = "max_value"
            case currentValue = "current_value"
            case remainingValue = "remaining_value"
            case modelFilter = "model_filter"
            case resetAt = "reset_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            limitType = try container.decodeIfPresent(String.self, forKey: .limitType)
            limitWindow = try container.decodeIfPresent(String.self, forKey: .limitWindow)
            maxValue = Self.decodeFlexibleDouble(from: container, forKey: .maxValue)
            currentValue = Self.decodeFlexibleDouble(from: container, forKey: .currentValue)
            remainingValue = Self.decodeFlexibleDouble(from: container, forKey: .remainingValue)
            modelFilter = try container.decodeIfPresent(String.self, forKey: .modelFilter)
            resetAt = Self.decodeFlexibleDate(from: container, forKey: .resetAt)
        }

        private static func decodeFlexibleDouble(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Double? {
            if let value = try? container.decode(Double.self, forKey: key) {
                return value
            }
            if let value = try? container.decode(Int.self, forKey: key) {
                return Double(value)
            }
            if let value = try? container.decode(String.self, forKey: key) {
                return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }

        private static func decodeFlexibleDate(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Date? {
            if let value = try? container.decode(Double.self, forKey: key) {
                return value > 2_000_000_000_000
                    ? Date(timeIntervalSince1970: value / 1000.0)
                    : Date(timeIntervalSince1970: value)
            }
            if let value = try? container.decode(Int.self, forKey: key) {
                return value > 2_000_000_000_000
                    ? Date(timeIntervalSince1970: TimeInterval(value) / 1000.0)
                    : Date(timeIntervalSince1970: TimeInterval(value))
            }
            if let value = try? container.decode(String.self, forKey: key) {
                return Self.parseFlexibleDateString(value)
            }
            return nil
        }

        private static func parseFlexibleDateString(_ value: String) -> Date? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let timestamp = Double(trimmed) {
                return timestamp > 2_000_000_000_000
                    ? Date(timeIntervalSince1970: timestamp / 1000.0)
                    : Date(timeIntervalSince1970: timestamp)
            }

            let formatterWithFractional = ISO8601DateFormatter()
            formatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatterWithFractional.date(from: trimmed) {
                return date
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: trimmed)
        }
    }

    private struct ResolvedUsageWindow {
        let label: String
        let windowHours: Int?
        let usagePercent: Double
        let resetDate: Date?
    }

    func fetch() async throws -> ProviderResult {
        let accounts = TokenManager.shared.getOpenAIAccounts()

        guard !accounts.isEmpty else {
            logger.error("No OpenAI accounts found for Codex")
            throw ProviderError.authenticationFailed("No OpenAI accounts configured")
        }

        var candidates: [CodexAccountCandidate] = []
        for account in accounts {
            do {
                let candidate = try await fetchUsageForAccount(account)
                candidates.append(candidate)
            } catch {
                logger.warning("Codex account fetch failed (\(account.authSource)): \(error.localizedDescription)")
            }
        }

        guard !candidates.isEmpty else {
            logger.error("Failed to fetch Codex usage for any account")
            throw ProviderError.providerError("All Codex account fetches failed")
        }

        let merged = CandidateDedupe.merge(
            candidates,
            accountId: { $0.accountId },
            isSameUsage: isSameUsage,
            priority: { sourcePriority($0.source) },
            mergeCandidates: mergeCandidates
        )
        let sorted = merged.sorted { lhs, rhs in
            sourcePriority(lhs.source) > sourcePriority(rhs.source)
        }

        let accountResults: [ProviderAccountResult] = sorted.enumerated().map { index, candidate in
            ProviderAccountResult(
                accountIndex: index,
                accountId: candidate.accountId,
                usage: candidate.usage,
                details: candidate.details
            )
        }

        let minRemaining = accountResults.compactMap { $0.usage.remainingQuota }.min() ?? 0
        let usage = ProviderUsage.quotaBased(remaining: minRemaining, entitlement: 100, overagePermitted: false)

        return ProviderResult(
            usage: usage,
            details: accountResults.first?.details,
            accounts: accountResults
        )
    }

    private struct CodexAccountCandidate {
        let accountId: String?
        let usage: ProviderUsage
        let details: DetailedUsage
        let sourceLabels: [String]
        let source: OpenAIAuthSource
    }

    private func sourcePriority(_ source: OpenAIAuthSource) -> Int {
        switch source {
        case .opencodeAuth:
            return 3
        case .openCodeMultiAuth:
            return 2
        case .codexLB:
            return 1
        case .codexAuth:
            return 0
        }
    }

    private func sourceLabel(_ source: OpenAIAuthSource) -> String {
        switch source {
        case .opencodeAuth:
            return "OpenCode"
        case .openCodeMultiAuth:
            return "OpenCode Multi Auth"
        case .codexLB:
            return "Codex LB"
        case .codexAuth:
            return "Codex"
        }
    }

    private func mergeSourceLabels(_ primary: [String], _ secondary: [String]) -> [String] {
        var merged: [String] = []
        for label in primary + secondary {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !merged.contains(trimmed) else { continue }
            merged.append(trimmed)
        }
        return merged
    }

    private func sourceSummary(_ labels: [String], fallback: String) -> String {
        let merged = mergeSourceLabels(labels, [])
        if merged.isEmpty {
            return fallback
        }
        if merged.count == 1, let first = merged.first {
            return first
        }
        return merged.joined(separator: " + ")
    }

    private func mergeCandidates(primary: CodexAccountCandidate, secondary: CodexAccountCandidate) -> CodexAccountCandidate {
        let mergedLabels = mergeSourceLabels(primary.sourceLabels, secondary.sourceLabels)
        var mergedDetails = primary.details
        mergedDetails.authUsageSummary = sourceSummary(mergedLabels, fallback: "Unknown")

        // Fallback to secondary email when primary has none (different auth sources may carry different metadata)
        if mergedDetails.email == nil || mergedDetails.email?.isEmpty == true {
            mergedDetails.email = secondary.details.email
        }

        return CodexAccountCandidate(
            accountId: primary.accountId,
            usage: primary.usage,
            details: mergedDetails,
            sourceLabels: mergedLabels,
            source: primary.source
        )
    }

    private func fetchUsageForAccount(_ account: OpenAIAuthAccount) async throws -> CodexAccountCandidate {
        let endpointConfiguration = TokenManager.shared.getCodexEndpointConfiguration()
        let url = try codexUsageURL(for: endpointConfiguration, account: account)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        let requestAccountId = codexRequestAccountID(for: account, endpointMode: endpointConfiguration.mode)
        let usesSelfServiceEndpoint = usesSelfServiceUsageEndpoint(account: account, endpointConfiguration: endpointConfiguration)
        if let accountId = requestAccountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        } else if !usesSelfServiceEndpoint {
            logger.warning(
                "Codex account ID missing for \(account.authSource, privacy: .public) using endpoint source \(endpointConfiguration.source, privacy: .public); sending request without account header"
            )
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type from Codex API")
            throw ProviderError.networkError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            logger.error("Codex API request failed with status code: \(httpResponse.statusCode)")
            throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }

        let decodedPayload = try decodeUsagePayload(
            data: data,
            account: account,
            endpointConfiguration: endpointConfiguration
        )
        return CodexAccountCandidate(
            accountId: account.accountId,
            usage: decodedPayload.usage,
            details: decodedPayload.details,
            sourceLabels: account.sourceLabels.isEmpty ? [sourceLabel(account.source)] : account.sourceLabels,
            source: account.source
        )
    }

    func decodeUsagePayload(
        data: Data,
        account: OpenAIAuthAccount,
        endpointConfiguration: CodexEndpointConfiguration
    ) throws -> DecodedUsagePayload {
        let decoder = JSONDecoder()

        do {
            if usesSelfServiceUsageEndpoint(account: account, endpointConfiguration: endpointConfiguration) {
                let response = try decoder.decode(SelfServiceUsageResponse.self, from: data)
                return buildSelfServicePayload(response: response, account: account)
            }

            let response = try decoder.decode(CodexResponse.self, from: data)
            return buildStandardPayload(response: response, account: account)
        } catch {
            logger.error("Failed to decode Codex API response: \(error.localizedDescription)")
            if let jsonString = String(data: data, encoding: .utf8) {
                logger.error("Codex raw response: \(jsonString.prefix(1000))")
                let debugMsg = "[Codex] Raw response: \(jsonString)\n"
                if let debugData = debugMsg.data(using: .utf8) {
                    let path = "/tmp/provider_debug.log"
                    if let handle = FileHandle(forWritingAtPath: path) {
                        handle.seekToEndOfFile()
                        handle.write(debugData)
                        handle.closeFile()
                    }
                }
            }
            throw ProviderError.decodingError(error.localizedDescription)
        }
    }

    func codexUsageURL(for configuration: CodexEndpointConfiguration) throws -> URL {
        switch configuration.mode {
        case .directChatGPT:
            guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
                logger.error("Default Codex usage URL is invalid; aborting request")
                throw ProviderError.providerError("Default Codex usage URL is invalid")
            }
            return url
        case .external(let usageURL):
            return usageURL
        }
    }

    func codexUsageURL(for configuration: CodexEndpointConfiguration, account: OpenAIAuthAccount) throws -> URL {
        if account.credentialType == .apiKey {
            switch configuration.mode {
            case .directChatGPT:
                throw ProviderError.authenticationFailed("Codex API key requires an external codex-lb endpoint")
            case .external(let usageURL):
                guard var components = URLComponents(url: usageURL, resolvingAgainstBaseURL: false) else {
                    throw ProviderError.providerError("External Codex usage URL is invalid")
                }
                let currentPath = components.path
                if currentPath.hasSuffix("/api/codex/usage") {
                    components.path = String(currentPath.dropLast("/api/codex/usage".count)) + "/v1/usage"
                } else if currentPath.hasSuffix("/v1/usage") {
                    // Already points at the self-service endpoint; use as-is.
                    components.path = currentPath
                } else if currentPath.hasSuffix("/usage") {
                    components.path = String(currentPath.dropLast("/usage".count)) + "/v1/usage"
                } else {
                    let trimmedPath = currentPath.hasSuffix("/") ? String(currentPath.dropLast()) : currentPath
                    components.path = trimmedPath + "/v1/usage"
                }
                guard let selfServiceURL = components.url else {
                    throw ProviderError.providerError("Self-service Codex usage URL is invalid")
                }
                return selfServiceURL
            }
        }

        return try codexUsageURL(for: configuration)
    }

    func codexRequestAccountID(for account: OpenAIAuthAccount, endpointMode: CodexEndpointMode) -> String? {
        if account.credentialType == .apiKey {
            return nil
        }
        switch endpointMode {
        case .directChatGPT:
            return account.accountId
        case .external:
            if account.source == .codexLB {
                return account.externalUsageAccountId ?? account.accountId
            }
            return account.accountId
        }
    }

    func usesSelfServiceUsageEndpoint(account: OpenAIAuthAccount, endpointConfiguration: CodexEndpointConfiguration) -> Bool {
        account.credentialType == .apiKey && isExternalEndpointMode(endpointConfiguration.mode)
    }

    func isExternalEndpointMode(_ mode: CodexEndpointMode) -> Bool {
        if case .external = mode {
            return true
        }
        return false
    }

    private func isSameUsage(_ lhs: CodexAccountCandidate, _ rhs: CodexAccountCandidate) -> Bool {
        let primaryMatch = sameUsageValue(lhs.details.dailyUsage, rhs.details.dailyUsage)
        let secondaryMatch = sameUsageValue(lhs.details.secondaryUsage, rhs.details.secondaryUsage)
        let primaryResetMatch = sameDate(lhs.details.primaryReset, rhs.details.primaryReset)
        let secondaryResetMatch = sameDate(lhs.details.secondaryReset, rhs.details.secondaryReset)
        let primaryLabelMatch = lhs.details.codexPrimaryWindowLabel == rhs.details.codexPrimaryWindowLabel
        let secondaryLabelMatch = lhs.details.codexSecondaryWindowLabel == rhs.details.codexSecondaryWindowLabel
        let primaryHoursMatch = lhs.details.codexPrimaryWindowHours == rhs.details.codexPrimaryWindowHours
        let secondaryHoursMatch = lhs.details.codexSecondaryWindowHours == rhs.details.codexSecondaryWindowHours
        let sparkUsageMatch = sameUsageValue(lhs.details.sparkUsage, rhs.details.sparkUsage)
        let sparkResetMatch = sameDate(lhs.details.sparkReset, rhs.details.sparkReset)
        let sparkSecondaryUsageMatch = sameUsageValue(lhs.details.sparkSecondaryUsage, rhs.details.sparkSecondaryUsage)
        let sparkSecondaryResetMatch = sameDate(lhs.details.sparkSecondaryReset, rhs.details.sparkSecondaryReset)
        let sparkWindowLabelMatch = lhs.details.sparkWindowLabel == rhs.details.sparkWindowLabel
        let sparkPrimaryLabelMatch = lhs.details.sparkPrimaryWindowLabel == rhs.details.sparkPrimaryWindowLabel
        let sparkSecondaryLabelMatch = lhs.details.sparkSecondaryWindowLabel == rhs.details.sparkSecondaryWindowLabel
        let sparkPrimaryHoursMatch = lhs.details.sparkPrimaryWindowHours == rhs.details.sparkPrimaryWindowHours
        let sparkSecondaryHoursMatch = lhs.details.sparkSecondaryWindowHours == rhs.details.sparkSecondaryWindowHours
        return primaryMatch
            && secondaryMatch
            && primaryResetMatch
            && secondaryResetMatch
            && primaryLabelMatch
            && secondaryLabelMatch
            && primaryHoursMatch
            && secondaryHoursMatch
            && sparkUsageMatch
            && sparkResetMatch
            && sparkSecondaryUsageMatch
            && sparkSecondaryResetMatch
            && sparkWindowLabelMatch
            && sparkPrimaryLabelMatch
            && sparkSecondaryLabelMatch
            && sparkPrimaryHoursMatch
            && sparkSecondaryHoursMatch
    }

    private func buildStandardPayload(response codexResponse: CodexResponse, account: OpenAIAuthAccount) -> DecodedUsagePayload {
        let baseWindows = codexResponse.rate_limit.resolvedWindows(excludingSpark: true)
        let primaryWindow = baseWindows?.shortWindow ?? codexResponse.rate_limit.primaryWindow ?? RateLimitWindow(used_percent: 0, limit_window_seconds: nil, reset_after_seconds: nil, reset_at: nil)
        let secondaryWindow = baseWindows?.longWindow
        let additionalSparkLimit = codexResponse.additional_rate_limits?.first { limit in
            let name = limit.limit_name ?? ""
            return name.range(of: "spark", options: .caseInsensitive) != nil
                && limit.rate_limit?.resolvedWindows(excludingSpark: false) != nil
        }
        let inlineSparkWindows = codexResponse.rate_limit.sparkWindows
        let inlineSparkPrimary = inlineSparkWindows.first
        let inlineSparkSecondary = inlineSparkWindows.count > 1 ? inlineSparkWindows.last : nil
        let additionalSparkWindows = additionalSparkLimit?.rate_limit?.resolvedWindows(excludingSpark: false)
        let primaryUsedPercent = primaryWindow.used_percent
        let secondaryUsedPercent = secondaryWindow?.used_percent
        let sparkUsedPercent = inlineSparkPrimary?.1.used_percent
            ?? additionalSparkWindows?.shortWindow.used_percent
        let sparkWindowLabel = normalizeSparkWindowLabel(inlineSparkPrimary?.0 ?? additionalSparkLimit?.limit_name)
        let sparkSecondaryUsedPercent = inlineSparkSecondary?.1.used_percent
            ?? (inlineSparkPrimary == nil ? additionalSparkWindows?.longWindow?.used_percent : nil)

        let now = Date()
        let primaryResetDate = resolveResetDate(now: now, window: primaryWindow)
        let secondaryResetDate = secondaryWindow.flatMap { resolveResetDate(now: now, window: $0) }
        let sparkResetDate = inlineSparkPrimary.flatMap { resolveResetDate(now: now, window: $0.1) }
            ?? additionalSparkWindows.flatMap { resolveResetDate(now: now, window: $0.shortWindow) }
        let sparkSecondaryResetDate = inlineSparkSecondary.flatMap { resolveResetDate(now: now, window: $0.1) }
            ?? (inlineSparkPrimary == nil ? additionalSparkWindows?.longWindow.flatMap { resolveResetDate(now: now, window: $0) } : nil)
        let primaryWindowMetadata = codexWindowMetadata(for: primaryWindow, fallbackLabel: "5h")
        let secondaryWindowMetadata = secondaryWindow.flatMap { codexWindowMetadata(for: $0, fallbackLabel: "Weekly") }
        let sparkPrimaryWindowMetadata = sparkUsedPercent != nil
            ? (inlineSparkPrimary.map { codexWindowMetadata(for: $0.1, fallbackLabel: "5h") }
                ?? additionalSparkWindows.map { codexWindowMetadata(for: $0.shortWindow, fallbackLabel: "5h") })
            : nil
        let sparkSecondaryWindowMetadata = sparkSecondaryUsedPercent != nil
            ? (inlineSparkSecondary.map { codexWindowMetadata(for: $0.1, fallbackLabel: "Weekly") }
                ?? additionalSparkWindows?.longWindow.map { codexWindowMetadata(for: $0, fallbackLabel: "Weekly") })
            : nil

        let remaining = max(0, Int(100 - primaryUsedPercent))
        let sourceLabels = account.sourceLabels.isEmpty ? [sourceLabel(account.source)] : account.sourceLabels
        let authUsageSummary = sourceSummary(sourceLabels, fallback: "Unknown")
        let details = DetailedUsage(
            dailyUsage: primaryUsedPercent,
            secondaryUsage: secondaryUsedPercent,
            secondaryReset: secondaryResetDate,
            primaryReset: primaryResetDate,
            codexPrimaryWindowLabel: primaryWindowMetadata.label,
            codexPrimaryWindowHours: primaryWindowMetadata.hours,
            codexSecondaryWindowLabel: secondaryWindowMetadata?.label,
            codexSecondaryWindowHours: secondaryWindowMetadata?.hours,
            sparkUsage: sparkUsedPercent,
            sparkReset: sparkResetDate,
            sparkSecondaryUsage: sparkSecondaryUsedPercent,
            sparkSecondaryReset: sparkSecondaryResetDate,
            sparkWindowLabel: sparkWindowLabel,
            sparkPrimaryWindowLabel: sparkPrimaryWindowMetadata?.label,
            sparkPrimaryWindowHours: sparkPrimaryWindowMetadata?.hours,
            sparkSecondaryWindowLabel: sparkSecondaryWindowMetadata?.label,
            sparkSecondaryWindowHours: sparkSecondaryWindowMetadata?.hours,
            creditsBalance: codexResponse.credits?.balanceAsDouble,
            planType: codexResponse.plan_type,
            email: account.email,
            authSource: account.authSource,
            authUsageSummary: authUsageSummary
        )

        let sparkSummary = sparkUsedPercent.map { String(format: "%.1f%%", $0) } ?? "none"
        let sparkWeeklySummary = sparkSecondaryUsedPercent.map { String(format: "%.1f%%", $0) } ?? "none"
        let sparkSource: String
        if inlineSparkPrimary != nil {
            sparkSource = "rate_limit"
        } else if additionalSparkLimit != nil {
            sparkSource = "additional_rate_limits"
        } else {
            sparkSource = "none"
        }
        let secondarySummary = secondaryUsedPercent.map { String(format: "%.1f%%", $0) } ?? "none"
        logger.debug(
            """
            Codex usage fetched (\(authUsageSummary)): \
            email=\(account.email ?? "unknown"), \
            base_short=\(primaryUsedPercent)%(\(baseWindows?.shortKey ?? "primary_window")), \
            base_long=\(secondarySummary)(\(baseWindows?.longKey ?? "none")), \
            base_source=\(baseWindows?.source ?? "fallback"), \
            spark_primary=\(sparkSummary), \
            spark_secondary=\(sparkWeeklySummary), \
            spark_source=\(sparkSource), \
            spark_window=\(sparkWindowLabel ?? "none"), \
            plan=\(codexResponse.plan_type ?? "unknown")
            """
        )

        return DecodedUsagePayload(
            usage: ProviderUsage.quotaBased(remaining: remaining, entitlement: 100, overagePermitted: false),
            details: details
        )
    }

    private func buildSelfServicePayload(response: SelfServiceUsageResponse, account: OpenAIAuthAccount) -> DecodedUsagePayload {
        let sourceLabels = account.sourceLabels.isEmpty ? [sourceLabel(account.source)] : account.sourceLabels
        let authUsageSummary = sourceSummary(sourceLabels, fallback: "Unknown")

        let grouped = partitionSelfServiceLimits(response.limits)
        let primary = resolveUsageWindow(from: grouped.base.first)
        let secondary = grouped.base.count > 1 ? resolveUsageWindow(from: grouped.base.last) : nil
        let sparkPrimary = resolveUsageWindow(from: grouped.spark.first)
        let sparkSecondary = grouped.spark.count > 1 ? resolveUsageWindow(from: grouped.spark.last) : nil
        let sparkLabel = normalizeSparkWindowLabel(grouped.spark.first?.modelFilter ?? grouped.spark.first?.limitType)

        let primaryPercent = primary?.usagePercent ?? 0
        let remaining = max(0, Int(100 - primaryPercent))
        let details = DetailedUsage(
            dailyUsage: primary?.usagePercent,
            secondaryUsage: secondary?.usagePercent,
            secondaryReset: secondary?.resetDate,
            primaryReset: primary?.resetDate,
            codexPrimaryWindowLabel: primary?.label,
            codexPrimaryWindowHours: primary?.windowHours,
            codexSecondaryWindowLabel: secondary?.label,
            codexSecondaryWindowHours: secondary?.windowHours,
            sparkUsage: sparkPrimary?.usagePercent,
            sparkReset: sparkPrimary?.resetDate,
            sparkSecondaryUsage: sparkSecondary?.usagePercent,
            sparkSecondaryReset: sparkSecondary?.resetDate,
            sparkWindowLabel: sparkLabel,
            sparkPrimaryWindowLabel: sparkPrimary?.label,
            sparkPrimaryWindowHours: sparkPrimary?.windowHours,
            sparkSecondaryWindowLabel: sparkSecondary?.label,
            sparkSecondaryWindowHours: sparkSecondary?.windowHours,
            email: account.email,
            monthlyCost: response.totalCostUSD,
            authSource: account.authSource,
            authUsageSummary: authUsageSummary
        )

        logger.debug(
            """
            Codex self-service usage fetched (\(authUsageSummary)): \
            email=\(account.email ?? "unknown"), \
            base_primary=\(primary.map { String(format: "%.1f%%(%@)", $0.usagePercent, $0.label) } ?? "none"), \
            base_secondary=\(secondary.map { String(format: "%.1f%%(%@)", $0.usagePercent, $0.label) } ?? "none"), \
            spark_primary=\(sparkPrimary.map { String(format: "%.1f%%(%@)", $0.usagePercent, $0.label) } ?? "none"), \
            spark_secondary=\(sparkSecondary.map { String(format: "%.1f%%(%@)", $0.usagePercent, $0.label) } ?? "none"), \
            total_cost_usd=\(response.totalCostUSD.map { String(format: "%.2f", $0) } ?? "none")
            """
        )

        return DecodedUsagePayload(
            usage: ProviderUsage.quotaBased(remaining: remaining, entitlement: 100, overagePermitted: false),
            details: details
        )
    }

    private func partitionSelfServiceLimits(_ limits: [SelfServiceLimit]) -> (base: [SelfServiceLimit], spark: [SelfServiceLimit]) {
        let usable = limits.filter { limit in
            guard let maxValue = limit.maxValue, maxValue > 0 else { return false }
            return limit.currentValue != nil || limit.remainingValue != nil
        }

        let spark = usable
            .filter(isSparkLimit)
            .sorted(by: compareSelfServiceLimits)
        let base = usable
            .filter { !isSparkLimit($0) }
            .sorted(by: compareSelfServiceLimits)
        return (base: base, spark: spark)
    }

    private func compareSelfServiceLimits(_ lhs: SelfServiceLimit, _ rhs: SelfServiceLimit) -> Bool {
        let lhsHours = normalizedWindowHours(from: lhs.limitWindow)
        let rhsHours = normalizedWindowHours(from: rhs.limitWindow)
        if let lhsHours, let rhsHours, lhsHours != rhsHours {
            return lhsHours < rhsHours
        }
        if lhs.limitWindow != rhs.limitWindow {
            return (lhs.limitWindow ?? "").localizedStandardCompare(rhs.limitWindow ?? "") == .orderedAscending
        }
        return (lhs.modelFilter ?? lhs.limitType ?? "").localizedStandardCompare(rhs.modelFilter ?? rhs.limitType ?? "") == .orderedAscending
    }

    private func isSparkLimit(_ limit: SelfServiceLimit) -> Bool {
        let haystack = [limit.modelFilter, limit.limitType]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return haystack.contains("spark")
    }

    private func resolveUsageWindow(from limit: SelfServiceLimit?) -> ResolvedUsageWindow? {
        guard let limit,
              let maxValue = limit.maxValue,
              maxValue > 0 else {
            return nil
        }

        let currentValue: Double
        if let explicitCurrent = limit.currentValue {
            currentValue = explicitCurrent
        } else if let remainingValue = limit.remainingValue {
            currentValue = max(0, maxValue - remainingValue)
        } else {
            return nil
        }

        let rawPercent = (currentValue / maxValue) * 100.0
        let usagePercent = min(max(rawPercent, 0), 100)
        return ResolvedUsageWindow(
            label: formatCodexWindowLabel(limit.limitWindow),
            windowHours: normalizedWindowHours(from: limit.limitWindow),
            usagePercent: usagePercent,
            resetDate: limit.resetAt
        )
    }

    private func formatCodexWindowLabel(_ rawLabel: String?) -> String {
        let normalized = rawLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !normalized.isEmpty else { return "Usage" }

        if normalized == "weekly" || normalized == "7d" || normalized == "7day" || normalized == "7days" {
            return "Weekly"
        }
        if normalized == "monthly" {
            return "Monthly"
        }
        if normalized == "daily" || normalized == "1d" || normalized == "1day" || normalized == "1days" || normalized == "24h" {
            return "Daily"
        }

        if let hours = normalizedWindowHours(from: rawLabel), hours > 0 {
            if hours % 24 == 0 {
                let days = hours / 24
                if days == 7 { return "Weekly" }
                if days == 1 { return "Daily" }
                return "\(days)d"
            }
            return "\(hours)h"
        }

        return rawLabel?
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized ?? "Usage"
    }

    private func normalizedWindowHours(from rawLabel: String?) -> Int? {
        guard let rawLabel else { return nil }
        let normalized = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        if normalized == "weekly" { return 24 * 7 }
        if normalized == "monthly" { return 24 * 30 }
        if normalized == "daily" { return 24 }

        let compact = normalized.replacingOccurrences(of: " ", with: "")
        let pattern = #"^(\d+)([hdw])$"#
        guard let match = compact.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let matched = String(compact[match])
        let unit = matched.last
        let valueString = String(matched.dropLast())
        guard let value = Int(valueString), value > 0 else { return nil }
        switch unit {
        case "h": return value
        case "d": return value * 24
        case "w": return value * 24 * 7
        default: return nil
        }
    }

    private func codexWindowMetadata(for window: RateLimitWindow, fallbackLabel: String) -> (label: String, hours: Int?) {
        if let seconds = window.limit_window_seconds,
           seconds > 0 {
            let rawLabel = compactWindowLabel(from: seconds)
            return (
                label: formatCodexWindowLabel(rawLabel),
                hours: normalizedWindowHours(from: rawLabel)
            )
        }

        return (
            label: formatCodexWindowLabel(fallbackLabel),
            hours: normalizedWindowHours(from: fallbackLabel)
        )
    }

    private func compactWindowLabel(from seconds: Int) -> String {
        guard seconds > 0 else { return "Usage" }
        if seconds % 604_800 == 0 {
            return "\(seconds / 604_800)w"
        }
        if seconds % 86_400 == 0 {
            return "\(seconds / 86_400)d"
        }
        let roundedHours = max(1, Int(round(Double(seconds) / 3600.0)))
        return "\(roundedHours)h"
    }

    private func normalizeSparkWindowLabel(_ rawLabel: String?) -> String? {
        guard let rawLabel else { return nil }
        let normalized = rawLabel
            .replacingOccurrences(of: "_window", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if normalized.lowercased() == normalized {
            return normalized.capitalized
        }
        return normalized
    }

    private func resolveResetDate(now: Date, window: RateLimitWindow) -> Date? {
        if let resetAfterSeconds = window.reset_after_seconds {
            return now.addingTimeInterval(TimeInterval(resetAfterSeconds))
        }
        if let resetAt = window.reset_at {
            if resetAt > 2_000_000_000_000 {
                return Date(timeIntervalSince1970: TimeInterval(resetAt) / 1000.0)
            }
            return Date(timeIntervalSince1970: TimeInterval(resetAt))
        }
        return nil
    }

    private func sameDate(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (left?, right?):
            return Int(left.timeIntervalSince1970) == Int(right.timeIntervalSince1970)
        default:
            return false
        }
    }

    private func sameUsageValue(_ lhs: Double?, _ rhs: Double?, tolerance: Double = 0.0001) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (left?, right?):
            return abs(left - right) <= tolerance
        default:
            return false
        }
    }
}

private enum AnyCodable: Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyCodable])
    case object([String: AnyCodable])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([AnyCodable].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: AnyCodable].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode AnyCodable"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let bool):
            try container.encode(bool)
        case .int(let int):
            try container.encode(int)
        case .double(let double):
            try container.encode(double)
        case .string(let string):
            try container.encode(string)
        case .array(let array):
            try container.encode(array)
        case .object(let object):
            try container.encode(object)
        }
    }
}
