import Foundation

struct ProviderResult {
    let usage: ProviderUsage
    let details: DetailedUsage?
    let accounts: [ProviderAccountResult]?

    init(
        usage: ProviderUsage,
        details: DetailedUsage?,
        accounts: [ProviderAccountResult]? = nil
    ) {
        self.usage = usage
        self.details = details
        self.accounts = accounts
    }
}

/// Per-account usage for providers that support multiple accounts
struct ProviderAccountResult {
    let accountIndex: Int
    let accountId: String?
    let usage: ProviderUsage
    let details: DetailedUsage?
}

struct GeminiAccountQuota: Codable {
    let accountIndex: Int
    let email: String
    let accountId: String?
    let remainingPercentage: Double
    let modelBreakdown: [String: Double]
    let authSource: String
    let authUsageSummary: String?
    /// Earliest reset time among all model quotas for this account
    let earliestReset: Date?
    /// Reset time for each model (key: modelId, value: reset date)
    let modelResetTimes: [String: Date]

    init(
        accountIndex: Int,
        email: String,
        accountId: String? = nil,
        remainingPercentage: Double,
        modelBreakdown: [String: Double],
        authSource: String,
        authUsageSummary: String? = nil,
        earliestReset: Date?,
        modelResetTimes: [String: Date]
    ) {
        self.accountIndex = accountIndex
        self.email = email
        self.accountId = accountId
        self.remainingPercentage = remainingPercentage
        self.modelBreakdown = modelBreakdown
        self.authSource = authSource
        self.authUsageSummary = authUsageSummary
        self.earliestReset = earliestReset
        self.modelResetTimes = modelResetTimes
    }
}

struct DetailedUsage {
    // Original fields
    let dailyUsage: Double?
    let weeklyUsage: Double?
    let monthlyUsage: Double?
    let totalCredits: Double?
    let remainingCredits: Double?
    let limit: Double?
    let limitRemaining: Double?
    let resetPeriod: String?

    // Claude-specific fields (5h/7d windows)
    let fiveHourUsage: Double?
    let fiveHourReset: Date?
    let sevenDayUsage: Double?
    let sevenDayReset: Date?

    // Claude model breakdown
    let sonnetUsage: Double?
    let sonnetReset: Date?
    let opusUsage: Double?
    let opusReset: Date?

    // Generic model breakdown (Gemini, Antigravity)
    let modelBreakdown: [String: Double]?
    /// Reset time for each model (key: model label/id, value: reset date)
    let modelResetTimes: [String: Date]?

    // Codex-specific fields (multiple windows)
    let secondaryUsage: Double?
    let secondaryReset: Date?
    let primaryReset: Date?
    let sparkUsage: Double?
    let sparkReset: Date?
    let sparkSecondaryUsage: Double?
    let sparkSecondaryReset: Date?
    let sparkWindowLabel: String?

    // Codex/Antigravity plan info
    let creditsBalance: Double?
    let planType: String?

    // Claude extra usage toggle
    let extraUsageEnabled: Bool?
    // Claude extra usage (monthly credits limit + usage)
    let extraUsageMonthlyLimitUSD: Double?
    let extraUsageUsedUSD: Double?
    let extraUsageUtilizationPercent: Double?

    // OpenCode Zen stats
    let sessions: Int?
    let messages: Int?
    let avgCostPerDay: Double?

    // var: mutated during candidate merging for email fallback
    var email: String?

    // History and cost tracking
    let dailyHistory: [DailyUsage]?
    let monthlyCost: Double?
    let creditsRemaining: Double?
    let creditsTotal: Double?

    // Authentication source info (displayed as "Token From:" or "Cookies From:")
    var authSource: String?
    // Human-friendly source labels (displayed as "Using in:")
    var authUsageSummary: String?
    // Authentication failure hint for account-level fallback rows.
    var authErrorMessage: String?

    // Multiple Gemini accounts support
    let geminiAccounts: [GeminiAccountQuota]?

    // Z.ai monitoring fields
    let tokenUsagePercent: Double?
    let tokenUsageReset: Date?
    let tokenUsageUsed: Int?
    let tokenUsageTotal: Int?
    let mcpUsagePercent: Double?
    let mcpUsageReset: Date?
    let mcpUsageUsed: Int?
    let mcpUsageTotal: Int?
    let modelUsageTokens: Int?
    let modelUsageCalls: Int?
    let toolNetworkSearchCount: Int?
    let toolWebReadCount: Int?
    let toolZreadCount: Int?

