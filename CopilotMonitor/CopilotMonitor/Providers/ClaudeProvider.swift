import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "ClaudeProvider")

// MARK: - Claude API Response Models

/// Response structure from Claude usage API
struct ClaudeUsageResponse: Codable {
    struct UsageWindow: Codable {
        let utilization: Double
        let resets_at: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resets_at = "resets_at"
        }
    }

    struct ExtraUsage: Codable {
        let is_enabled: Bool?

        enum CodingKeys: String, CodingKey {
            case is_enabled = "is_enabled"
        }
    }

    let five_hour: UsageWindow?
    let seven_day: UsageWindow?
    let seven_day_sonnet: UsageWindow?
    let seven_day_opus: UsageWindow?
    let extra_usage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case five_hour = "five_hour"
        case seven_day = "seven_day"
        case seven_day_sonnet = "seven_day_sonnet"
        case seven_day_opus = "seven_day_opus"
        case extra_usage = "extra_usage"
    }
}

// MARK: - ClaudeProvider Implementation

/// Provider for Anthropic Claude API usage tracking
/// Uses quota-based model with 7-day rolling window
final class ClaudeProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .claude
    let type: ProviderType = .quotaBased

    private let tokenManager: TokenManager
    private let session: URLSession

    init(tokenManager: TokenManager = .shared, session: URLSession = .shared) {
        self.tokenManager = tokenManager
        self.session = session
    }

    // MARK: - ProviderProtocol Implementation

    /// Fetches Claude usage data from Anthropic API
    /// - Returns: ProviderResult with remaining quota percentage
    /// - Throws: ProviderError if fetch fails
    func fetch() async throws -> ProviderResult {
        let accounts = tokenManager.getClaudeAccounts()

        guard !accounts.isEmpty else {
            logger.error("No Claude accounts found")
            throw ProviderError.authenticationFailed("Anthropic access token not available")
        }

        var candidates: [ClaudeAccountCandidate] = []
        for account in accounts {
            do {
                let candidate = try await fetchUsageForAccount(account)
                candidates.append(candidate)
            } catch {
                logger.warning("Claude account fetch failed (\(account.authSource)): \(error.localizedDescription)")
            }
        }

        guard !candidates.isEmpty else {
            logger.error("Failed to fetch Claude usage for any account")
            throw ProviderError.providerError("All Claude account fetches failed")
        }

        let merged = dedupeCandidates(candidates)
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

    private struct ClaudeAccountCandidate {
        let accountId: String?
        let usage: ProviderUsage
        let details: DetailedUsage
        let source: ClaudeAuthSource
    }

    private func sourcePriority(_ source: ClaudeAuthSource) -> Int {
        switch source {
        case .opencodeAuth:
            return 3
        case .claudeCodeKeychain:
            return 2
        case .claudeCodeConfig:
            return 1
        case .claudeLegacyCredentials:
            return 0
        }
    }

    private func fetchUsageForAccount(_ account: ClaudeAuthAccount) async throws -> ClaudeAccountCandidate {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            logger.error("Invalid Claude API URL")
            throw ProviderError.networkError("Invalid API endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type from Claude API")
            throw ProviderError.networkError("Invalid response type")
        }

        if httpResponse.statusCode == 401 {
            logger.warning("Claude API returned 401 - token expired")
            throw ProviderError.authenticationFailed("Token expired or invalid")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            logger.error("Claude API returned status \(httpResponse.statusCode)")
            throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }

        do {
            let decoder = JSONDecoder()
            let response = try decoder.decode(ClaudeUsageResponse.self, from: data)

            guard let sevenDay = response.seven_day else {
                logger.error("Claude API response missing seven_day window")
                throw ProviderError.decodingError("Missing seven_day usage window")
            }

            let utilization = sevenDay.utilization
            let remaining = 100 - utilization

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

            let fiveHourReset = response.five_hour?.resets_at.flatMap { parseISO8601Date($0) }
            let sevenDayReset = sevenDay.resets_at.flatMap { parseISO8601Date($0) }

            let fiveHourUsage = response.five_hour?.utilization
            let sonnetUsage = response.seven_day_sonnet?.utilization
            let sonnetReset = response.seven_day_sonnet?.resets_at.flatMap { parseISO8601Date($0) }
            let opusUsage = response.seven_day_opus?.utilization
            let opusReset = response.seven_day_opus?.resets_at.flatMap { parseISO8601Date($0) }

            let extraUsageEnabled = response.extra_usage?.is_enabled

            logger.info("Claude usage fetched (\(account.authSource)): 7d=\(utilization)%, 5h=\(fiveHourUsage?.description ?? "N/A")%")

            let usage = ProviderUsage.quotaBased(
                remaining: Int(remaining),
                entitlement: 100,
                overagePermitted: false
            )

            let details = DetailedUsage(
                fiveHourUsage: fiveHourUsage,
                fiveHourReset: fiveHourReset,
                sevenDayUsage: utilization,
                sevenDayReset: sevenDayReset,
                sonnetUsage: sonnetUsage,
                sonnetReset: sonnetReset,
                opusUsage: opusUsage,
                opusReset: opusReset,
                extraUsageEnabled: extraUsageEnabled,
                authSource: account.authSource
            )

            return ClaudeAccountCandidate(
                accountId: account.accountId ?? account.email,
                usage: usage,
                details: details,
                source: account.source
            )
        } catch let error as DecodingError {
            logger.error("Failed to decode Claude response: \(error.localizedDescription)")
            throw ProviderError.decodingError("Invalid response format: \(error.localizedDescription)")
        } catch {
            logger.error("Unexpected error parsing Claude response: \(error.localizedDescription)")
            throw ProviderError.providerError("Failed to parse response: \(error.localizedDescription)")
        }
    }

    private func dedupeCandidates(_ candidates: [ClaudeAccountCandidate]) -> [ClaudeAccountCandidate] {
        var results: [ClaudeAccountCandidate] = []

        for candidate in candidates {
            if let accountId = candidate.accountId,
               let index = results.firstIndex(where: { $0.accountId == accountId }) {
                if sourcePriority(candidate.source) > sourcePriority(results[index].source) {
                    results[index] = candidate
                }
                continue
            }

            if let index = results.firstIndex(where: { isSameUsage($0, candidate) }) {
                if sourcePriority(candidate.source) > sourcePriority(results[index].source) {
                    results[index] = candidate
                }
                continue
            }

            results.append(candidate)
        }

        return results
    }

    private func isSameUsage(_ lhs: ClaudeAccountCandidate, _ rhs: ClaudeAccountCandidate) -> Bool {
        let weeklyMatch = lhs.details.sevenDayUsage == rhs.details.sevenDayUsage
        let fiveHourMatch = lhs.details.fiveHourUsage == rhs.details.fiveHourUsage
        let sevenDayResetMatch = sameDate(lhs.details.sevenDayReset, rhs.details.sevenDayReset)
        let fiveHourResetMatch = sameDate(lhs.details.fiveHourReset, rhs.details.fiveHourReset)
        return weeklyMatch && fiveHourMatch && sevenDayResetMatch && fiveHourResetMatch
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
}
