import Foundation

struct ProviderResult {
    let usage: ProviderUsage
    let details: DetailedUsage?
}

struct GeminiAccountQuota: Codable {
    let accountIndex: Int
    let email: String
    let remainingPercentage: Double
    let modelBreakdown: [String: Double]
    let authSource: String
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
    let opusUsage: Double?
    
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
        opusUsage: Double? = nil,
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
        geminiAccounts: [GeminiAccountQuota]? = nil
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
        self.opusUsage = opusUsage
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
    }
}

extension DetailedUsage: Codable {
    enum CodingKeys: String, CodingKey {
        case dailyUsage, weeklyUsage, monthlyUsage, totalCredits, remainingCredits
        case limit, limitRemaining, resetPeriod
        case fiveHourUsage, fiveHourReset, sevenDayUsage, sevenDayReset
        case sonnetUsage, opusUsage, modelBreakdown
        case secondaryUsage, secondaryReset, primaryReset
        case creditsBalance, planType, extraUsageEnabled
        case sessions, messages, avgCostPerDay, email
        case dailyHistory, monthlyCost, creditsRemaining, creditsTotal
        case authSource, geminiAccounts
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
        opusUsage = try container.decodeIfPresent(Double.self, forKey: .opusUsage)
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
        try container.encodeIfPresent(opusUsage, forKey: .opusUsage)
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
    }
}

extension DetailedUsage {
    var hasAnyValue: Bool {
        return dailyUsage != nil || weeklyUsage != nil || monthlyUsage != nil 
            || totalCredits != nil || remainingCredits != nil 
            || limit != nil || limitRemaining != nil || resetPeriod != nil
            || fiveHourUsage != nil || fiveHourReset != nil
            || sevenDayUsage != nil || sevenDayReset != nil
            || sonnetUsage != nil || opusUsage != nil
            || modelBreakdown != nil
            || secondaryUsage != nil || secondaryReset != nil || primaryReset != nil
            || creditsBalance != nil || planType != nil
            || extraUsageEnabled != nil
            || sessions != nil || messages != nil || avgCostPerDay != nil
            || email != nil
            || dailyHistory != nil || monthlyCost != nil
            || creditsRemaining != nil || creditsTotal != nil
            || authSource != nil || geminiAccounts != nil
    }
}