    // Copilot-specific fields (overage tracking)
    let copilotOverageCost: Double?
    let copilotOverageRequests: Double?
    let copilotUsedRequests: Int?
    let copilotLimitRequests: Int?
    let copilotQuotaResetDateUTC: Date?

    init(
        dailyUsage: Double? = nil,
        weeklyUsage: Double? = nil,
        monthlyUsage: Double? = nil,
        totalCredits: Double? = nil,
        remainingCredits: Double? = nil,
        limit: Double? = nil,
        limitRemaining: Double? = nil,
        resetPeriod: String? = nil,
        fiveHourUsage: Double? = nil,
        fiveHourReset: Date? = nil,
        sevenDayUsage: Double? = nil,
        sevenDayReset: Date? = nil,
        sonnetUsage: Double? = nil,
        sonnetReset: Date? = nil,
        opusUsage: Double? = nil,
        opusReset: Date? = nil,
        modelBreakdown: [String: Double]? = nil,
        modelResetTimes: [String: Date]? = nil,
        secondaryUsage: Double? = nil,
        secondaryReset: Date? = nil,
        primaryReset: Date? = nil,
        sparkUsage: Double? = nil,
        sparkReset: Date? = nil,
        sparkSecondaryUsage: Double? = nil,
        sparkSecondaryReset: Date? = nil,
        sparkWindowLabel: String? = nil,
        creditsBalance: Double? = nil,
        planType: String? = nil,
        extraUsageEnabled: Bool? = nil,
        extraUsageMonthlyLimitUSD: Double? = nil,
        extraUsageUsedUSD: Double? = nil,
        extraUsageUtilizationPercent: Double? = nil,
        sessions: Int? = nil,
        messages: Int? = nil,
        avgCostPerDay: Double? = nil,
        email: String? = nil,
        dailyHistory: [DailyUsage]? = nil,
        monthlyCost: Double? = nil,
        creditsRemaining: Double? = nil,
        creditsTotal: Double? = nil,
        authSource: String? = nil,
        authUsageSummary: String? = nil,
        authErrorMessage: String? = nil,
        geminiAccounts: [GeminiAccountQuota]? = nil,
        tokenUsagePercent: Double? = nil,
        tokenUsageReset: Date? = nil,
        tokenUsageUsed: Int? = nil,
        tokenUsageTotal: Int? = nil,
        mcpUsagePercent: Double? = nil,
        mcpUsageReset: Date? = nil,
        mcpUsageUsed: Int? = nil,
        mcpUsageTotal: Int? = nil,
        modelUsageTokens: Int? = nil,
        modelUsageCalls: Int? = nil,
        toolNetworkSearchCount: Int? = nil,
        toolWebReadCount: Int? = nil,
        toolZreadCount: Int? = nil,
        copilotOverageCost: Double? = nil,
        copilotOverageRequests: Double? = nil,
        copilotUsedRequests: Int? = nil,
        copilotLimitRequests: Int? = nil,
        copilotQuotaResetDateUTC: Date? = nil
    ) {
        self.dailyUsage = dailyUsage
        self.weeklyUsage = weeklyUsage
        self.monthlyUsage = monthlyUsage
        self.totalCredits = totalCredits
        self.remainingCredits = remainingCredits
        self.limit = limit
        self.limitRemaining = limitRemaining
        self.resetPeriod = resetPeriod
        self.fiveHourUsage = fiveHourUsage
        self.fiveHourReset = fiveHourReset
        self.sevenDayUsage = sevenDayUsage
        self.sevenDayReset = sevenDayReset
        self.sonnetUsage = sonnetUsage
        self.sonnetReset = sonnetReset
        self.opusUsage = opusUsage
        self.opusReset = opusReset
        self.modelBreakdown = modelBreakdown
        self.modelResetTimes = modelResetTimes
        self.secondaryUsage = secondaryUsage
        self.secondaryReset = secondaryReset
        self.primaryReset = primaryReset
        self.sparkUsage = sparkUsage
        self.sparkReset = sparkReset
        self.sparkSecondaryUsage = sparkSecondaryUsage
        self.sparkSecondaryReset = sparkSecondaryReset
        self.sparkWindowLabel = sparkWindowLabel
        self.creditsBalance = creditsBalance
        self.planType = planType
        self.extraUsageEnabled = extraUsageEnabled
        self.extraUsageMonthlyLimitUSD = extraUsageMonthlyLimitUSD
        self.extraUsageUsedUSD = extraUsageUsedUSD
        self.extraUsageUtilizationPercent = extraUsageUtilizationPercent
        self.sessions = sessions
        self.messages = messages
        self.avgCostPerDay = avgCostPerDay
        self.email = email
        self.dailyHistory = dailyHistory
        self.monthlyCost = monthlyCost
        self.creditsRemaining = creditsRemaining
        self.creditsTotal = creditsTotal
        self.authSource = authSource
        self.authUsageSummary = authUsageSummary
        self.authErrorMessage = authErrorMessage
        self.geminiAccounts = geminiAccounts
        self.tokenUsagePercent = tokenUsagePercent
        self.tokenUsageReset = tokenUsageReset
        self.tokenUsageUsed = tokenUsageUsed
        self.tokenUsageTotal = tokenUsageTotal
        self.mcpUsagePercent = mcpUsagePercent
        self.mcpUsageReset = mcpUsageReset
        self.mcpUsageUsed = mcpUsageUsed
        self.mcpUsageTotal = mcpUsageTotal
        self.modelUsageTokens = modelUsageTokens
        self.modelUsageCalls = modelUsageCalls
        self.toolNetworkSearchCount = toolNetworkSearchCount
        self.toolWebReadCount = toolWebReadCount
        self.toolZreadCount = toolZreadCount
        self.copilotOverageCost = copilotOverageCost
        self.copilotOverageRequests = copilotOverageRequests
        self.copilotUsedRequests = copilotUsedRequests
        self.copilotLimitRequests = copilotLimitRequests
        self.copilotQuotaResetDateUTC = copilotQuotaResetDateUTC
    }
}

