import Foundation

// MARK: - Refresh Interval
enum RefreshInterval: Int, CaseIterable {
    case oneMinute = 60
    case threeMinutes = 180
    case fiveMinutes = 300
    case tenMinutes = 600
    case thirtyMinutes = 1800
    case oneHour = 3600

    var title: String {
        switch self {
        case .oneMinute: return "1m"
        case .threeMinutes: return "3m"
        case .fiveMinutes: return "5m"
        case .tenMinutes: return "10m"
        case .thirtyMinutes: return "30m"
        case .oneHour: return "1h"
        }
    }

    static var defaultInterval: RefreshInterval { .fiveMinutes }
}

// MARK: - Prediction Period
enum PredictionPeriod: Int, CaseIterable {
    case oneWeek = 7
    case twoWeeks = 14
    case threeWeeks = 21

    var title: String {
        switch self {
        case .oneWeek: return "7 days"
        case .twoWeeks: return "14 days"
        case .threeWeeks: return "21 days"
        }
    }

    var weights: [Double] {
        switch self {
        case .oneWeek:
            return [1.5, 1.5, 1.2, 1.2, 1.2, 1.0, 1.0]
        case .twoWeeks:
            return [1.5, 1.5, 1.4, 1.4, 1.3, 1.3, 1.2, 1.2, 1.1, 1.1, 1.0, 1.0, 1.0, 1.0]
        case .threeWeeks:
            return [1.5, 1.5, 1.4, 1.4, 1.3, 1.3, 1.2, 1.2, 1.2, 1.1, 1.1, 1.1, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
        }
    }

    static var defaultPeriod: PredictionPeriod { .oneWeek }
}

// MARK: - Brave Search Refresh Mode
enum BraveSearchRefreshMode: Int, CaseIterable {
    case eventOnly = 0
    case apiEverySixHours = 1
    case hybrid = 2

    var title: String {
        switch self {
        case .eventOnly: return "Event-based only"
        case .apiEverySixHours: return "API sync every 6h"
        case .hybrid: return "Hybrid (event + 6h API)"
        }
    }

    var allowsAPISync: Bool {
        switch self {
        case .eventOnly:
            return false
        case .apiEverySixHours, .hybrid:
            return true
        }
    }

    var allowsEventCounting: Bool {
        switch self {
        case .eventOnly, .hybrid:
            return true
        case .apiEverySixHours:
            return false
        }
    }

    static var defaultMode: BraveSearchRefreshMode { .eventOnly }
}

// MARK: - Menu Bar Display
enum MenuBarDisplayMode: Int, CaseIterable {
    case totalCost = 0
    case iconOnly = 1
    case onlyShow = 2

    var title: String {
        switch self {
        case .totalCost: return "Total Cost"
        case .iconOnly: return "Icon Only"
        case .onlyShow: return "Only Show"
        }
    }

    static var defaultMode: MenuBarDisplayMode { .totalCost }
}

enum OnlyShowMode: Int, CaseIterable {
    case pinnedProvider = 0
    case alertFirst = 1
    case recentChange = 2

    var title: String {
        switch self {
        case .pinnedProvider: return "Pinned Provider"
        case .alertFirst: return "Alert First"
        case .recentChange: return "Recent Quota Change Only"
        }
    }

    static var defaultMode: OnlyShowMode { .pinnedProvider }
}

enum StatusBarDisplayPreferences {
    static let modeKey = "statusBarDisplay.mode"
    static let onlyShowModeKey = "statusBarDisplay.onlyShowMode"
    static let providerKey = "statusBarDisplay.provider"
    // Legacy key kept for migration from old toggle-based UI.
    static let showAlertFirstKey = "statusBarDisplay.showAlertFirst"
    static let criticalBadgeKey = "statusBarDisplay.criticalBadge"
    static let showProviderNameKey = "statusBarDisplay.showProviderName"
}

enum SearchEnginePreferences {
    static let braveRefreshModeKey = "searchEngines.brave.refreshMode"
    static let braveLastAPISyncAtKey = "searchEngines.brave.lastApiSyncAt"
    static let braveLastUsedKey = "searchEngines.brave.lastUsed"
    static let braveLastRemainingKey = "searchEngines.brave.lastRemaining"
    static let braveLastLimitKey = "searchEngines.brave.lastLimit"
    static let braveLastResetSecondsKey = "searchEngines.brave.lastResetSeconds"
    static let braveEventEstimatedUsedKey = "searchEngines.brave.eventEstimatedUsed"
    static let braveEventCursorKey = "searchEngines.brave.eventCursor"
    static let braveEventMonthKey = "searchEngines.brave.eventMonth"
}
