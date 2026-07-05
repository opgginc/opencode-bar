import Foundation

struct SubscriptionMenuAction {
    let subscriptionKey: String
    let plan: SubscriptionPlan
}

enum SubscriptionPlan: Codable, Equatable {
    case none
    case preset(String, Double)
    case custom(Double)

    var cost: Double {
        switch self {
        case .none:
            return 0
        case .preset(_, let amount):
            return amount
        case .custom(let amount):
            return amount
        }
    }

    var displayName: String {
        switch self {
        case .none:
            return "None"
        case .preset(let name, _):
            return name
        case .custom:
            return "Custom"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .none:
            return "None"
        case .preset(let name, _):
            return name
        case .custom:
            return "Custom"
        }
    }

    var isSet: Bool {
        switch self {
        case .none:
            return false
        default:
            return true
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, name, amount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "none":
            self = .none
        case "preset":
            let name = try container.decode(String.self, forKey: .name)
            let amount = try container.decode(Double.self, forKey: .amount)
            self = .preset(name, amount)
        case "custom":
            let amount = try container.decode(Double.self, forKey: .amount)
            self = .custom(amount)
        default:
            self = .none
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode("none", forKey: .type)
        case .preset(let name, let amount):
            try container.encode("preset", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(amount, forKey: .amount)
        case .custom(let amount):
            try container.encode("custom", forKey: .type)
            try container.encode(amount, forKey: .amount)
        }
    }
}

extension SubscriptionPlan {
    /// User-facing title for the selected subscription plan, formatted with the supplied formatter.
    /// Pass the matching preset list so RMB mode can use native CNY prices where available.
    /// Example outputs: "Pro ($20/月)", "Moderato (¥99/月)", "自定义 (¥144/月)", "无 (¥0)".
    func displayTitle(formatter: CurrencyFormatter = CurrencyFormatter.shared,
                      presets: [SubscriptionPreset] = []) -> String {
        switch self {
        case .none:
            return "无 (\(formatter.format(usd: 0, decimals: 0)))"
        case .preset(let name, let cost):
            let matchedPreset = presets.first { $0.name == name && $0.cost == cost }
            let price = matchedPreset?.formattedPrice(decimals: 0, formatter: formatter)
                ?? formatter.format(usd: cost, decimals: 0)
            return "\(name) (\(price)/月)"
        case .custom(let amount):
            return "自定义 (\(formatter.format(usd: amount, decimals: 0))/月)"
        }
    }
}

struct SubscriptionPreset {
    let name: String
    let cost: Double          // USD，ROI 计算唯一真值
    var cnyCost: Double? = nil // 国内套餐人民币原生价，仅展示用

    func formattedPrice(decimals: Int = 0, formatter: CurrencyFormatter = CurrencyFormatter.shared) -> String {
        if formatter.currency == .rmb, let cny = cnyCost {
            return "¥\(Int(cny))"
        }
        return formatter.format(usd: cost, decimals: decimals)
    }
}

struct ProviderSubscriptionPresets {
    // MARK: - Per-family catalogs

    static let claude: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Pro", cost: 20),
        SubscriptionPreset(name: "MAX 5x", cost: 100),
        SubscriptionPreset(name: "MAX 20x", cost: 200)
    ]