extension DetailedUsage: Codable {
    enum CodingKeys: String, CodingKey {
        case dailyUsage, weeklyUsage, monthlyUsage, totalCredits, remainingCredits
        case limit, limitRemaining, resetPeriod
        case fiveHourUsage, fiveHourReset, sevenDayUsage, sevenDayReset
        case sonnetUsage, sonnetReset, opusUsage, opusReset, modelBreakdown, modelResetTimes
        case secondaryUsage, secondaryReset, primaryReset
        case sparkUsage, sparkReset, sparkSecondaryUsage, sparkSecondaryReset, sparkWindowLabel
        case creditsBalance, planType, extraUsageEnabled
        case extraUsageMonthlyLimitUSD, extraUsageUsedUSD, extraUsageUtilizationPercent
        case sessions, messages, avgCostPerDay, email
        case dailyHistory, monthlyCost, creditsRemaining, creditsTotal
        case authSource, authUsageSummary, authErrorMessage, geminiAccounts
        case tokenUsagePercent, tokenUsageReset, tokenUsageUsed, tokenUsageTotal
        case mcpUsagePercent, mcpUsageReset, mcpUsageUsed, mcpUsageTotal
        case modelUsageTokens, modelUsageCalls
        case toolNetworkSearchCount, toolWebReadCount, toolZreadCount
        case copilotOverageCost, copilotOverageRequests, copilotUsedRequests, copilotLimitRequests, copilotQuotaResetDateUTC
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dailyUsage = try container.decodeIfPresent(Double.self, forKey: .dailyUsage)
        weeklyUsage = try container.decodeIfPresent(Double.self, forKey: .weeklyUsage)
        monthlyUsage = try container.decodeIfPresent(Double.self, forKey: .monthlyUsage)
        totalCredits = try container.decodeIfPresent(Double.self, forKey: .totalCredits)
        remainingCredits = try container.decodeIfPresent(Double.self, forKey: .remainingCredits)
        limit = try container.decodeIfPresent(Double.self, forKey: .limit)
        limitRemaining = try container.decodeIfPresent(Double.self, forKey: .limitRemaining)
        resetPeriod = try container.decodeIfPresent(String.self, forKey: .resetPeriod)
        fiveHourUsage = try container.decodeIfPresent(Double.self, forKey: .fiveHourUsage)
        fiveHourReset = try container.decodeIfPresent(Date.self, forKey: .fiveHourReset)
        sevenDayUsage = try container.decodeIfPresent(Double.self, forKey: .sevenDayUsage)
        sevenDayReset = try container.decodeIfPresent(Date.self, forKey: .sevenDayReset)
        sonnetUsage = try container.decodeIfPresent(Double.self, forKey: .sonnetUsage)
        sonnetReset = try container.decodeIfPresent(Date.self, forKey: .sonnetReset)
        opusUsage = try container.decodeIfPresent(Double.self, forKey: .opusUsage)
        opusReset = try container.decodeIfPresent(Date.self, forKey: .opusReset)
        modelBreakdown = try container.decodeIfPresent([String: Double].self, forKey: .modelBreakdown)
        modelResetTimes = try container.decodeIfPresent([String: Date].self, forKey: .modelResetTimes)
        secondaryUsage = try container.decodeIfPresent(Double.self, forKey: .secondaryUsage)
        secondaryReset = try container.decodeIfPresent(Date.self, forKey: .secondaryReset)
        primaryReset = try container.decodeIfPresent(Date.self, forKey: .primaryReset)
        sparkUsage = try container.decodeIfPresent(Double.self, forKey: .sparkUsage)
        sparkReset = try container.decodeIfPresent(Date.self, forKey: .sparkReset)
        sparkSecondaryUsage = try container.decodeIfPresent(Double.self, forKey: .sparkSecondaryUsage)
        sparkSecondaryReset = try container.decodeIfPresent(Date.self, forKey: .sparkSecondaryReset)
        sparkWindowLabel = try container.decodeIfPresent(String.self, forKey: .sparkWindowLabel)
        creditsBalance = try container.decodeIfPresent(Double.self, forKey: .creditsBalance)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
        extraUsageEnabled = try container.decodeIfPresent(Bool.self, forKey: .extraUsageEnabled)
        extraUsageMonthlyLimitUSD = try container.decodeIfPresent(Double.self, forKey: .extraUsageMonthlyLimitUSD)
        extraUsageUsedUSD = try container.decodeIfPresent(Double.self, forKey: .extraUsageUsedUSD)
        extraUsageUtilizationPercent = try container.decodeIfPresent(Double.self, forKey: .extraUsageUtilizationPercent)
        sessions = try container.decodeIfPresent(Int.self, forKey: .sessions)
        messages = try container.decodeIfPresent(Int.self, forKey: .messages)
        avgCostPerDay = try container.decodeIfPresent(Double.self, forKey: .avgCostPerDay)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        dailyHistory = try container.decodeIfPresent([DailyUsage].self, forKey: .dailyHistory)
        monthlyCost = try container.decodeIfPresent(Double.self, forKey: .monthlyCost)
        creditsRemaining = try container.decodeIfPresent(Double.self, forKey: .creditsRemaining)
        creditsTotal = try container.decodeIfPresent(Double.self, forKey: .creditsTotal)
        authSource = try container.decodeIfPresent(String.self, forKey: .authSource)
        authUsageSummary = try container.decodeIfPresent(String.self, forKey: .authUsageSummary)
        authErrorMessage = try container.decodeIfPresent(String.self, forKey: .authErrorMessage)
        geminiAccounts = try container.decodeIfPresent([GeminiAccountQuota].self, forKey: .geminiAccounts)
        tokenUsagePercent = try container.decodeIfPresent(Double.self, forKey: .tokenUsagePercent)
        tokenUsageReset = try container.decodeIfPresent(Date.self, forKey: .tokenUsageReset)
        tokenUsageUsed = try container.decodeIfPresent(Int.self, forKey: .tokenUsageUsed)
        tokenUsageTotal = try container.decodeIfPresent(Int.self, forKey: .tokenUsageTotal)
        mcpUsagePercent = try container.decodeIfPresent(Double.self, forKey: .mcpUsagePercent)
        mcpUsageReset = try container.decodeIfPresent(Date.self, forKey: .mcpUsageReset)
        mcpUsageUsed = try container.decodeIfPresent(Int.self, forKey: .mcpUsageUsed)
        mcpUsageTotal = try container.decodeIfPresent(Int.self, forKey: .mcpUsageTotal)
        modelUsageTokens = try container.decodeIfPresent(Int.self, forKey: .modelUsageTokens)
        modelUsageCalls = try container.decodeIfPresent(Int.self, forKey: .modelUsageCalls)
        toolNetworkSearchCount = try container.decodeIfPresent(Int.self, forKey: .toolNetworkSearchCount)
        toolWebReadCount = try container.decodeIfPresent(Int.self, forKey: .toolWebReadCount)
        toolZreadCount = try container.decodeIfPresent(Int.self, forKey: .toolZreadCount)
        copilotOverageCost = try container.decodeIfPresent(Double.self, forKey: .copilotOverageCost)
        copilotOverageRequests = try container.decodeIfPresent(Double.self, forKey: .copilotOverageRequests)
        copilotUsedRequests = try container.decodeIfPresent(Int.self, forKey: .copilotUsedRequests)
        copilotLimitRequests = try container.decodeIfPresent(Int.self, forKey: .copilotLimitRequests)
        copilotQuotaResetDateUTC = try container.decodeIfPresent(Date.self, forKey: .copilotQuotaResetDateUTC)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(dailyUsage, forKey: .dailyUsage)
        try container.encodeIfPresent(weeklyUsage, forKey: .weeklyUsage)
        try container.encodeIfPresent(monthlyUsage, forKey: .monthlyUsage)
        try container.encodeIfPresent(totalCredits, forKey: .totalCredits)
        try container.encodeIfPresent(remainingCredits, forKey: .remainingCredits)
        try container.encodeIfPresent(limit, forKey: .limit)
        try container.encodeIfPresent(limitRemaining, forKey: .limitRemaining)
        try container.encodeIfPresent(resetPeriod, forKey: .resetPeriod)
        try container.encodeIfPresent(fiveHourUsage, forKey: .fiveHourUsage)
        try container.encodeIfPresent(fiveHourReset, forKey: .fiveHourReset)
        try container.encodeIfPresent(sevenDayUsage, forKey: .sevenDayUsage)
        try container.encodeIfPresent(sevenDayReset, forKey: .sevenDayReset)
        try container.encodeIfPresent(sonnetUsage, forKey: .sonnetUsage)
        try container.encodeIfPresent(sonnetReset, forKey: .sonnetReset)
        try container.encodeIfPresent(opusUsage, forKey: .opusUsage)
        try container.encodeIfPresent(opusReset, forKey: .opusReset)
        try container.encodeIfPresent(modelBreakdown, forKey: .modelBreakdown)
        try container.encodeIfPresent(modelResetTimes, forKey: .modelResetTimes)
        try container.encodeIfPresent(secondaryUsage, forKey: .secondaryUsage)
        try container.encodeIfPresent(secondaryReset, forKey: .secondaryReset)
        try container.encodeIfPresent(primaryReset, forKey: .primaryReset)
        try container.encodeIfPresent(sparkUsage, forKey: .sparkUsage)
        try container.encodeIfPresent(sparkReset, forKey: .sparkReset)
        try container.encodeIfPresent(sparkSecondaryUsage, forKey: .sparkSecondaryUsage)
        try container.encodeIfPresent(sparkSecondaryReset, forKey: .sparkSecondaryReset)
        try container.encodeIfPresent(sparkWindowLabel, forKey: .sparkWindowLabel)
        try container.encodeIfPresent(creditsBalance, forKey: .creditsBalance)
        try container.encodeIfPresent(planType, forKey: .planType)
        try container.encodeIfPresent(extraUsageEnabled, forKey: .extraUsageEnabled)
        try container.encodeIfPresent(extraUsageMonthlyLimitUSD, forKey: .extraUsageMonthlyLimitUSD)
        try container.encodeIfPresent(extraUsageUsedUSD, forKey: .extraUsageUsedUSD)
        try container.encodeIfPresent(extraUsageUtilizationPercent, forKey: .extraUsageUtilizationPercent)
        try container.encodeIfPresent(sessions, forKey: .sessions)
        try container.encodeIfPresent(messages, forKey: .messages)
        try container.encodeIfPresent(avgCostPerDay, forKey: .avgCostPerDay)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(dailyHistory, forKey: .dailyHistory)
        try container.encodeIfPresent(monthlyCost, forKey: .monthlyCost)
        try container.encodeIfPresent(creditsRemaining, forKey: .creditsRemaining)
        try container.encodeIfPresent(creditsTotal, forKey: .creditsTotal)
        try container.encodeIfPresent(authSource, forKey: .authSource)
        try container.encodeIfPresent(authUsageSummary, forKey: .authUsageSummary)
        try container.encodeIfPresent(authErrorMessage, forKey: .authErrorMessage)
        try container.encodeIfPresent(geminiAccounts, forKey: .geminiAccounts)
        try container.encodeIfPresent(tokenUsagePercent, forKey: .tokenUsagePercent)
        try container.encodeIfPresent(tokenUsageReset, forKey: .tokenUsageReset)
        try container.encodeIfPresent(tokenUsageUsed, forKey: .tokenUsageUsed)
        try container.encodeIfPresent(tokenUsageTotal, forKey: .tokenUsageTotal)
        try container.encodeIfPresent(mcpUsagePercent, forKey: .mcpUsagePercent)
        try container.encodeIfPresent(mcpUsageReset, forKey: .mcpUsageReset)
        try container.encodeIfPresent(mcpUsageUsed, forKey: .mcpUsageUsed)
        try container.encodeIfPresent(mcpUsageTotal, forKey: .mcpUsageTotal)
        try container.encodeIfPresent(modelUsageTokens, forKey: .modelUsageTokens)
        try container.encodeIfPresent(modelUsageCalls, forKey: .modelUsageCalls)
        try container.encodeIfPresent(toolNetworkSearchCount, forKey: .toolNetworkSearchCount)
        try container.encodeIfPresent(toolWebReadCount, forKey: .toolWebReadCount)
        try container.encodeIfPresent(toolZreadCount, forKey: .toolZreadCount)
        try container.encodeIfPresent(copilotOverageCost, forKey: .copilotOverageCost)
        try container.encodeIfPresent(copilotOverageRequests, forKey: .copilotOverageRequests)
        try container.encodeIfPresent(copilotUsedRequests, forKey: .copilotUsedRequests)
        try container.encodeIfPresent(copilotLimitRequests, forKey: .copilotLimitRequests)
        try container.encodeIfPresent(copilotQuotaResetDateUTC, forKey: .copilotQuotaResetDateUTC)
    }
}

