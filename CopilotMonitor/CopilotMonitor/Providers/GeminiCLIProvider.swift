import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "GeminiCLIProvider")

// MARK: - Gemini CLI API Response Models

/// Response structure from Gemini CLI quota API
struct GeminiQuotaResponse: Codable {
    struct Bucket: Codable {
        let modelId: String
        let remainingFraction: Double
        let resetTime: String
    }

    let buckets: [Bucket]
}

struct GeminiUserInfoResponse: Codable {
    let email: String?
}

// MARK: - GeminiCLIProvider Implementation

/// Provider for Google Gemini CLI quota tracking via cloudcode-pa.googleapis.com
/// Uses OAuth token refresh from antigravity-accounts.json with fallback to OpenCode auth.json
final class GeminiCLIProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .geminiCLI
    let type: ProviderType = .quotaBased

    private let tokenManager: TokenManager
    private let session: URLSession

    init(tokenManager: TokenManager = .shared, session: URLSession = .shared) {
        self.tokenManager = tokenManager
        self.session = session
    }

    // MARK: - ProviderProtocol Implementation

    func fetch() async throws -> ProviderResult {
        let allAccounts = tokenManager.getAllGeminiAccounts()

        guard !allAccounts.isEmpty else {
            logger.error("No Gemini accounts found")
            throw ProviderError.authenticationFailed("No Gemini accounts configured")
        }

        var candidates: [GeminiAccountCandidate] = []

        for account in allAccounts {
            do {
                let quotaResult = try await fetchQuotaForAccount(account: account)
                candidates.append(GeminiAccountCandidate(quota: quotaResult, source: account.source))
            } catch {
                let displayEmail = account.email?.isEmpty == false ? account.email ?? "" : "unknown"
                logger.warning("Failed to fetch quota for account #\(account.index + 1) (\(displayEmail)): \(error.localizedDescription)")
            }
        }

        guard !candidates.isEmpty else {
            logger.error("Failed to fetch quota for any Gemini account")
            throw ProviderError.providerError("All account quota fetches failed")
        }

        let deduped = dedupeCandidates(candidates)
        let sorted = deduped.sorted { lhs, rhs in
            sourcePriority(lhs.source) > sourcePriority(rhs.source)
        }

        let geminiAccountQuotas: [GeminiAccountQuota] = sorted.enumerated().map { index, candidate in
            let quota = candidate.quota
            return GeminiAccountQuota(
                accountIndex: index,
                email: quota.email,
                remainingPercentage: quota.remainingPercentage,
                modelBreakdown: quota.modelBreakdown,
                authSource: quota.authSource,
                earliestReset: quota.earliestReset,
                modelResetTimes: quota.modelResetTimes
            )
        }

        let overallMinPercentage = geminiAccountQuotas.map { $0.remainingPercentage }.min() ?? 100.0

        logger.info("Gemini CLI: Fetched quota for \(geminiAccountQuotas.count)/\(allAccounts.count) accounts, overall min: \(overallMinPercentage)%")

        let usage = ProviderUsage.quotaBased(
            remaining: Int(overallMinPercentage),
            entitlement: 100,
            overagePermitted: false
        )

        let authSources = Set(geminiAccountQuotas.map { $0.authSource })
        let authSourceSummary: String?
        if authSources.count == 1 {
            authSourceSummary = authSources.first
        } else if authSources.count > 1 {
            authSourceSummary = "Multiple auth sources"
        } else {
            authSourceSummary = nil
        }

        let details = DetailedUsage(
            authSource: authSourceSummary,
            geminiAccounts: geminiAccountQuotas
        )

        return ProviderResult(usage: usage, details: details)
    }

    private struct GeminiAccountCandidate {
        let quota: GeminiAccountQuota
        let source: GeminiAuthSource
    }

    private func sourcePriority(_ source: GeminiAuthSource) -> Int {
        switch source {
        case .opencodeAuth:
            return 2
        case .antigravity:
            return 1
        }
    }

    private func dedupeCandidates(_ candidates: [GeminiAccountCandidate]) -> [GeminiAccountCandidate] {
        var results: [GeminiAccountCandidate] = []

        for candidate in candidates {
            let email = candidate.quota.email.trimmingCharacters(in: .whitespacesAndNewlines)
            if email != "Unknown", !email.isEmpty,
               let index = results.firstIndex(where: { $0.quota.email == email }) {
                if sourcePriority(candidate.source) > sourcePriority(results[index].source) {
                    results[index] = candidate
                }
                continue
            }

            if let index = results.firstIndex(where: { isSameUsage($0.quota, candidate.quota) }) {
                if sourcePriority(candidate.source) > sourcePriority(results[index].source) {
                    results[index] = candidate
                }
                continue
            }

            results.append(candidate)
        }

        return results
    }

    private func isSameUsage(_ lhs: GeminiAccountQuota, _ rhs: GeminiAccountQuota) -> Bool {
        let remainingMatch = lhs.remainingPercentage == rhs.remainingPercentage
        let resetMatch = sameDate(lhs.earliestReset, rhs.earliestReset)
        let modelsMatch = lhs.modelBreakdown == rhs.modelBreakdown
        return remainingMatch && resetMatch && modelsMatch
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

    // MARK: - Private Helpers

    private func fetchQuotaForAccount(account: GeminiAuthAccount) async throws -> GeminiAccountQuota {
        let accountIndex = account.index
        let projectId = account.projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        if projectId.isEmpty {
            throw ProviderError.authenticationFailed("Missing project ID for account #\(accountIndex + 1)")
        }

        guard let accessToken = await tokenManager.refreshGeminiAccessToken(
            refreshToken: account.refreshToken,
            clientId: account.clientId,
            clientSecret: account.clientSecret
        ) else {
            throw ProviderError.authenticationFailed("Unable to refresh token for account #\(accountIndex + 1)")
        }

        let resolvedEmail = await resolveGeminiAccountEmail(primaryEmail: account.email, accessToken: accessToken)
        if resolvedEmail == "Unknown" {
            logger.warning("Gemini CLI: Email lookup failed for account #\(accountIndex + 1)")
        }

        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota") else {
            throw ProviderError.networkError("Invalid API endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // project parameter is required to get all models including gemini-3 variants
        request.httpBody = "{\"project\":\"\(projectId)\"}".data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response type")
        }

        if httpResponse.statusCode == 401 {
            throw ProviderError.authenticationFailed("Token expired for account #\(accountIndex + 1)")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }

        let quotaResponse = try JSONDecoder().decode(GeminiQuotaResponse.self, from: data)

        guard !quotaResponse.buckets.isEmpty else {
            throw ProviderError.decodingError("Empty buckets array")
        }

        var modelBreakdown: [String: Double] = [:]
        var modelResetTimes: [String: Date] = [:]
        var minFraction = 1.0
        var earliestReset: Date?

        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso8601FormatterNoFrac = ISO8601DateFormatter()
        iso8601FormatterNoFrac.formatOptions = [.withInternetDateTime]

        for bucket in quotaResponse.buckets {
            let percentage = bucket.remainingFraction * 100.0
            modelBreakdown[bucket.modelId] = percentage
            minFraction = min(minFraction, bucket.remainingFraction)

            if let resetDate = iso8601Formatter.date(from: bucket.resetTime)
                ?? iso8601FormatterNoFrac.date(from: bucket.resetTime) {
                modelResetTimes[bucket.modelId] = resetDate
                if let current = earliestReset {
                    earliestReset = min(current, resetDate)
                } else {
                    earliestReset = resetDate
                }
            }
        }

        let remainingPercentage = minFraction * 100.0

        logger.info("Gemini CLI account #\(accountIndex + 1) (\(resolvedEmail)): \(remainingPercentage)% remaining, resets: \(earliestReset?.description ?? "unknown")")

        return GeminiAccountQuota(
            accountIndex: accountIndex,
            email: resolvedEmail,
            remainingPercentage: remainingPercentage,
            modelBreakdown: modelBreakdown,
            authSource: account.authSource,
            earliestReset: earliestReset,
            modelResetTimes: modelResetTimes
        )
    }

    private func resolveGeminiAccountEmail(primaryEmail: String?, accessToken: String) async -> String {
        if let email = primaryEmail?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            return email
        }

        if let fetchedEmail = await fetchGeminiUserEmail(accessToken: accessToken) {
            return fetchedEmail
        }

        return "Unknown"
    }

    private func fetchGeminiUserEmail(accessToken: String) async -> String? {
        guard let url = URL(string: "https://www.googleapis.com/oauth2/v1/userinfo?alt=json") else {
            logger.warning("Gemini CLI: Invalid userinfo endpoint URL")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                logger.warning("Gemini CLI: Invalid response type from userinfo endpoint")
                return nil
            }

            guard httpResponse.statusCode == 200 else {
                logger.warning("Gemini CLI: Userinfo request failed with status \(httpResponse.statusCode)")
                return nil
            }

            let payload = try JSONDecoder().decode(GeminiUserInfoResponse.self, from: data)
            return payload.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            logger.warning("Gemini CLI: Failed to fetch user email: \(error.localizedDescription)")
            return nil
        }
    }
}