    static let codex: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Go", cost: 8),
        SubscriptionPreset(name: "Plus", cost: 20),
        SubscriptionPreset(name: "Pro $100", cost: 100),
        SubscriptionPreset(name: "Pro $200", cost: 200),
        SubscriptionPreset(name: "Business", cost: 25)
    ]

    static var commandCode: [SubscriptionPreset] {
        CommandCodePlanCatalog.orderedPlans.map {
            SubscriptionPreset(name: $0.displayName, cost: $0.monthlyCreditsUSD)
        }
    }

    static let cursor: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Pro", cost: 20),
        SubscriptionPreset(name: "Teams", cost: 40)
    ]

    static let geminiCLI: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Plus Monthly", cost: 4),
        SubscriptionPreset(name: "Plus Annual", cost: 8),
        SubscriptionPreset(name: "Pro", cost: 20),
        SubscriptionPreset(name: "Ultra Monthly", cost: 125),
        SubscriptionPreset(name: "Ultra Annual", cost: 250)
    ]

    static let copilot: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Pro", cost: 10),
        SubscriptionPreset(name: "Pro+", cost: 39),
        SubscriptionPreset(name: "Business", cost: 19),
        SubscriptionPreset(name: "Enterprise", cost: 39)
    ]

    // Kimi Global: 海外版订阅套餐
    static let kimiGlobal: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Moderato",   cost: 19),
        SubscriptionPreset(name: "Allegretto", cost: 39),
        SubscriptionPreset(name: "Allegro",    cost: 99),
        SubscriptionPreset(name: "Vivace",     cost: 199)
    ]

    // Kimi 国内版
    static let kimiChina: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Andante",    cost: 0,   cnyCost: 49),
        SubscriptionPreset(name: "Moderato",   cost: 19,  cnyCost: 99),
        SubscriptionPreset(name: "Allegretto", cost: 39,  cnyCost: 199),
        SubscriptionPreset(name: "Allegro",    cost: 99,  cnyCost: 699)
    ]

    // MiniMax 海外版
    static let minimaxGlobal: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Plus",  cost: 20),
        SubscriptionPreset(name: "Max",   cost: 50),
        SubscriptionPreset(name: "Ultra", cost: 120)
    ]

    // MiniMax 国内版
    static let minimaxChina: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Plus",  cost: 20, cnyCost: 49),
        SubscriptionPreset(name: "Max",   cost: 50, cnyCost: 119),
        SubscriptionPreset(name: "Ultra", cost: 120, cnyCost: 469)
    ]

    static let antigravity: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Pro", cost: 20)
    ]

    static let zai: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Lite", cost: 6),
        SubscriptionPreset(name: "Pro", cost: 30),
        SubscriptionPreset(name: "Max", cost: 60)
    ]

    static let chutes: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Base", cost: 3),
        SubscriptionPreset(name: "Plus", cost: 10),
        SubscriptionPreset(name: "Pro", cost: 20)
    ]

    static let synthetic: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Standard", cost: 20),
        SubscriptionPreset(name: "Pro", cost: 60)
    ]

    static let nanoGpt: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Subscription", cost: 8)
    ]

    static let openRouter: [SubscriptionPreset] = []
    static let openCode: [SubscriptionPreset] = []
    static let openCodeZen: [SubscriptionPreset] = []
    static let openCodeGo: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Go", cost: 10)
    ]
    static let kiro: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Free", cost: 0),
        SubscriptionPreset(name: "Pro", cost: 20),
        SubscriptionPreset(name: "Pro+", cost: 40),
        SubscriptionPreset(name: "Power", cost: 200)
    ]
    static let grok: [SubscriptionPreset] = [
        SubscriptionPreset(name: "SuperGrok Lite", cost: 10),
        SubscriptionPreset(name: "SuperGrok", cost: 30),
        SubscriptionPreset(name: "SuperGrok Heavy Discount", cost: 99),
        SubscriptionPreset(name: "SuperGrok Heavy", cost: 300)
    ]
    static let tavily: [SubscriptionPreset] = []
    static let brave: [SubscriptionPreset] = []

    // 新增：MiMo（仅海外 Token Plan）
    static let mimo: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Lite",     cost: 6,   cnyCost: 39),
        SubscriptionPreset(name: "Standard", cost: 16,  cnyCost: 99),
        SubscriptionPreset(name: "Pro",      cost: 50,  cnyCost: 329),
        SubscriptionPreset(name: "Max",      cost: 100, cnyCost: 659)
    ]

    // 新增：火山 Ark（国内 CNY 套餐，USD 为近似折算，用于总费用汇总）
    private static let volcanoUSDMultiplier = 1.0 / 7.2
    static let volcanoArk: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Agent Plan Small",  cost: 40 * volcanoUSDMultiplier, cnyCost: 40),
        SubscriptionPreset(name: "Agent Plan Medium", cost: 200 * volcanoUSDMultiplier, cnyCost: 200),
        SubscriptionPreset(name: "Agent Plan Large",  cost: 500 * volcanoUSDMultiplier, cnyCost: 500),
        SubscriptionPreset(name: "Agent Plan Max",    cost: 1000 * volcanoUSDMultiplier, cnyCost: 1000)
    ]

    // 新增：腾讯混元 Token Plan（国内 CNY 套餐）
    private static let hunyuanUSDMultiplier = 1.0 / 7.2
    static let hunyuan: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Lite",     cost: 39 * hunyuanUSDMultiplier, cnyCost: 39),
        SubscriptionPreset(name: "Standard", cost: 99 * hunyuanUSDMultiplier, cnyCost: 99),
        SubscriptionPreset(name: "Pro",      cost: 299 * hunyuanUSDMultiplier, cnyCost: 299),
        SubscriptionPreset(name: "Max",      cost: 599 * hunyuanUSDMultiplier, cnyCost: 599)
    ]

    // 新增：智谱 GLM Coding Plan（国内 CNY 套餐）
    private static let zhipuUSDMultiplier = 1.0 / 7.2
    static let zhipuGLM: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Lite", cost: 49 * zhipuUSDMultiplier, cnyCost: 49),
        SubscriptionPreset(name: "Pro",  cost: 149 * zhipuUSDMultiplier, cnyCost: 149),
        SubscriptionPreset(name: "Max",  cost: 469 * zhipuUSDMultiplier, cnyCost: 469)
    ]

    // MARK: - Lookup

    static func presets(for provider: ProviderIdentifier) -> [SubscriptionPreset] {
        presets(family: provider.family, region: provider.region)
    }

    static func presets(family: ProviderFamily, region: ProviderRegion) -> [SubscriptionPreset] {
        switch (family, region) {
        case (.claude, _): return claude
        case (.codex, _): return codex
        case (.commandCode, _): return commandCode
        case (.cursor, _): return cursor
        case (.geminiCLI, _): return geminiCLI
        case (.copilot, _): return copilot
        case (.kimi, .china): return kimiChina
        case (.kimi, .global): return kimiGlobal
        case (.minimax, .china): return minimaxChina
        case (.minimax, .global): return minimaxGlobal
        case (.antigravity, _): return antigravity
        case (.zai, _): return zai
        case (.chutes, _): return chutes
        case (.synthetic, _): return synthetic
        case (.nanoGpt, _): return nanoGpt
        case (.openRouter, _): return openRouter
        case (.openCode, _): return openCode
        case (.openCodeZen, _): return openCodeZen
        case (.openCodeGo, _): return openCodeGo
        case (.kiro, _): return kiro
        case (.grok, _): return grok
        case (.tavily, _): return tavily
        case (.brave, _): return brave
        case (.mimo, _): return mimo
        case (.volcanoArk, _): return volcanoArk
        case (.hunyuan, _): return hunyuan
        case (.zhipuGLM, _): return zhipuGLM
        }
    }
}