enum FormatterError: LocalizedError {
    case encodingFailed
    case invalidData

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode data to JSON"
        case .invalidData:
            return "Invalid data format"
        }
    }
}

struct JSONFormatter {
    static func format(_ results: [ProviderIdentifier: ProviderResult]) throws -> String {
        var jsonDict: [String: [String: Any]] = [:]

        for (identifier, result) in results {
            var providerDict: [String: Any] = [:]

            switch result.usage {
            case .payAsYouGo(_, let cost, let resetsAt):
                providerDict["type"] = "pay-as-you-go"
                if let cost = cost {
                    providerDict["cost"] = cost
                }
                if let resetsAt = resetsAt {
                    let formatter = ISO8601DateFormatter()
                    providerDict["resetsAt"] = formatter.string(from: resetsAt)
                }

            case .quotaBased(let remaining, let entitlement, let overagePermitted):
                providerDict["type"] = "quota-based"
                providerDict["remaining"] = remaining
                providerDict["entitlement"] = entitlement
                providerDict["overagePermitted"] = overagePermitted
                providerDict["usagePercentage"] = result.usage.usagePercentage
            }

            // Z.AI: include both token and MCP usage percentages
            if identifier == .zaiCodingPlan {
                if let tokenPercent = result.details?.tokenUsagePercent {
                    providerDict["tokenUsagePercent"] = tokenPercent
                }
                if let mcpPercent = result.details?.mcpUsagePercent {
                    providerDict["mcpUsagePercent"] = mcpPercent
                }
            }

            if identifier == .geminiCLI, let accounts = result.details?.geminiAccounts, !accounts.isEmpty {
                var accountsArray: [[String: Any]] = []
                for account in accounts {
                    var accountDict: [String: Any] = [:]
                    accountDict["index"] = account.accountIndex
                    accountDict["email"] = account.email
                    if let accountId = account.accountId, !accountId.isEmpty {
                        accountDict["accountId"] = accountId
                    }
                    accountDict["remainingPercentage"] = account.remainingPercentage
                    accountDict["modelBreakdown"] = account.modelBreakdown
                    accountDict["authSource"] = account.authSource
                    accountsArray.append(accountDict)
                }
                providerDict["accounts"] = accountsArray
            }

            jsonDict[identifier.rawValue] = providerDict
        }

        let jsonData = try JSONSerialization.data(withJSONObject: jsonDict, options: [.prettyPrinted, .sortedKeys])
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw FormatterError.encodingFailed
        }

