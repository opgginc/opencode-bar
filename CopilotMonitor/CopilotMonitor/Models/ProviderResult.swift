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
    let remainingPercentage: Double
    let modelBreakdown: [String: Double]
    let authSource: String
    /// Earliest reset time among all model quotas for this account
    let earliestReset: Date?
    /// Reset time for each model (key: modelId, value: reset date)
    let modelResetTimes: [String: Date]
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

    // Codex-specific fields (multiple windows)
    let secondaryUsage: Double?
    let secondaryReset: Date?
    let primaryReset: Date?

    // Codex/Antigravity plan info
    let creditsBalance: Double?
    let planType: String?

    // Claude extra usage toggle
    let extraUsageEnabled: Bool?

    // OpenCode Zen stats
    let sessions: Int?
    let messages: Int?
    let avgCostPerDay: Double?

    // Antigravity user email
    let email: String?

    // History and cost tracking
    let dailyHistory: [DailyUsage]?
    let monthlyCost: Double?
    let creditsRemaining: Double?
    let creditsTotal: Double?

    // Authentication source info (displayed as "Token From:" or "Cookies From:")
    let authSource: String?

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
        secondaryUsage: Double? = nil,
        secondaryReset: Date? = nil,
        primaryReset: Date? = nil,
        creditsBalance: Double? = nil,
        planType: String? = nil,
        extraUsageEnabled: Bool? = nil,
        sessions: Int? = nil,
        messages: Int? = nil,
        avgCostPerDay: Double? = nil,
        email: String? = nil,
        dailyHistory: [DailyUsage]? = nil,
        monthlyCost: Double? = nil,
        creditsRemaining: Double? = nil,
        creditsTotal: Double? = nil,
        authSource: String? = nil,
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
        self.secondaryUsage = secondaryUsage
        self.secondaryReset = secondaryReset
        self.primaryReset = primaryReset
        self.creditsBalance = creditsBalance
        self.planType = planType
        self.extraUsageEnabled = extraUsageEnabled
        self.sessions = sessions
        self.messages = messages
        self.avgCostPerDay = avgCostPerDay
        self.email = email
        self.dailyHistory = dailyHistory
        self.monthlyCost = monthlyCost
        self.creditsRemaining = creditsRemaining
        self.creditsTotal = creditsTotal
        self.authSource = authSource
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
        case sonnetUsage, sonnetReset, opusUsage, opusReset, modelBreakdown
        case secondaryUsage, secondaryReset, primaryReset
        case creditsBalance, planType, extraUsageEnabled
        case sessions, messages, avgCostPerDay, email
        case dailyHistory, monthlyCost, creditsRemaining, creditsTotal
        case authSource, geminiAccounts
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
        secondaryUsage = try container.decodeIfPresent(Double.self, forKey: .secondaryUsage)
        secondaryReset = try container.decodeIfPresent(Date.self, forKey: .secondaryReset)
        primaryReset = try container.decodeIfPresent(Date.self, forKey: .primaryReset)
        creditsBalance = try container.decodeIfPresent(Double.self, forKey: .creditsBalance)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
        extraUsageEnabled = try container.decodeIfPresent(Bool.self, forKey: .extraUsageEnabled)
        sessions = try container.decodeIfPresent(Int.self, forKey: .sessions)
        messages = try container.decodeIfPresent(Int.self, forKey: .messages)
        avgCostPerDay = try container.decodeIfPresent(Double.self, forKey: .avgCostPerDay)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        dailyHistory = try container.decodeIfPresent([DailyUsage].self, forKey: .dailyHistory)
        monthlyCost = try container.decodeIfPresent(Double.self, forKey: .monthlyCost)
        creditsRemaining = try container.decodeIfPresent(Double.self, forKey: .creditsRemaining)
        creditsTotal = try container.decodeIfPresent(Double.self, forKey: .creditsTotal)
        authSource = try container.decodeIfPresent(String.self, forKey: .authSource)
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
        try container.encodeIfPresent(secondaryUsage, forKey: .secondaryUsage)
        try container.encodeIfPresent(secondaryReset, forKey: .secondaryReset)
        try container.encodeIfPresent(primaryReset, forKey: .primaryReset)
        try container.encodeIfPresent(creditsBalance, forKey: .creditsBalance)
        try container.encodeIfPresent(planType, forKey: .planType)
        try container.encodeIfPresent(extraUsageEnabled, forKey: .extraUsageEnabled)
        try container.encodeIfPresent(sessions, forKey: .sessions)
        try container.encodeIfPresent(messages, forKey: .messages)
        try container.encodeIfPresent(avgCostPerDay, forKey: .avgCostPerDay)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(dailyHistory, forKey: .dailyHistory)
        try container.encodeIfPresent(monthlyCost, forKey: .monthlyCost)
        try container.encodeIfPresent(creditsRemaining, forKey: .creditsRemaining)
        try container.encodeIfPresent(creditsTotal, forKey: .creditsTotal)
        try container.encodeIfPresent(authSource, forKey: .authSource)
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

/// Shared helper for deduplicating multi-account provider candidates.
struct CandidateDedupe {
    static func merge<T>(
        _ candidates: [T],
        accountId: (T) -> String?,
        isSameUsage: (T, T) -> Bool,
        priority: (T) -> Int
    ) -> [T] {
        var results: [T] = []

        for candidate in candidates {
            if let candidateId = accountId(candidate),
               let index = results.firstIndex(where: { accountId($0) == candidateId }) {
                if priority(candidate) > priority(results[index]) {
                    results[index] = candidate
                }
                continue
            }

            if let index = results.firstIndex(where: { isSameUsage($0, candidate) }) {
                if priority(candidate) > priority(results[index]) {
                    results[index] = candidate
                }
                continue
            }

            results.append(candidate)
        }

        return results
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
            || modelBreakdown != nil
            || secondaryUsage != nil || secondaryReset != nil || primaryReset != nil
            || creditsBalance != nil || planType != nil
            || extraUsageEnabled != nil
            || sessions != nil || messages != nil || avgCostPerDay != nil
            || email != nil
            || dailyHistory != nil || monthlyCost != nil
            || creditsRemaining != nil || creditsTotal != nil
            || authSource != nil || geminiAccounts != nil
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
