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
            return "None ($0)"
        case .preset(let name, let amount):
            return "\(name) ($\(Int(amount))/m)"
        case .custom(let amount):
            return String(format: "Custom ($%.0f/m)", amount)
        }
    }

    var shortDisplayName: String {
        switch self {
        case .none:
            return "None"
        case .preset(let name, _):
            return name
        case .custom(let amount):
            return String(format: "$%.0f", amount)
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

struct SubscriptionPreset {
    let name: String
    let cost: Double
}

struct ProviderSubscriptionPresets {
    static let claude: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Pro", cost: 20),
        SubscriptionPreset(name: "MAX", cost: 100),
        SubscriptionPreset(name: "MAX", cost: 200)
    ]

    static let codex: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Go", cost: 8),
        SubscriptionPreset(name: "Plus", cost: 20),
        SubscriptionPreset(name: "Business", cost: 25),
        SubscriptionPreset(name: "Pro", cost: 200)
    ]

    static let cursor: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Pro", cost: 20),
        SubscriptionPreset(name: "Teams", cost: 40)
    ]

    static let geminiCLI: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Plus", cost: 4),
        SubscriptionPreset(name: "Plus", cost: 8),
        SubscriptionPreset(name: "Pro", cost: 20),
        SubscriptionPreset(name: "Ultra", cost: 125),
        SubscriptionPreset(name: "Ultra", cost: 250)
    ]

    static let copilot: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Pro", cost: 10),
        SubscriptionPreset(name: "Pro+", cost: 39),
        SubscriptionPreset(name: "Business", cost: 19),
        SubscriptionPreset(name: "Enterprise", cost: 39)
    ]

    static let kimi: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Moderato", cost: 19),
        SubscriptionPreset(name: "Allegretto", cost: 39),
        SubscriptionPreset(name: "Vivace", cost: 199)
    ]

    static let minimaxCodingPlan: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Starter", cost: 10),
        SubscriptionPreset(name: "Plus", cost: 20),
        SubscriptionPreset(name: "Max", cost: 50),
        SubscriptionPreset(name: "Plus HS", cost: 40),
        SubscriptionPreset(name: "Max HS", cost: 80),
        SubscriptionPreset(name: "Ultra HS", cost: 150)
    ]

    static let antigravity: [SubscriptionPreset] = [
        SubscriptionPreset(name: "Pro", cost: 20)
    ]

    static let zaiCodingPlan: [SubscriptionPreset] = [
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
    static let tavilySearch: [SubscriptionPreset] = []
    static let braveSearch: [SubscriptionPreset] = []

    static func presets(for provider: ProviderIdentifier) -> [SubscriptionPreset] {
        switch provider {
        case .claude:
            return claude
        case .codex:
            return codex
        case .cursor:
            return cursor
        case .geminiCLI:
            return geminiCLI
        case .copilot:
            return copilot
        case .kimi:
            return kimi
        case .minimaxCodingPlan:
            return minimaxCodingPlan
        case .antigravity:
            return antigravity
        case .openRouter:
            return openRouter
        case .openCode:
            return openCode
        case .openCodeZen:
            return openCodeZen
        case .openCodeGo:
            return openCodeGo
        case .kiro:
            return kiro
        case .grok:
            return grok
        case .tavilySearch:
            return tavilySearch
        case .braveSearch:
            return braveSearch
        case .zaiCodingPlan:
            return zaiCodingPlan
        case .nanoGpt:
            return nanoGpt
        case .synthetic:
            return synthetic
        case .chutes:
            return chutes
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

    func getTotalMonthlySubscriptionCost() -> Double {
        var total: Double = 0
        for key in getAllSubscriptionKeys() {
            total += getPlan(forKey: key).cost
        }
        return total
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
