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
        SubscriptionPreset(name: "Team", cost: 30),
        SubscriptionPreset(name: "Pro", cost: 200)
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

    static let openRouter: [SubscriptionPreset] = []
    static let openCode: [SubscriptionPreset] = []
    static let openCodeZen: [SubscriptionPreset] = []

    static func presets(for provider: ProviderIdentifier) -> [SubscriptionPreset] {
        switch provider {
        case .claude:
            return claude
        case .codex:
            return codex
        case .geminiCLI:
            return geminiCLI
        case .copilot:
            return copilot
        case .kimi:
            return kimi
        case .antigravity:
            return antigravity
        case .openRouter:
            return openRouter
        case .openCode:
            return openCode
        case .openCodeZen:
            return openCodeZen
        case .zaiCodingPlan:
            return zaiCodingPlan
        case .chutes:
            return chutes
        }
    }
}

final class SubscriptionSettingsManager {
    static let shared = SubscriptionSettingsManager()

    private let userDefaultsKeyPrefix = "subscription_v2."

    private init() {}

    func subscriptionKey(for provider: ProviderIdentifier, accountId: String? = nil) -> String {
        if let accountId = accountId {
            return "\(provider.rawValue).\(accountId)"
        }
        return provider.rawValue
    }

    func getPlan(forKey key: String) -> SubscriptionPlan {
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
        let fullKey = "\(userDefaultsKeyPrefix)\(key)"
        do {
            let data = try JSONEncoder().encode(plan)
            UserDefaults.standard.set(data, forKey: fullKey)
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
}