        return jsonString
    }
}

struct TableFormatter {
    private static let columnWidths = (
        provider: 20,
        type: 15,
        usage: 10,
        metrics: 30
    )

    static func format(_ results: [ProviderIdentifier: ProviderResult]) -> String {
        guard !results.isEmpty else {
            return "No provider data available"
        }

        var output = ""

        output += formatHeader()
        output += "\n"
        output += formatSeparator()
        output += "\n"

        let sortedResults = results.sorted { a, b in
            a.key.displayName < b.key.displayName
        }

        for (identifier, result) in sortedResults {
            if identifier == .geminiCLI,
               let accounts = result.details?.geminiAccounts,
               accounts.count > 1 {
                for account in accounts {
                    output += formatGeminiAccountRow(account: account, allResults: results)
                    output += "\n"
                }
            } else {
                output += formatRow(identifier: identifier, result: result)
                output += "\n"
            }
        }

        return output
    }

    private static func formatHeader() -> String {
        let provider = "Provider".padding(toLength: columnWidths.provider, withPad: " ", startingAt: 0)
        let type = "Type".padding(toLength: columnWidths.type, withPad: " ", startingAt: 0)
        let usage = "Usage".padding(toLength: columnWidths.usage, withPad: " ", startingAt: 0)
        let metrics = "Key Metrics"

        return "\(provider)  \(type)  \(usage)  \(metrics)"
    }

