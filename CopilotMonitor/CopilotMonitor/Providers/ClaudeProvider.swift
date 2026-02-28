import Foundation
import CryptoKit
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
        let monthly_limit: Double?
        let used_credits: Double?
        let utilization: Double?

        enum CodingKeys: String, CodingKey {
            case is_enabled = "is_enabled"
            case monthly_limit = "monthly_limit"
            case used_credits = "used_credits"
            case utilization = "utilization"
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

/// Response structure from Claude profile/account endpoints
private struct ClaudeAccountIdentityResponse: Decodable {
    struct Account: Decodable {
        let uuid: String?
        let taggedId: String?
        let email: String?
        let emailAddress: String?

        enum CodingKeys: String, CodingKey {
            case uuid
            case taggedId = "tagged_id"
            case email
            case emailAddress = "email_address"
        }
    }

    let account: Account?
    let uuid: String?
    let taggedId: String?
    let email: String?
    let emailAddress: String?

    enum CodingKeys: String, CodingKey {
        case account
        case uuid
        case taggedId = "tagged_id"
        case email
        case emailAddress = "email_address"
    }
}

private struct ClaudeOAuthRefreshResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
    let token_type: String?
    let scope: String?
}

// MARK: - ClaudeProvider Implementation

/// Provider for Anthropic Claude API usage tracking
/// Uses quota-based model with 7-day rolling window
final class ClaudeProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .claude
    let type: ProviderType = .quotaBased

    private let tokenManager: TokenManager
    private let session: URLSession
    private let claudeUsageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")
    private let claudeOAuthRefreshEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")
    private let claudeOAuthClientID = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_CLIENT_ID"]
        ?? "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

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
                if account.source == .opencodeAuth {
                    logger.info("Skipping unavailable OpenCode Claude account")
                    continue
                }
                let fallback = await unavailableCandidate(for: account, error: error)
                candidates.append(fallback)
            }
        }

        guard !candidates.isEmpty else {
            logger.error("Failed to fetch Claude usage for any account")
            throw ProviderError.authenticationFailed("No active Claude accounts available")
        }

        let merged = CandidateDedupe.merge(
            candidates,
            accountId: { $0.dedupeKey },
            isSameUsage: { _, _ in false },
            priority: { ($0.hasUsageData ? 100 : 0) + sourcePriority($0.source) },
            mergeCandidates: mergeCandidates
        )
        let sorted = merged.sorted { lhs, rhs in
            if lhs.hasUsageData != rhs.hasUsageData {
                return lhs.hasUsageData
            }
            return sourcePriority(lhs.source) > sourcePriority(rhs.source)
        }

        let hasUsageCandidate = sorted.contains { $0.hasUsageData }
        let displayCandidates = sorted.filter { candidate in
            guard hasUsageCandidate, !candidate.hasUsageData else { return true }
            guard let authError = candidate.details.authErrorMessage?.lowercased(),
                  authError.contains("token expired"),
                  let accountId = candidate.accountId?.lowercased(),
                  accountId.hasPrefix("token:") else {
                return true
            }

            logger.info("Suppressing unresolved expired Claude candidate because active account is available")
            return false
        }

        let accountResults: [ProviderAccountResult] = displayCandidates.enumerated().map { index, candidate in
            ProviderAccountResult(
                accountIndex: index,
                accountId: candidate.accountId,
                usage: candidate.usage,
                details: candidate.details
            )
        }

        let usageAccountResults = accountResults.filter { ($0.usage.totalEntitlement ?? 0) > 0 }
        guard !usageAccountResults.isEmpty else {
            logger.error("Failed to fetch Claude usage for every discovered account")
            throw ProviderError.providerError("All Claude account fetches failed")
        }

        let minRemaining = usageAccountResults.compactMap { $0.usage.remainingQuota }.min() ?? 0
        let usage = ProviderUsage.quotaBased(remaining: minRemaining, entitlement: 100, overagePermitted: false)

        return ProviderResult(
            usage: usage,
            details: accountResults.first?.details,
            accounts: accountResults
        )
    }

    private struct ClaudeAccountCandidate {
        let dedupeKey: String
        let accountId: String?
        let usage: ProviderUsage
        let details: DetailedUsage
        let sourceLabels: [String]
        let source: ClaudeAuthSource
        let hasUsageData: Bool
    }

    private struct ClaudeResolvedIdentity {
        let dedupeKey: String
        let accountId: String?
        let email: String?
        let displayAccountId: String
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

    private func sourceLabel(_ source: ClaudeAuthSource) -> String {
        switch source {
        case .opencodeAuth:
            return "OpenCode"
        case .claudeCodeKeychain:
            return "Claude Code (Keychain)"
        case .claudeCodeConfig:
            return "Claude Code"
        case .claudeLegacyCredentials:
            return "Claude Code (Legacy)"
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

    private func mergeCandidates(primary: ClaudeAccountCandidate, secondary: ClaudeAccountCandidate) -> ClaudeAccountCandidate {
        let mergedLabels = mergeSourceLabels(primary.sourceLabels, secondary.sourceLabels)
        var mergedDetails = primary.details
        mergedDetails.authUsageSummary = sourceSummary(mergedLabels, fallback: "Unknown")
        if mergedDetails.email == nil || mergedDetails.email?.isEmpty == true {
            mergedDetails.email = secondary.details.email
        }
        if mergedDetails.authErrorMessage == nil || mergedDetails.authErrorMessage?.isEmpty == true {
            mergedDetails.authErrorMessage = secondary.details.authErrorMessage
        }

        let mergedAccountId: String?
        if let primaryId = normalizedNonEmpty(primary.accountId),
           !primaryId.hasPrefix("token:") {
            mergedAccountId = primaryId
        } else if let secondaryId = normalizedNonEmpty(secondary.accountId) {
            mergedAccountId = secondaryId
        } else {
            mergedAccountId = normalizedNonEmpty(primary.accountId)
        }

        return ClaudeAccountCandidate(
            dedupeKey: primary.dedupeKey,
            accountId: mergedAccountId,
            usage: primary.usage,
            details: mergedDetails,
            sourceLabels: mergedLabels,
            source: primary.source,
            hasUsageData: primary.hasUsageData || secondary.hasUsageData
        )
    }

    private func normalizedNonEmpty(_ value: String?, lowercase: Bool = false) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return lowercase ? trimmed.lowercased() : trimmed
    }

    private func tokenFingerprint(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        let full = digest.map { String(format: "%02x", $0) }.joined()
        return String(full.prefix(12))
    }

    private func fetchAccountIdentity(accessToken: String) async -> (accountId: String?, email: String?)? {
        let endpoints = [
            "/api/oauth/profile",
            "/api/oauth/account"
        ]

        for endpoint in endpoints {
            guard let url = URL(string: "https://api.anthropic.com\(endpoint)") else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

            do {
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    logger.warning("Claude identity endpoint returned invalid response type: \(endpoint)")
                    continue
                }

                if httpResponse.statusCode == 401 {
                    logger.warning("Claude identity endpoint unauthorized: \(endpoint)")
                    return nil
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    logger.debug("Claude identity endpoint skipped: \(endpoint) status=\(httpResponse.statusCode)")
                    continue
                }

                let payload = try JSONDecoder().decode(ClaudeAccountIdentityResponse.self, from: data)
                let resolvedAccountId = normalizedNonEmpty(
                    payload.account?.uuid
                    ?? payload.account?.taggedId
                    ?? payload.uuid
                    ?? payload.taggedId
                )
                let resolvedEmail = normalizedNonEmpty(
                    payload.account?.email
                    ?? payload.account?.emailAddress
                    ?? payload.email
                    ?? payload.emailAddress,
                    lowercase: true
                )

                if resolvedAccountId != nil || resolvedEmail != nil {
                    logger.debug(
                        "Claude identity resolved via \(endpoint): accountId=\(resolvedAccountId != nil), email=\(resolvedEmail != nil)"
                    )
                    return (accountId: resolvedAccountId, email: resolvedEmail)
                }
            } catch {
                logger.debug("Claude identity endpoint failed (\(endpoint)): \(error.localizedDescription)")
            }
        }

        return nil
    }

    private func resolveAccountIdentity(_ account: ClaudeAuthAccount) async -> ClaudeResolvedIdentity {
        var resolvedAccountId = normalizedNonEmpty(account.accountId)
        var resolvedEmail = normalizedNonEmpty(account.email, lowercase: true)

        if resolvedAccountId == nil || resolvedEmail == nil,
           let apiIdentity = await fetchAccountIdentity(accessToken: account.accessToken) {
            if resolvedAccountId == nil {
                resolvedAccountId = apiIdentity.accountId
            }
            if resolvedEmail == nil {
                resolvedEmail = apiIdentity.email
            }
        }

        let dedupeKey: String
        if let resolvedAccountId {
            dedupeKey = "id:\(resolvedAccountId)"
        } else if let resolvedEmail {
            dedupeKey = "email:\(resolvedEmail)"
        } else {
            dedupeKey = "token:\(tokenFingerprint(account.accessToken))"
        }

        let displayAccountId = resolvedAccountId ?? resolvedEmail ?? dedupeKey
        return ClaudeResolvedIdentity(
            dedupeKey: dedupeKey,
            accountId: resolvedAccountId,
            email: resolvedEmail,
            displayAccountId: displayAccountId
        )
    }

    private func isAccessTokenExpired(_ account: ClaudeAuthAccount) -> Bool {
        guard let expiresAt = account.expiresAt else { return false }
        // Treat tokens expiring in under 60 seconds as expired to avoid race conditions.
        return expiresAt <= Date().addingTimeInterval(60)
    }

    private func isTokenExpiredError(_ error: Error) -> Bool {
        guard let providerError = error as? ProviderError else {
            return error.localizedDescription.lowercased().contains("token expired")
                || error.localizedDescription.lowercased().contains("invalid token")
        }

        switch providerError {
        case .authenticationFailed(let message):
            let lowered = message.lowercased()
            return lowered.contains("token expired")
                || lowered.contains("expired")
                || lowered.contains("invalid")
        default:
            return false
        }
    }

    private func authErrorMessage(for account: ClaudeAuthAccount, error: Error) -> String {
        if isAccessTokenExpired(account) || isTokenExpiredError(error) {
            return "Token expired"
        }
        return "Authentication failed"
    }

    private func refreshClaudeAccessToken(for account: ClaudeAuthAccount) async -> ClaudeAuthAccount? {
        let refreshToken = account.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !refreshToken.isEmpty else {
            logger.info("Claude token refresh skipped: refresh token unavailable (\(account.authSource))")
            return nil
        }

        guard let refreshURL = claudeOAuthRefreshEndpoint else {
            logger.error("Claude OAuth refresh URL is invalid")
            return nil
        }

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: claudeOAuthClientID)
        ]

        guard let body = components.query?.data(using: .utf8) else {
            logger.error("Claude OAuth refresh payload construction failed")
            return nil
        }

        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                logger.warning("Claude token refresh failed: invalid response type")
                return nil
            }

            guard httpResponse.statusCode == 200 else {
                logger.warning("Claude token refresh failed (\(httpResponse.statusCode))")
                return nil
            }

            let refreshResponse = try JSONDecoder().decode(ClaudeOAuthRefreshResponse.self, from: data)
            let refreshedAccessToken = refreshResponse.access_token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !refreshedAccessToken.isEmpty else {
                logger.warning("Claude token refresh returned empty access token")
                return nil
            }

            let refreshedRefreshToken = normalizedNonEmpty(refreshResponse.refresh_token) ?? account.refreshToken
            let refreshedExpiresAt = refreshResponse.expires_in.map {
                Date().addingTimeInterval(TimeInterval(max(0, $0 - 60)))
            }

            tokenManager.persistClaudeOAuthRefresh(
                accessToken: refreshedAccessToken,
                refreshToken: refreshedRefreshToken,
                expiresAt: refreshedExpiresAt
            )

            logger.info("Claude token refreshed successfully (\(account.authSource))")
            return ClaudeAuthAccount(
                accessToken: refreshedAccessToken,
                accountId: account.accountId,
                email: account.email,
                refreshToken: refreshedRefreshToken,
                expiresAt: refreshedExpiresAt ?? account.expiresAt,
                authSource: account.authSource,
                sourceLabels: account.sourceLabels,
                source: account.source
            )
        } catch {
            logger.warning("Claude token refresh failed with error: \(error.localizedDescription)")
            return nil
        }
    }

    private func requestClaudeUsageData(accessToken: String) async throws -> Data {
        guard let url = claudeUsageEndpoint else {
            logger.error("Invalid Claude API URL")
            throw ProviderError.networkError("Invalid API endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
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

        return data
    }

    private func unavailableCandidate(for account: ClaudeAuthAccount, error: Error) async -> ClaudeAccountCandidate {
        let sourceLabels = account.sourceLabels.isEmpty ? [sourceLabel(account.source)] : account.sourceLabels
        let authUsageSummary = sourceSummary(sourceLabels, fallback: "Unknown")
        let identity = await resolveAccountIdentity(account)

        logger.info(
            "Claude account fallback (\(authUsageSummary)): reason=\(error.localizedDescription)"
        )

        let details = DetailedUsage(
            email: identity.email,
            authSource: account.authSource,
            authUsageSummary: authUsageSummary,
            authErrorMessage: authErrorMessage(for: account, error: error)
        )

        return ClaudeAccountCandidate(
            dedupeKey: identity.dedupeKey,
            accountId: identity.displayAccountId,
            usage: ProviderUsage.quotaBased(remaining: 0, entitlement: 0, overagePermitted: false),
            details: details,
            sourceLabels: sourceLabels,
            source: account.source,
            hasUsageData: false
        )
    }

    private func fetchUsageForAccount(_ account: ClaudeAuthAccount) async throws -> ClaudeAccountCandidate {
        var workingAccount = account
        var data: Data

        if isAccessTokenExpired(workingAccount),
           let refreshedAccount = await refreshClaudeAccessToken(for: workingAccount) {
            logger.info("Claude access token refreshed before usage request (\(account.authSource))")
            workingAccount = refreshedAccount
        }

        do {
            data = try await requestClaudeUsageData(accessToken: workingAccount.accessToken)
        } catch {
            if isTokenExpiredError(error),
               let refreshedAccount = await refreshClaudeAccessToken(for: workingAccount) {
                logger.info("Retrying Claude usage request with refreshed token (\(account.authSource))")
                workingAccount = refreshedAccount
                data = try await requestClaudeUsageData(accessToken: workingAccount.accessToken)
            } else {
                throw error
            }
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
            let extraUsageMonthlyLimitCredits = response.extra_usage?.monthly_limit
            let extraUsageUsedCredits = response.extra_usage?.used_credits
            let extraUsageUtilizationPercent = response.extra_usage?.utilization

            let sourceLabels = account.sourceLabels.isEmpty ? [sourceLabel(account.source)] : account.sourceLabels
            let authUsageSummary = sourceSummary(sourceLabels, fallback: "Unknown")
            let identity = await resolveAccountIdentity(workingAccount)

            logger.info("Claude usage fetched (\(authUsageSummary)): 7d=\(utilization)%, 5h=\(fiveHourUsage?.description ?? "N/A")%")
            logger.debug("Claude account identity (\(authUsageSummary)): dedupeKey=\(identity.dedupeKey), accountId=\(identity.accountId ?? "nil"), email=\(identity.email ?? "nil")")

            if let extraUsageEnabled {
                let limitUSD = (extraUsageMonthlyLimitCredits ?? 0) / 100.0
                let usedUSD = (extraUsageUsedCredits ?? 0) / 100.0
                logger.info(
                    "Claude extra usage (\(authUsageSummary)): enabled=\(extraUsageEnabled), limit=$\(String(format: "%.2f", limitUSD)), used=$\(String(format: "%.2f", usedUSD)), utilization=\(extraUsageUtilizationPercent?.description ?? "nil")"
                )
            }

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
                extraUsageMonthlyLimitUSD: extraUsageMonthlyLimitCredits.map { $0 / 100.0 },
                extraUsageUsedUSD: extraUsageUsedCredits.map { $0 / 100.0 },
                extraUsageUtilizationPercent: extraUsageUtilizationPercent,
                email: identity.email,
                authSource: workingAccount.authSource,
                authUsageSummary: authUsageSummary
            )

            return ClaudeAccountCandidate(
                dedupeKey: identity.dedupeKey,
                accountId: identity.displayAccountId,
                usage: usage,
                details: details,
                sourceLabels: sourceLabels,
                source: account.source,
                hasUsageData: true
            )
        } catch let error as DecodingError {
            logger.error("Failed to decode Claude response: \(error.localizedDescription)")
            throw ProviderError.decodingError("Invalid response format: \(error.localizedDescription)")
        } catch {
            logger.error("Unexpected error parsing Claude response: \(error.localizedDescription)")
            throw ProviderError.providerError("Failed to parse response: \(error.localizedDescription)")
        }
    }

}