final class SubscriptionSettingsManager {
    static let shared = SubscriptionSettingsManager()
    static let defaultAccountId = "_default_"

    private let userDefaultsKeyPrefix = "subscription_v2."

    private init() {}

    func subscriptionKey(for provider: ProviderIdentifier, accountId: String? = nil) -> String {
        "\(provider.rawValue).\(normalizedAccountId(accountId))"
    }

    func getPlan(forKey key: String) -> SubscriptionPlan {
        guard isCurrentSubscriptionKey(key) else {
            return .none
        }

        let fullKey = "\(userDefaultsKeyPrefix)\(key)"
        guard let data = UserDefaults.standard.data(forKey: fullKey),
              let plan = try? JSONDecoder().decode(SubscriptionPlan.self, from: data) else {
            return .none
        }
        return plan
    }

    func getPlan(for provider: ProviderIdentifier, accountId: String? = nil) -> SubscriptionPlan {
        let key = subscriptionKey(for: provider, accountId: accountId)
        return getPlan(forKey: key)
    }

    func setPlan(_ plan: SubscriptionPlan, forKey key: String) {
        guard isCurrentSubscriptionKey(key) else {
            NSLog("Skipped saving subscription plan for legacy key")
            return
        }

        let fullKey = "\(userDefaultsKeyPrefix)\(key)"
        do {
            let data = try JSONEncoder().encode(plan)
            UserDefaults.standard.set(data, forKey: fullKey)
            NSLog("Saved subscription plan for account-scoped key")
        } catch {
            NSLog("Failed to encode SubscriptionPlan for key '%@': %@", fullKey, String(describing: error))
        }
    }

    func setPlan(_ plan: SubscriptionPlan, for provider: ProviderIdentifier, accountId: String? = nil) {
        let key = subscriptionKey(for: provider, accountId: accountId)
        setPlan(plan, forKey: key)
    }

    func removePlan(forKey key: String) {
        let fullKey = "\(userDefaultsKeyPrefix)\(key)"
        UserDefaults.standard.removeObject(forKey: fullKey)
    }

    func removePlans(forKeys keys: [String]) {
        for key in keys {
            removePlan(forKey: key)
        }
    }

