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

    // Chutes-specific value cap tracking
    let chutesMonthlyValueCapUSD: Double?
    let chutesMonthlyValueUsedUSD: Double?
    let chutesMonthlyValueUsedPercent: Double?

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
        chutesMonthlyValueCapUSD: Double? = nil,
        chutesMonthlyValueUsedUSD: Double? = nil,
        chutesMonthlyValueUsedPercent: Double? = nil,
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
        self.chutesMonthlyValueCapUSD = chutesMonthlyValueCapUSD
        self.chutesMonthlyValueUsedUSD = chutesMonthlyValueUsedUSD
        self.chutesMonthlyValueUsedPercent = chutesMonthlyValueUsedPercent
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
        case creditsBalance, planType
        case chutesMonthlyValueCapUSD, chutesMonthlyValueUsedUSD, chutesMonthlyValueUsedPercent
        case extraUsageEnabled
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
        chutesMonthlyValueCapUSD = try container.decodeIfPresent(Double.self, forKey: .chutesMonthlyValueCapUSD)
        chutesMonthlyValueUsedUSD = try container.decodeIfPresent(Double.self, forKey: .chutesMonthlyValueUsedUSD)
        chutesMonthlyValueUsedPercent = try container.decodeIfPresent(Double.self, forKey: .chutesMonthlyValueUsedPercent)
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
        try container.encodeIfPresent(chutesMonthlyValueCapUSD, forKey: .chutesMonthlyValueCapUSD)
        try container.encodeIfPresent(chutesMonthlyValueUsedUSD, forKey: .chutesMonthlyValueUsedUSD)
        try container.encodeIfPresent(chutesMonthlyValueUsedPercent, forKey: .chutesMonthlyValueUsedPercent)
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
                if entitlement == Int.max {
                    providerDict["remaining"] = "unlimited"
                    providerDict["entitlement"] = "unlimited"
                } else {
                    providerDict["remaining"] = remaining
                    providerDict["entitlement"] = entitlement
                }
                providerDict["overagePermitted"] = overagePermitted
                providerDict["usagePercentage"] = entitlement == Int.max ? 0.0 : result.usage.usagePercentage
            }

            if identifier == .minimaxCodingPlan {
                if let fiveHourUsage = result.details?.fiveHourUsage {
                    providerDict["fiveHourUsage"] = fiveHourUsage
                }
                if let sevenDayUsage = result.details?.sevenDayUsage {
                    providerDict["sevenDayUsage"] = sevenDayUsage
                }
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

            if let accounts = result.accounts, accounts.count > 1 {
                var accountsArray: [[String: Any]] = []
                for account in accounts {
                    var accountDict: [String: Any] = [:]
                    accountDict["index"] = account.accountIndex
                    if let accountId = account.accountId {
                        accountDict["accountId"] = accountId
                    }
                    if let authSource = account.details?.authSource {
                        accountDict["authSource"] = authSource
                    }
                    accountDict["usagePercentage"] = account.usage.usagePercentage

                    switch account.usage {
                    case .quotaBased(let remaining, let entitlement, let overagePermitted):
                        if entitlement == Int.max {
                            accountDict["remaining"] = "unlimited"
                            accountDict["entitlement"] = "unlimited"
                        } else {
                            accountDict["remaining"] = remaining
                            accountDict["entitlement"] = entitlement
                        }
                        accountDict["overagePermitted"] = overagePermitted
                    case .payAsYouGo(_, let cost, _):
                        if let cost = cost {
                            accountDict["cost"] = cost
                        }
                    }

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
    private static let minProviderWidth = 20
    private static let typeWidth = 15
    private static let usageWidth = 10

    private static func isUnlimitedEntitlement(_ entitlement: Int) -> Bool {
        entitlement == Int.max
    }

    private static func formatQuotaUsagePercentage(remaining: Int, entitlement: Int) -> String {
        if isUnlimitedEntitlement(entitlement) {
            return "0%"
        }

        guard entitlement > 0 else { return "0%" }
        let used = entitlement - remaining
        let percentage = (Double(used) / Double(entitlement)) * 100
        return String(format: "%.0f%%", percentage)
    }

    private static func formatQuotaMetrics(remaining: Int, entitlement: Int, overagePermitted: Bool) -> String {
        if isUnlimitedEntitlement(entitlement) {
            let remainingLabel = (remaining == Int.max) ? "∞" : "\(remaining)"
            return "\(remainingLabel)/Unlimited remaining"
        }

        if remaining >= 0 {
            return "\(remaining)/\(entitlement) remaining"
        }

        let overage = abs(remaining)
        return overagePermitted ? "\(overage) overage (allowed)" : "\(overage) overage (not allowed)"
    }

    private static func accountLabel(identifier: ProviderIdentifier, account: ProviderAccountResult) -> String {
        if let accountId = account.accountId, !accountId.isEmpty {
            return "\(identifier.displayName) (\(accountId))"
        } else {
            return "\(identifier.displayName) (#\(account.accountIndex + 1))"
        }
    }

    private static func geminiLabel(account: GeminiAccountQuota) -> String {
        return "Gemini (#\(account.accountIndex + 1))"
    }

    private static func shortenAuthSource(_ source: String) -> String {
        if source.hasPrefix("/") || source.hasPrefix("~") {
            return (source as NSString).lastPathComponent
        }
        return source
    }

    private static func computeMetricsWidth(
        _ sortedResults: [(key: ProviderIdentifier, value: ProviderResult)]
    ) -> Int {
        let minMetricsWidth = 30
        var maxWidth = minMetricsWidth
        for (identifier, result) in sortedResults {
            if identifier == .geminiCLI,
               let accounts = result.details?.geminiAccounts,
               accounts.count > 1 {
                for account in accounts {
                    let metricsStr: String
                    if let accountId = account.accountId, !accountId.isEmpty {
                        metricsStr = "\(String(format: "%.0f", account.remainingPercentage))% remaining (\(account.email), id: \(accountId))"
                    } else {
                        metricsStr = "\(String(format: "%.0f", account.remainingPercentage))% remaining (\(account.email))"
                    }
                    maxWidth = max(maxWidth, metricsStr.count)
                }
            } else if let accounts = result.accounts, accounts.count > 1 {
                for account in accounts {
                    let metricsStr: String
                    switch account.usage {
                    case .payAsYouGo(_, let cost, _):
                        if let cost = cost {
                            metricsStr = String(format: "$%.2f spent", cost)
                        } else {
                            metricsStr = "Cost unavailable"
                        }
                    case .quotaBased(let remaining, let entitlement, let overagePermitted):
                        metricsStr = formatQuotaMetrics(
                            remaining: remaining,
                            entitlement: entitlement,
                            overagePermitted: overagePermitted
                        )
                    }
                    let source = account.details?.authSource ?? ""
                    let sourceLabel = source.isEmpty ? "" : " [\(shortenAuthSource(source))]"
                    maxWidth = max(maxWidth, metricsStr.count + sourceLabel.count)
                }
            } else {
                maxWidth = max(maxWidth, formatMetrics(result).count)
            }
        }
        return maxWidth
    }

    private static func computeProviderWidth(
        _ sortedResults: [(key: ProviderIdentifier, value: ProviderResult)]
    ) -> Int {
        var maxWidth = minProviderWidth
        for (identifier, result) in sortedResults {
            if identifier == .geminiCLI,
               let accounts = result.details?.geminiAccounts,
               accounts.count > 1 {
                for account in accounts {
                    maxWidth = max(maxWidth, geminiLabel(account: account).count)
                }
            } else if let accounts = result.accounts, accounts.count > 1 {
                for account in accounts {
                    maxWidth = max(maxWidth, accountLabel(identifier: identifier, account: account).count)
                }
            } else {
                maxWidth = max(maxWidth, identifier.displayName.count)
            }
        }
        return maxWidth
    }

    static func format(_ results: [ProviderIdentifier: ProviderResult]) -> String {
        guard !results.isEmpty else {
            return "No provider data available"
        }

        let sortedResults = results.sorted { $0.key.displayName < $1.key.displayName }
        let providerWidth = computeProviderWidth(sortedResults)
        let metricsWidth = computeMetricsWidth(sortedResults)

        var output = ""

        output += formatHeader(providerWidth: providerWidth)
        output += "\n"
        output += formatSeparator(providerWidth: providerWidth, metricsWidth: metricsWidth)
        output += "\n"

        for (identifier, result) in sortedResults {
            if identifier == .geminiCLI,
               let accounts = result.details?.geminiAccounts,
               accounts.count > 1 {
                for account in accounts {
                    output += formatGeminiAccountRow(account: account, providerWidth: providerWidth)
                    output += "\n"
                }
            } else if let accounts = result.accounts, accounts.count > 1 {
                for account in accounts {
                    output += formatAccountRow(identifier: identifier, account: account, providerWidth: providerWidth)
                    output += "\n"
                }
            } else {
                output += formatRow(identifier: identifier, result: result, providerWidth: providerWidth)
                output += "\n"
            }
        }

        return output
    }

    private static func formatHeader(providerWidth: Int) -> String {
        let provider = "Provider".padding(toLength: providerWidth, withPad: " ", startingAt: 0)
        let type = "Type".padding(toLength: typeWidth, withPad: " ", startingAt: 0)
        let usage = "Usage".padding(toLength: usageWidth, withPad: " ", startingAt: 0)
        let metrics = "Key Metrics"

        return "\(provider)  \(type)  \(usage)  \(metrics)"
    }

    private static func formatSeparator(providerWidth: Int, metricsWidth: Int) -> String {
        let totalWidth = providerWidth + typeWidth + usageWidth + metricsWidth + 6
        return String(repeating: "─", count: totalWidth)
    }

    private static func formatRow(identifier: ProviderIdentifier, result: ProviderResult, providerWidth: Int) -> String {
        let providerName = identifier.displayName
        let providerPadded = providerName.padding(toLength: providerWidth, withPad: " ", startingAt: 0)

        let typeStr = getProviderType(result)
        let typePadded = typeStr.padding(toLength: typeWidth, withPad: " ", startingAt: 0)

        let usageStr = formatUsagePercentage(identifier: identifier, result: result)
        let usagePadded = usageStr.padding(toLength: usageWidth, withPad: " ", startingAt: 0)

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
            if identifier == .minimaxCodingPlan {
                let percents = [result.details?.fiveHourUsage, result.details?.sevenDayUsage].compactMap { $0 }
                if percents.count == 2 {
                    return percents.map { String(format: "%.0f%%", $0) }.joined(separator: ",")
                }
            }
            // Z.AI: show both token and MCP percentages when both are available
            if identifier == .zaiCodingPlan {
                let percents = [result.details?.tokenUsagePercent, result.details?.mcpUsagePercent].compactMap { $0 }
                if percents.count == 2 {
                    return percents.map { String(format: "%.0f%%", $0) }.joined(separator: ",")
                }
            }
            switch result.usage {
            case .quotaBased(let remaining, let entitlement, _):
                return formatQuotaUsagePercentage(remaining: remaining, entitlement: entitlement)
            case .payAsYouGo:
                return "-"
            }
        }
    }

    private static func formatGeminiAccountRow(account: GeminiAccountQuota, providerWidth: Int) -> String {
        let label = geminiLabel(account: account)
        let providerPadded = label.padding(toLength: providerWidth, withPad: " ", startingAt: 0)
        let typePadded = "Quota-based".padding(toLength: typeWidth, withPad: " ", startingAt: 0)
        let usageStr = String(format: "%.0f%%", 100 - account.remainingPercentage)
        let usagePadded = usageStr.padding(toLength: usageWidth, withPad: " ", startingAt: 0)

        let metricsStr: String
        if let accountId = account.accountId, !accountId.isEmpty {
            metricsStr = "\(String(format: "%.0f", account.remainingPercentage))% remaining (\(account.email), id: \(accountId))"
        } else {
            metricsStr = "\(String(format: "%.0f", account.remainingPercentage))% remaining (\(account.email))"
        }

        return "\(providerPadded)  \(typePadded)  \(usagePadded)  \(metricsStr)"
    }

    private static func formatAccountRow(identifier: ProviderIdentifier, account: ProviderAccountResult, providerWidth: Int) -> String {
        let label = accountLabel(identifier: identifier, account: account)
        let providerPadded = label.padding(toLength: providerWidth, withPad: " ", startingAt: 0)

        let typeStr: String
        let usageStr: String
        let metricsStr: String

        switch account.usage {
        case .payAsYouGo(_, let cost, _):
            typeStr = "Pay-as-you-go"
            usageStr = "-"
            if let cost = cost {
                metricsStr = String(format: "$%.2f spent", cost)
            } else {
                metricsStr = "Cost unavailable"
            }
        case .quotaBased(let remaining, let entitlement, let overagePermitted):
            typeStr = "Quota-based"
            usageStr = formatQuotaUsagePercentage(remaining: remaining, entitlement: entitlement)
            metricsStr = formatQuotaMetrics(
                remaining: remaining,
                entitlement: entitlement,
                overagePermitted: overagePermitted
            )
        }

        let source = account.details?.authSource ?? ""
        let sourceLabel = source.isEmpty ? "" : " [\(shortenAuthSource(source))]"

        let typePadded = typeStr.padding(toLength: typeWidth, withPad: " ", startingAt: 0)
        let usagePadded = usageStr.padding(toLength: usageWidth, withPad: " ", startingAt: 0)

        return "\(providerPadded)  \(typePadded)  \(usagePadded)  \(metricsStr)\(sourceLabel)"
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
            return formatQuotaMetrics(
                remaining: remaining,
                entitlement: entitlement,
                overagePermitted: overagePermitted
            )
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

/// Shared numeric parser for API response dictionaries.
/// APIs may return Double, Int, NSNumber, or String for numeric fields.
enum APIValueParser {
    static func parseDouble(from dict: [String: Any], keys: [String]) -> Double {
        for key in keys {
            if let value = dict[key] as? Double { return value }
            if let value = dict[key] as? Int { return Double(value) }
            if let value = dict[key] as? NSNumber { return value.doubleValue }
            if let str = dict[key] as? String, let parsed = Double(str) { return parsed }
        }
        return 0.0
    }

    static func parseInt(from dict: [String: Any], keys: [String]) -> Int {
        for key in keys {
            if let value = dict[key] as? Int { return value }
            if let value = dict[key] as? Double { return Int(value) }
            if let value = dict[key] as? NSNumber { return value.intValue }
            if let str = dict[key] as? String, let parsed = Int(str) { return parsed }
        }
        return 0
    }
}

enum ProviderDisplayPolicy {
    static func shouldShowRateLimitedErrorRow(
        identifier: ProviderIdentifier,
        errorMessage: String,
        result: ProviderResult?
    ) -> Bool {
        guard isRateLimitError(errorMessage) else { return false }
        return !hasDisplayableAccountRows(identifier: identifier, result: result)
    }

    static func hasDisplayableAccountRows(
        identifier: ProviderIdentifier,
        result: ProviderResult?
    ) -> Bool {
        guard let result else { return false }

        switch identifier {
        case .claude, .codex, .copilot:
            guard let accounts = result.accounts else { return false }
            return !accounts.isEmpty
        case .geminiCLI:
            guard let accounts = result.details?.geminiAccounts else { return false }
            return !accounts.isEmpty
        default:
            return false
        }
    }

    private static func isRateLimitError(_ errorMessage: String) -> Bool {
        let lowercased = errorMessage.lowercased()
        return lowercased.contains("rate limited")
            || lowercased.contains("rate_limit_error")
            || lowercased.contains("http 429")
            || lowercased.contains("too many requests")
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
            || chutesMonthlyValueCapUSD != nil || chutesMonthlyValueUsedUSD != nil || chutesMonthlyValueUsedPercent != nil
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