    private static func formatSeparator() -> String {
        let totalWidth = columnWidths.provider + columnWidths.type + columnWidths.usage + 30 + 6
        return String(repeating: "─", count: totalWidth)
    }

    private static func formatRow(identifier: ProviderIdentifier, result: ProviderResult) -> String {
        let providerName = identifier.displayName
        let providerPadded = providerName.padding(toLength: columnWidths.provider, withPad: " ", startingAt: 0)

        let typeStr = getProviderType(result)
        let typePadded = typeStr.padding(toLength: columnWidths.type, withPad: " ", startingAt: 0)

        let usageStr = formatUsagePercentage(identifier: identifier, result: result)
        let usagePadded = usageStr.padding(toLength: columnWidths.usage, withPad: " ", startingAt: 0)

        let metricsStr = formatMetrics(result)

        return "\(providerPadded)  \(typePadded)  \(usagePadded)  \(metricsStr)"
    }

    private static func getProviderType(_ result: ProviderResult) -> String {
        switch result.usage {
        case .payAsYouGo:
            return "Pay-as-you-go"
        case .quotaBased:
            return "Quota-based"
        }
    }

    private static func formatUsagePercentage(identifier: ProviderIdentifier, result: ProviderResult) -> String {
        switch result.usage {
        case .payAsYouGo:
            // Pay-as-you-go doesn't have meaningful usage percentage - show dash
            return "-"
        case .quotaBased:
            // Z.AI: show both token and MCP percentages when both are available
            if identifier == .zaiCodingPlan {
                let percents = [result.details?.tokenUsagePercent, result.details?.mcpUsagePercent].compactMap { $0 }
                if percents.count == 2 {
                    return percents.map { String(format: "%.0f%%", $0) }.joined(separator: ",")
                }
            }
            let percentage = result.usage.usagePercentage
            return String(format: "%.0f%%", percentage)
        }
    }

