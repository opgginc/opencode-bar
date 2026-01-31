import AppKit
import Foundation

extension StatusBarController {
    
    func createDetailSubmenu(_ details: DetailedUsage, identifier: ProviderIdentifier) -> NSMenu {
        let submenu = NSMenu()
        
        switch identifier {
        case .openRouter:
            if let remaining = details.creditsRemaining, let total = details.creditsTotal {
                let percent = total > 0 ? (remaining / total) * 100 : 0
                submenu.addItem(NSMenuItem(title: String(format: "Credits: $%.0f/$%.0f (%.0f%%)", remaining, total, percent), action: nil, keyEquivalent: ""))
            }
            if let daily = details.dailyUsage {
                submenu.addItem(NSMenuItem(title: String(format: "Daily: $%.2f", daily), action: nil, keyEquivalent: ""))
            }
            if let weekly = details.weeklyUsage {
                submenu.addItem(NSMenuItem(title: String(format: "Weekly: $%.2f", weekly), action: nil, keyEquivalent: ""))
            }
            
        case .openCodeZen:
            if let avg = details.avgCostPerDay {
                submenu.addItem(NSMenuItem(title: String(format: "Avg/Day: $%.2f", avg), action: nil, keyEquivalent: ""))
            }
            if let sessions = details.sessions {
                let formatted = NumberFormatter.localizedString(from: NSNumber(value: sessions), number: .decimal)
                submenu.addItem(NSMenuItem(title: "Sessions: \(formatted)", action: nil, keyEquivalent: ""))
            }
            if let messages = details.messages {
                let formatted = NumberFormatter.localizedString(from: NSNumber(value: messages), number: .decimal)
                submenu.addItem(NSMenuItem(title: "Messages: \(formatted)", action: nil, keyEquivalent: ""))
            }
            
            if let models = details.modelBreakdown, !models.isEmpty {
                submenu.addItem(NSMenuItem.separator())
                let headerItem = NSMenuItem(title: "Top Models:", action: nil, keyEquivalent: "")
                headerItem.isEnabled = false
                submenu.addItem(headerItem)
                
                let sortedModels = models.sorted { $0.value > $1.value }.prefix(5)
                for (model, cost) in sortedModels {
                    let shortName = model.components(separatedBy: "/").last ?? model
                    submenu.addItem(NSMenuItem(title: String(format: "  %@: $%.2f", shortName, cost), action: nil, keyEquivalent: ""))
                }
            }
            
            if let history = details.dailyHistory, !history.isEmpty {
                submenu.addItem(NSMenuItem.separator())
                let historyItem = NSMenuItem(title: "Usage History", action: nil, keyEquivalent: "")
                historyItem.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Usage History")
                let historySubmenu = NSMenu()
                
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "MMM d"
                
                for day in history.prefix(7) {
                    let cost = day.billedAmount
                    let title = String(format: "%@: $%.2f", dateFormatter.string(from: day.date), cost)
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    item.attributedTitle = NSAttributedString(
                        string: title,
                        attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)]
                    )
                    historySubmenu.addItem(item)
                }
                
                historyItem.submenu = historySubmenu
                submenu.addItem(historyItem)
            }
            
        case .claude:
            if let fiveHour = details.fiveHourUsage {
                submenu.addItem(NSMenuItem(title: String(format: "5h Window: %.0f%%", fiveHour), action: nil, keyEquivalent: ""))
                if let reset = details.fiveHourReset {
                    let formatter = DateFormatter()
                    formatter.timeStyle = .short
                    submenu.addItem(NSMenuItem(title: "   Resets: \(formatter.string(from: reset))", action: nil, keyEquivalent: ""))
                }
            }
            if let sevenDay = details.sevenDayUsage {
                submenu.addItem(NSMenuItem(title: String(format: "7d Window: %.0f%%", sevenDay), action: nil, keyEquivalent: ""))
                if let reset = details.sevenDayReset {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "MMM d"
                    submenu.addItem(NSMenuItem(title: "   Resets: \(formatter.string(from: reset))", action: nil, keyEquivalent: ""))
                }
            }
            submenu.addItem(NSMenuItem.separator())
            if let sonnet = details.sonnetUsage {
                submenu.addItem(NSMenuItem(title: String(format: "Sonnet (7d): %.0f%%", sonnet), action: nil, keyEquivalent: ""))
            }
            if let opus = details.opusUsage {
                submenu.addItem(NSMenuItem(title: String(format: "Opus (7d): %.0f%%", opus), action: nil, keyEquivalent: ""))
            }
            if let extraUsage = details.extraUsageEnabled {
                submenu.addItem(NSMenuItem(title: "Extra Usage: \(extraUsage ? "ON" : "OFF")", action: nil, keyEquivalent: ""))
            }
            