    func getAllSubscriptionKeys() -> [String] {
        let allKeys = UserDefaults.standard.dictionaryRepresentation().keys
        return allKeys.filter { $0.hasPrefix(userDefaultsKeyPrefix) }
            .map { String($0.dropFirst(userDefaultsKeyPrefix.count)) }
            .filter { isCurrentSubscriptionKey($0) }
            .sorted()
    }

    /// Return subscription keys that look like duplicates of the same physical account.
    ///
    /// Heuristics:
    /// - `.kimi.<id>` and `.kimi_cn.<id>` both present for the same `id` (most common case:
    ///   user switched between Global and CN provider but kept both selections).
    /// - Two keys with identical `.accountId` suffix whose plans match by name+amount.
    func findLikelyDuplicateSubscriptionKeys() -> [String] {
        let allKeys = getAllSubscriptionKeys()
        let groups = Dictionary(grouping: allKeys) { key -> String in
            // ".kimi.d7k…" → suffix "d7k…"; drop the ".kimi." portion
            // ".kimi_cn.d7k…" → suffix "d7k…"
            // ".openCodeGo._default_" → "_default_" (account id part)
            if let dot = key.firstIndex(of: ".") {
                let rest = key[key.index(after: dot)...]
                if rest.firstIndex(of: ".") != nil {
                    let afterFirstDot = rest.index(after: rest.firstIndex(of: ".")!)
                    return String(rest[afterFirstDot...])
                } else {
                    return String(rest)
                }
            }
            return key
        }
        var duplicateKeys: [String] = []
        for (accountId, keys) in groups where keys.count > 1 && accountId != Self.defaultAccountId {
            // Multiple keys for the same account id → flag all but the first
            let sortedKeys = keys.sorted()
            for k in sortedKeys.dropFirst() {
                duplicateKeys.append(k)
            }
        }
        return duplicateKeys.sorted()
    }

    func getTotalMonthlySubscriptionCost() -> Double {
        var total: Double = 0
        for key in getAllSubscriptionKeys() {
            total += getPlan(forKey: key).cost
        }
        return total
    }

    /// Monthly subscription total expressed in the requested currency.
    /// RMB uses native cnyCost when available; otherwise falls back to USD × rate.
    func totalMonthlyCost(inCurrency currency: Currency, formatter: CurrencyFormatter) -> Double {
        getAllSubscriptionKeys().reduce(0) { $0 + monthlyCost(forKey: $1, inCurrency: currency, formatter: formatter) }
    }

    /// Formatted monthly subscription total, ready for UI display.
    func totalMonthlyCostDisplayText(currency: Currency, formatter: CurrencyFormatter) -> String {
        let total = totalMonthlyCost(inCurrency: currency, formatter: formatter)
        return formatter.format(amount: total, as: currency, decimals: 0)
    }

    func monthlyCost(forKey key: String, inCurrency currency: Currency, formatter: CurrencyFormatter) -> Double {
        let plan = getPlan(forKey: key)
        switch currency {
        case .usd:
            return plan.cost
        case .rmb:
            return cnyCost(for: plan, key: key) ?? (plan.cost * formatter.currentRate)
        }
    }

    func hasAnySubscription() -> Bool {
        for key in getAllSubscriptionKeys() {
            if getPlan(forKey: key).isSet {
                return true
            }
        }
        return false
    }

    private func normalizedAccountId(_ accountId: String?) -> String {
        guard let accountId = accountId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accountId.isEmpty else {
            return Self.defaultAccountId
        }
        return accountId.lowercased()
    }

    private func providerIdentifier(for subscriptionKey: String) -> ProviderIdentifier? {
        let prefix = subscriptionKey.split(separator: ".", maxSplits: 1).first
        guard let prefix else { return nil }
        return ProviderIdentifier(rawValue: String(prefix))
    }

    private func cnyCost(for plan: SubscriptionPlan, key: String) -> Double? {
        switch plan {
        case .preset(let name, _):
            guard let provider = providerIdentifier(for: key) else { return nil }
            return ProviderSubscriptionPresets.presets(for: provider).first { $0.name == name }?.cnyCost
        case .custom, .none:
            return nil
        }
    }

    private func isCurrentSubscriptionKey(_ key: String) -> Bool {
        let parts = key.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              ProviderIdentifier(rawValue: String(parts[0])) != nil else {
            return false
        }

        let accountId = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return !accountId.isEmpty
    }
}