    private static func formatGeminiAccountRow(
        account: GeminiAccountQuota,
        allResults: [ProviderIdentifier: ProviderResult]
    ) -> String {
        let accountName = "Gemini (#\(account.accountIndex + 1))"
        let providerPadded = accountName.padding(toLength: columnWidths.provider, withPad: " ", startingAt: 0)
        let typePadded = "Quota-based".padding(toLength: columnWidths.type, withPad: " ", startingAt: 0)
        let geminiUsedPercent = 100 - account.remainingPercentage

        // For Antigravity-sourced accounts, show both Gemini CLI % and Antigravity %
        let usageStr: String
        if account.authSource.lowercased().contains("antigravity"),
           let antigravityResult = allResults[.antigravity],
           case .quotaBased(let agRemaining, let agEntitlement, _) = antigravityResult.usage,
           agEntitlement > 0 {
            let antigravityUsedPercent = (Double(agEntitlement - agRemaining) / Double(agEntitlement)) * 100
            usageStr = String(format: "%.0f%%,%.0f%%", geminiUsedPercent, antigravityUsedPercent)
        } else {
            usageStr = String(format: "%.0f%%", geminiUsedPercent)
        }
        let usagePadded = usageStr.padding(toLength: columnWidths.usage, withPad: " ", startingAt: 0)

        let metricsStr: String
        if let accountId = account.accountId, !accountId.isEmpty {
            metricsStr = "\(String(format: "%.0f", account.remainingPercentage))% remaining (\(account.email), id: \(accountId))"
        } else {
            metricsStr = "\(String(format: "%.0f", account.remainingPercentage))% remaining (\(account.email))"
        }

        return "\(providerPadded)  \(typePadded)  \(usagePadded)  \(metricsStr)"
    }