        case .codex:
            if let primary = details.dailyUsage {
                var primaryTitle = String(format: "Primary: %.0f%%", primary)
                if let reset = details.primaryReset {
                    let hours = Int(reset.timeIntervalSinceNow / 3600)
                    primaryTitle += " (\(hours)h)"
                }
                submenu.addItem(NSMenuItem(title: primaryTitle, action: nil, keyEquivalent: ""))
            }
            if let secondary = details.secondaryUsage {
                var secondaryTitle = String(format: "Secondary: %.0f%%", secondary)
                if let reset = details.secondaryReset {
                    let hours = Int(reset.timeIntervalSinceNow / 3600)
                    secondaryTitle += " (\(hours)h)"
                }
                submenu.addItem(NSMenuItem(title: secondaryTitle, action: nil, keyEquivalent: ""))
            }
            submenu.addItem(NSMenuItem.separator())
            if let plan = details.planType {
                submenu.addItem(NSMenuItem(title: "Plan: \(plan)", action: nil, keyEquivalent: ""))
            }
            if let credits = details.creditsBalance {
                submenu.addItem(NSMenuItem(title: String(format: "Credits: $%.2f", credits), action: nil, keyEquivalent: ""))
            }
            
        case .geminiCLI:
            if let models = details.modelBreakdown, !models.isEmpty {
                for (model, quota) in models.sorted(by: { $0.key < $1.key }) {
                    submenu.addItem(NSMenuItem(title: String(format: "%@: %.0f%%", model, quota), action: nil, keyEquivalent: ""))
                }
            }
            
        case .antigravity:
            if let models = details.modelBreakdown, !models.isEmpty {
                for (model, quota) in models.sorted(by: { $0.key < $1.key }) {
                    submenu.addItem(NSMenuItem(title: String(format: "%@: %.0f%%", model, quota), action: nil, keyEquivalent: ""))
                }
            }
            if details.planType != nil || details.email != nil {
                submenu.addItem(NSMenuItem.separator())
            }
            if let plan = details.planType {
                submenu.addItem(NSMenuItem(title: "Plan: \(plan)", action: nil, keyEquivalent: ""))
            }
            if let email = details.email {
                submenu.addItem(NSMenuItem(title: "Email: \(email)", action: nil, keyEquivalent: ""))
            }
            
