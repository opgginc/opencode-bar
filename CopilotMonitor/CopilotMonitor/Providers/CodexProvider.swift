import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "CodexProvider")

final class CodexProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .codex
    let type: ProviderType = .quotaBased

    private struct RateLimitWindow: Codable {
        let used_percent: Double
        let limit_window_seconds: Int?
        let reset_after_seconds: Int
        let reset_at: Int?
    }

    private struct RateLimit: Codable {
        let allowed: Bool?
        let limit_reached: Bool?
        let primary_window: RateLimitWindow
        let secondary_window: RateLimitWindow?
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

    private struct CodexResponse: Codable {
        let plan_type: String?
        let rate_limit: RateLimit
        let credits: CreditsInfo?
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
            priority: { sourcePriority($0.source) }
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
        let source: OpenAIAuthSource
    }

    private func sourcePriority(_ source: OpenAIAuthSource) -> Int {
        switch source {
        case .opencodeAuth:
            return 2
        case .codexAuth:
            return 1
        }
    }

    private func fetchUsageForAccount(_ account: OpenAIAuthAccount) async throws -> CodexAccountCandidate {
        let endpoint = "https://chatgpt.com/backend-api/wham/usage"
        guard let url = URL(string: endpoint) else {
            logger.error("Invalid Codex API endpoint URL")
            throw ProviderError.networkError("Invalid endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId = account.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        } else {
            logger.warning("Codex account ID missing for \(account.authSource), sending request without account header")
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

        let decoder = JSONDecoder()
        let codexResponse: CodexResponse
        do {
            codexResponse = try decoder.decode(CodexResponse.self, from: data)
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

        let primaryWindow = codexResponse.rate_limit.primary_window
        let secondaryWindow = codexResponse.rate_limit.secondary_window
        let primaryUsedPercent = primaryWindow.used_percent
        let primaryResetSeconds = primaryWindow.reset_after_seconds
        let secondaryUsedPercent = secondaryWindow?.used_percent ?? 0.0
        let secondaryResetSeconds = secondaryWindow?.reset_after_seconds ?? 0

        let now = Date()
        let primaryResetDate = now.addingTimeInterval(TimeInterval(primaryResetSeconds))
        let secondaryResetDate = secondaryWindow != nil ? now.addingTimeInterval(TimeInterval(secondaryResetSeconds)) : nil

        let remaining = Int(100 - primaryUsedPercent)
        let details = DetailedUsage(
            dailyUsage: primaryUsedPercent,
            secondaryUsage: secondaryUsedPercent,
            secondaryReset: secondaryResetDate,
            primaryReset: primaryResetDate,
            creditsBalance: codexResponse.credits?.balanceAsDouble,
            planType: codexResponse.plan_type,
            authSource: account.authSource
        )

        logger.info("Codex usage fetched (\(account.authSource)): primary=\(primaryUsedPercent)%, secondary=\(secondaryUsedPercent)%, plan=\(codexResponse.plan_type ?? "unknown")")

        let usage = ProviderUsage.quotaBased(remaining: remaining, entitlement: 100, overagePermitted: false)
        return CodexAccountCandidate(
            accountId: account.accountId,
            usage: usage,
            details: details,
            source: account.source
        )
    }

    private func isSameUsage(_ lhs: CodexAccountCandidate, _ rhs: CodexAccountCandidate) -> Bool {
        let primaryMatch = lhs.details.dailyUsage == rhs.details.dailyUsage
        let secondaryMatch = lhs.details.secondaryUsage == rhs.details.secondaryUsage
        let primaryResetMatch = sameDate(lhs.details.primaryReset, rhs.details.primaryReset)
        let secondaryResetMatch = sameDate(lhs.details.secondaryReset, rhs.details.secondaryReset)
        return primaryMatch && secondaryMatch && primaryResetMatch && secondaryResetMatch
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