    private static func formatMetrics(_ result: ProviderResult) -> String {
        switch result.usage {
        case .payAsYouGo(_, let cost, let resetsAt):
            var metrics = ""

            if let cost = cost {
                metrics += String(format: "$%.2f spent", cost)
            } else {
                metrics += "Cost unavailable"
            }

            if let resetsAt = resetsAt {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMM d"
                let resetDate = formatter.string(from: resetsAt)
                metrics += " (resets \(resetDate))"
            }

            return metrics

        case .quotaBased(let remaining, let entitlement, let overagePermitted):
            if remaining >= 0 {
                return "\(remaining)/\(entitlement) remaining"
            } else {
                let overage = abs(remaining)
                if overagePermitted {
                    return "\(overage) overage (allowed)"
                } else {
                    return "\(overage) overage (not allowed)"
                }
            }
        }
    }
}

/// Shared helper for deduplicating multi-account provider candidates.
struct CandidateDedupe {
    static func merge<T>(
        _ candidates: [T],
        accountId: (T) -> String?,
        isSameUsage: (T, T) -> Bool,
        priority: (T) -> Int,
        mergeCandidates: ((T, T) -> T)? = nil
    ) -> [T] {
        var results: [T] = []

        for candidate in candidates {
            if let candidateId = accountId(candidate),
               let index = results.firstIndex(where: { accountId($0) == candidateId }) {
                let existing = results[index]
                results[index] = preferredCandidate(
                    incoming: candidate,
                    existing: existing,
                    priority: priority,
                    mergeCandidates: mergeCandidates
                )
                continue
            }

            if let index = results.firstIndex(where: { isSameUsage($0, candidate) }) {
                let existing = results[index]
                results[index] = preferredCandidate(
                    incoming: candidate,
                    existing: existing,
                    priority: priority,
                    mergeCandidates: mergeCandidates
                )
                continue
            }

            results.append(candidate)
        }

        return results
    }

    private static func preferredCandidate<T>(
        incoming: T,
        existing: T,
        priority: (T) -> Int,
        mergeCandidates: ((T, T) -> T)?
    ) -> T {
        let incomingPriority = priority(incoming)
        let existingPriority = priority(existing)

        let preferred: T
        let secondary: T
        if incomingPriority > existingPriority {
            preferred = incoming
            secondary = existing
        } else {
            preferred = existing
            secondary = incoming
        }

        guard let mergeCandidates else {
            return preferred
        }
        return mergeCandidates(preferred, secondary)
    }
}

extension DetailedUsage {
    var hasAnyValue: Bool {
        return dailyUsage != nil || weeklyUsage != nil || monthlyUsage != nil
            || totalCredits != nil || remainingCredits != nil
            || limit != nil || limitRemaining != nil || resetPeriod != nil
            || fiveHourUsage != nil || fiveHourReset != nil
            || sevenDayUsage != nil || sevenDayReset != nil
            || sonnetUsage != nil || sonnetReset != nil
            || opusUsage != nil || opusReset != nil
            || modelBreakdown != nil || modelResetTimes != nil
            || secondaryUsage != nil || secondaryReset != nil || primaryReset != nil
            || sparkUsage != nil || sparkReset != nil || sparkSecondaryUsage != nil || sparkSecondaryReset != nil || sparkWindowLabel != nil
            || creditsBalance != nil || planType != nil
            || extraUsageEnabled != nil
            || extraUsageMonthlyLimitUSD != nil || extraUsageUsedUSD != nil || extraUsageUtilizationPercent != nil
            || sessions != nil || messages != nil || avgCostPerDay != nil
            || email != nil
            || dailyHistory != nil || monthlyCost != nil
            || creditsRemaining != nil || creditsTotal != nil
            || authSource != nil || authUsageSummary != nil || authErrorMessage != nil || geminiAccounts != nil
            || tokenUsagePercent != nil || tokenUsageReset != nil
            || tokenUsageUsed != nil || tokenUsageTotal != nil
            || mcpUsagePercent != nil || mcpUsageReset != nil
            || mcpUsageUsed != nil || mcpUsageTotal != nil
            || modelUsageTokens != nil || modelUsageCalls != nil
            || toolNetworkSearchCount != nil || toolWebReadCount != nil || toolZreadCount != nil
            || copilotOverageCost != nil || copilotOverageRequests != nil
            || copilotUsedRequests != nil || copilotLimitRequests != nil
            || copilotQuotaResetDateUTC != nil
    }
}