        default:
            break
        }
        
        if let daily = details.dailyUsage {
            let item = NSMenuItem(title: String(format: "Daily: $%.2f", daily), action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Daily")
            submenu.addItem(item)
        }
        
        if let weekly = details.weeklyUsage {
            let item = NSMenuItem(title: String(format: "Weekly: $%.2f", weekly), action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Weekly")
            submenu.addItem(item)
        }
        
        if let monthly = details.monthlyUsage {
            let item = NSMenuItem(title: String(format: "Monthly: $%.2f", monthly), action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Monthly")
            submenu.addItem(item)
        }
        
        if let remaining = details.remainingCredits {
            let item = NSMenuItem(title: String(format: "Credits: $%.2f left", remaining), action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "creditcard", accessibilityDescription: "Credits")
            submenu.addItem(item)
        }
        
        if let limit = details.limit, let remaining = details.limitRemaining {
            let item = NSMenuItem(title: String(format: "Limit: $%.2f / $%.2f", remaining, limit), action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "chart.bar", accessibilityDescription: "Limit")
            submenu.addItem(item)
        }
        
        if let period = details.resetPeriod {
            let item = NSMenuItem(title: "Resets: \(period)", action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Reset")
            submenu.addItem(item)
        }
        
        return submenu
    }
    
    func createCopilotHistorySubmenu() -> NSMenu {
        debugLog("createCopilotHistorySubmenu: started")
        let submenu = NSMenu()
        debugLog("createCopilotHistorySubmenu: calling getHistoryUIState")
        let state = getHistoryUIState()
        debugLog("createCopilotHistorySubmenu: getHistoryUIState completed")
        
        if state.hasNoData {
            debugLog("createCopilotHistorySubmenu: hasNoData=true, returning early")
            let item = NSMenuItem(title: "No data", action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "tray", accessibilityDescription: "No data")
            item.isEnabled = false
            submenu.addItem(item)
            return submenu
        }
        debugLog("createCopilotHistorySubmenu: hasNoData=false, continuing")
        
        if let prediction = state.prediction {
            debugLog("createCopilotHistorySubmenu: prediction exists")
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            
            let monthlyText = "Predicted EOM: \(formatter.string(from: NSNumber(value: prediction.predictedMonthlyRequests)) ?? "0") requests"
            let monthlyItem = NSMenuItem(title: monthlyText, action: nil, keyEquivalent: "")
            monthlyItem.image = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: "Predicted EOM")
            monthlyItem.isEnabled = false
            monthlyItem.attributedTitle = NSAttributedString(
                string: monthlyText,
                attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
            )
            submenu.addItem(monthlyItem)
            
            if prediction.predictedBilledAmount > 0 {
                let costText = String(format: "Predicted Add-on: $%.2f", prediction.predictedBilledAmount)
                let costItem = NSMenuItem(title: costText, action: nil, keyEquivalent: "")
                costItem.image = NSImage(systemSymbolName: "dollarsign.circle", accessibilityDescription: "Predicted Add-on")
                costItem.isEnabled = false
                costItem.attributedTitle = NSAttributedString(
                    string: costText,
                    attributes: [
                        .font: NSFont.boldSystemFont(ofSize: 13),
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ]
                )
                submenu.addItem(costItem)
            }
            
            if prediction.confidenceLevel == .low {
                let confItem = NSMenuItem(title: "Low prediction accuracy", action: nil, keyEquivalent: "")
                confItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Low accuracy")
                confItem.isEnabled = false
                submenu.addItem(confItem)
            } else if prediction.confidenceLevel == .medium {
                let confItem = NSMenuItem(title: "Medium prediction accuracy", action: nil, keyEquivalent: "")
                confItem.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Medium accuracy")
                confItem.isEnabled = false
                submenu.addItem(confItem)
            }
            
            debugLog("createCopilotHistorySubmenu: adding separator after prediction")
            submenu.addItem(NSMenuItem.separator())
            debugLog("createCopilotHistorySubmenu: separator added")
        } else {
            debugLog("createCopilotHistorySubmenu: no prediction")
        }
        
        if state.isStale {
            debugLog("createCopilotHistorySubmenu: data is stale")
            let staleItem = NSMenuItem(title: "Data is stale", action: nil, keyEquivalent: "")
            staleItem.image = NSImage(systemSymbolName: "clock.badge.exclamationmark", accessibilityDescription: "Data is stale")
            staleItem.isEnabled = false
            submenu.addItem(staleItem)
            debugLog("createCopilotHistorySubmenu: stale item added")
        }
        
        if let history = state.history {
            debugLog("createCopilotHistorySubmenu: history exists, processing \(history.recentDays.count) days")
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMM d"
            dateFormatter.timeZone = TimeZone(identifier: "UTC")
            
            var utcCalendar = Calendar(identifier: .gregorian)
            utcCalendar.timeZone = TimeZone(identifier: "UTC")!
            let today = utcCalendar.startOfDay(for: Date())
            
            let numberFormatter = NumberFormatter()
            numberFormatter.numberStyle = .decimal
            numberFormatter.maximumFractionDigits = 0
            
            for day in history.recentDays {
                let dayStart = utcCalendar.startOfDay(for: day.date)
                let isToday = dayStart == today
                let dateStr = dateFormatter.string(from: day.date)
                let reqStr = numberFormatter.string(from: NSNumber(value: day.totalRequests)) ?? "0"
                let label = isToday ? "\(dateStr) (Today): \(reqStr) req" : "\(dateStr): \(reqStr) req"
                
                let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.attributedTitle = NSAttributedString(
                    string: label,
                    attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)]
                )
                submenu.addItem(item)
            }
            debugLog("createCopilotHistorySubmenu: all history items added")
        } else {
            debugLog("createCopilotHistorySubmenu: no history")
        }
        
         debugLog("createCopilotHistorySubmenu: adding final separator and prediction period menu")
         submenu.addItem(NSMenuItem.separator())
         let predictionPeriodItem = NSMenuItem(title: "Prediction Period", action: nil, keyEquivalent: "")
         predictionPeriodItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Prediction Period")
         debugLog("createCopilotHistorySubmenu: creating new prediction period submenu")
         
         // Create a new submenu instead of referencing the shared one to avoid deadlock
         let periodSubmenu = NSMenu()
         for period in PredictionPeriod.allCases {
             let item = NSMenuItem(title: period.title, action: #selector(predictionPeriodSelected(_:)), keyEquivalent: "")
             item.target = self
             item.tag = period.rawValue
             periodSubmenu.addItem(item)
         }
         predictionPeriodItem.submenu = periodSubmenu
         debugLog("createCopilotHistorySubmenu: prediction period submenu created")
         submenu.addItem(predictionPeriodItem)
         debugLog("createCopilotHistorySubmenu: completed successfully")
         
         return submenu
    }
}
