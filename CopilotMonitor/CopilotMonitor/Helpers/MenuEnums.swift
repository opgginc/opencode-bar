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

// MARK: - Menu Bar Display Mode
enum MenuBarDisplayMode: Int, CaseIterable {
    case defaultMode = 0
    case iconOnly = 1
    case totalCost = 2
    case singleProvider = 3

    var title: String {
        switch self {
        case .defaultMode: return "Default"
        case .iconOnly: return "Icon Only"
        case .totalCost: return "Total Cost"
        case .singleProvider: return "Single Provider"
        }
    }

    static var defaultMode_: MenuBarDisplayMode { .defaultMode }

    /// UserDefaults key for the display mode
    static let userDefaultsKey = "menuBarDisplayMode"

    /// UserDefaults key for the selected provider (used with .singleProvider mode)
    static let providerKey = "menuBarDisplayProvider"
}
