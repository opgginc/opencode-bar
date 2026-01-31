import AppKit
import Foundation

extension StatusBarController {
    
    func createDetailSubmenu(_ details: DetailedUsage, identifier: ProviderIdentifier) -> NSMenu {
        let submenu = NSMenu()
        
        switch identifier {
        case .openRouter:
            if let remaining = details.creditsRemaining, let total = details.creditsTotal {
                let percent = total > 0 ? (remaining / total) * 100 : 0
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: String(format: "Credits: $%.0f/$%.0f (%.0f%%)", remaining, total, percent))
                submenu.addItem(item)
            }
            
        case .openCodeZen:
            if let avg = details.avgCostPerDay {
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: String(format: "Avg/Day: $%.2f", avg))
                submenu.addItem(item)
            }
            if let sessions = details.sessions {
                let formatted = NumberFormatter.localizedString(from: NSNumber(value: sessions), number: .decimal)
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: "Sessions: \(formatted)")
                submenu.addItem(item)
            }
            if let messages = details.messages {
                let formatted = NumberFormatter.localizedString(from: NSNumber(value: messages), number: .decimal)
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: "Messages: \(formatted)")
                submenu.addItem(item)
            }
            
            if let models = details.modelBreakdown, !models.isEmpty {
                submenu.addItem(NSMenuItem.separator())
                let headerItem = NSMenuItem()
                headerItem.view = createHeaderView(title: "Top Models")
                submenu.addItem(headerItem)
                
                let sortedModels = models.sorted { $0.value > $1.value }.prefix(5)
                for (model, cost) in sortedModels {
                    let shortName = model.components(separatedBy: "/").last ?? model
                    let item = NSMenuItem()
                    item.view = createDisabledLabelView(text: String(format: "  %@: $%.2f", shortName, cost))
                    submenu.addItem(item)
                }
            }
            
            submenu.addItem(NSMenuItem.separator())
            let historyItem = NSMenuItem(title: "Usage History", action: nil, keyEquivalent: "")
            historyItem.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Usage History")
            let historySubmenu = NSMenu()
            
            let loadingState = OpenCodeZenProvider.loadingState
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMM d"
            
            let historyToDisplay: [DailyUsage]
            if loadingState.isLoading || !loadingState.dailyHistory.isEmpty {
                historyToDisplay = loadingState.dailyHistory
            } else if let history = details.dailyHistory {
                historyToDisplay = Array(history.prefix(30))
            } else {
                historyToDisplay = []
            }
            
            if historyToDisplay.isEmpty && !loadingState.isLoading {
                let noDataItem = NSMenuItem()
                noDataItem.view = createDisabledLabelView(text: "No history data")
                historySubmenu.addItem(noDataItem)
            } else {
                for day in historyToDisplay.prefix(30) {
                    let cost = day.billedAmount
                    let title = String(format: "%@: $%.2f", dateFormatter.string(from: day.date), cost)
                    let item = NSMenuItem()
                    item.view = createDisabledLabelView(text: title, monospaced: true)
                    historySubmenu.addItem(item)
                }
                
                if loadingState.isLoading {
                    historySubmenu.addItem(NSMenuItem.separator())
                    let loadingText = "Loading day \(loadingState.currentDay)/\(loadingState.totalDays)..."
                    let loadingItem = NSMenuItem()
                    loadingItem.view = createDisabledLabelView(
                        text: loadingText,
                        icon: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Loading"),
                        font: NSFont.systemFont(ofSize: 11, weight: .medium)
                    )
                    historySubmenu.addItem(loadingItem)
                }
                
                if let error = loadingState.lastError, !loadingState.isLoading {
                    historySubmenu.addItem(NSMenuItem.separator())
                    let errorItem = NSMenuItem()
                    errorItem.view = createDisabledLabelView(
                        text: error,
                        icon: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Error")
                    )
                    historySubmenu.addItem(errorItem)
                }
            }
            
            historyItem.submenu = historySubmenu
            submenu.addItem(historyItem)
            
        case .claude:
            if let fiveHour = details.fiveHourUsage {
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: String(format: "5h Window: %.0f%%", fiveHour))
                submenu.addItem(item)
                if let reset = details.fiveHourReset {
                    let formatter = DateFormatter()
                    formatter.timeStyle = .short
                    let resetItem = NSMenuItem()
                    resetItem.view = createDisabledLabelView(text: "   Resets: \(formatter.string(from: reset))")
                    submenu.addItem(resetItem)
                }
            }
            if let sevenDay = details.sevenDayUsage {
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: String(format: "7d Window: %.0f%%", sevenDay))
                submenu.addItem(item)
                if let reset = details.sevenDayReset {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "MMM d"
                    let resetItem = NSMenuItem()
                    resetItem.view = createDisabledLabelView(text: "   Resets: \(formatter.string(from: reset))")
                    submenu.addItem(resetItem)
                }
            }
            submenu.addItem(NSMenuItem.separator())
            if let sonnet = details.sonnetUsage {
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: String(format: "Sonnet (7d): %.0f%%", sonnet))
                submenu.addItem(item)
            }
            if let opus = details.opusUsage {
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: String(format: "Opus (7d): %.0f%%", opus))
                submenu.addItem(item)
            }
            if let extraUsage = details.extraUsageEnabled {
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: "Extra Usage: \(extraUsage ? "ON" : "OFF")")
                submenu.addItem(item)
            }
            
        case .codex:
            if let primary = details.dailyUsage {
                var primaryTitle = String(format: "Primary: %.0f%%", primary)
                if let reset = details.primaryReset {
                    let hours = Int(reset.timeIntervalSinceNow / 3600)
                    primaryTitle += " (\(hours)h)"
                }
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: primaryTitle)
                submenu.addItem(item)
            }
            if let secondary = details.secondaryUsage {
                var secondaryTitle = String(format: "Secondary: %.0f%%", secondary)
                if let reset = details.secondaryReset {
                    let hours = Int(reset.timeIntervalSinceNow / 3600)
                    secondaryTitle += " (\(hours)h)"
                }
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: secondaryTitle)
                submenu.addItem(item)
            }
            submenu.addItem(NSMenuItem.separator())
            if let plan = details.planType {
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: "Plan: \(plan)")
                submenu.addItem(item)
            }
            if let credits = details.creditsBalance {
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: String(format: "Credits: $%.2f", credits))
                submenu.addItem(item)
            }
            
        case .geminiCLI:
            if let models = details.modelBreakdown, !models.isEmpty {
                for (model, quota) in models.sorted(by: { $0.key < $1.key }) {
                    let item = NSMenuItem()
                    item.view = createDisabledLabelView(text: String(format: "%@: %.0f%%", model, quota))
                    submenu.addItem(item)
                }
            }
            if let email = details.email {
                submenu.addItem(NSMenuItem.separator())
                let item = NSMenuItem()
                item.view = createDisabledLabelView(
                    text: "Email: \(email)",
                    icon: NSImage(systemSymbolName: "person.circle", accessibilityDescription: "User Email")
                )
                submenu.addItem(item)
            }
            
        case .antigravity:
            if let models = details.modelBreakdown, !models.isEmpty {
                for (model, quota) in models.sorted(by: { $0.key < $1.key }) {
                    let item = NSMenuItem()
                    item.view = createDisabledLabelView(text: String(format: "%@: %.0f%%", model, quota))
                    submenu.addItem(item)
                }
            }
            if details.planType != nil || details.email != nil {
                submenu.addItem(NSMenuItem.separator())
            }
            if let plan = details.planType {
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: "Plan: \(plan)")
                submenu.addItem(item)
            }
            if let email = details.email {
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: "Email: \(email)")
                submenu.addItem(item)
            }
            
        default:
            break
        }
        
        if let daily = details.dailyUsage {
            let item = NSMenuItem()
            item.view = createDisabledLabelView(
                text: String(format: "Daily: $%.2f", daily),
                icon: NSImage(systemSymbolName: "calendar", accessibilityDescription: "Daily")
            )
            submenu.addItem(item)
        }
        
        if let weekly = details.weeklyUsage {
            let item = NSMenuItem()
            item.view = createDisabledLabelView(
                text: String(format: "Weekly: $%.2f", weekly),
                icon: NSImage(systemSymbolName: "calendar", accessibilityDescription: "Weekly")
            )
            submenu.addItem(item)
        }
        
        if let monthly = details.monthlyUsage {
            let item = NSMenuItem()
            item.view = createDisabledLabelView(
                text: String(format: "Monthly: $%.2f", monthly),
                icon: NSImage(systemSymbolName: "calendar", accessibilityDescription: "Monthly")
            )
            submenu.addItem(item)
        }
        
        if let remaining = details.remainingCredits {
            let item = NSMenuItem()
            item.view = createDisabledLabelView(
                text: String(format: "Credits: $%.2f left", remaining),
                icon: NSImage(systemSymbolName: "creditcard", accessibilityDescription: "Credits")
            )
            submenu.addItem(item)
        }
        
        if let limit = details.limit, let remaining = details.limitRemaining {
            let item = NSMenuItem()
            item.view = createDisabledLabelView(
                text: String(format: "Limit: $%.2f / $%.2f", remaining, limit),
                icon: NSImage(systemSymbolName: "chart.bar", accessibilityDescription: "Limit")
            )
            submenu.addItem(item)
        }
        
        if let period = details.resetPeriod {
            let item = NSMenuItem()
            item.view = createDisabledLabelView(
                text: "Resets: \(period)",
                icon: NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Reset")
            )
            submenu.addItem(item)
        }
        
        if let authSource = details.authSource {
            submenu.addItem(NSMenuItem.separator())
            let authItem = NSMenuItem()
            authItem.view = createDisabledLabelView(
                text: "Token From: \(authSource)",
                icon: NSImage(systemSymbolName: "key", accessibilityDescription: "Auth Source"),
                multiline: true
            )
            submenu.addItem(authItem)
        }
        
        return submenu
    }
    
    func createGeminiAccountSubmenu(_ account: GeminiAccountQuota) -> NSMenu {
        let submenu = NSMenu()
        
        for (model, quota) in account.modelBreakdown.sorted(by: { $0.key < $1.key }) {
            let item = NSMenuItem()
            item.view = createDisabledLabelView(text: String(format: "%@: %.0f%%", model, quota))
            submenu.addItem(item)
        }
        
        submenu.addItem(NSMenuItem.separator())
        
        let emailItem = NSMenuItem()
        emailItem.view = createDisabledLabelView(
            text: "Email: \(account.email)",
            icon: NSImage(systemSymbolName: "person.circle", accessibilityDescription: "User Email")
        )
        submenu.addItem(emailItem)
        
        submenu.addItem(NSMenuItem.separator())
        
        let authItem = NSMenuItem()
        authItem.view = createDisabledLabelView(
            text: "Token From: \(account.authSource)",
            icon: NSImage(systemSymbolName: "key", accessibilityDescription: "Auth Source"),
            multiline: true
        )
        submenu.addItem(authItem)
        
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
            let item = NSMenuItem()
            item.view = createDisabledLabelView(
                text: "No data",
                icon: NSImage(systemSymbolName: "tray", accessibilityDescription: "No data")
            )
            submenu.addItem(item)
            return submenu
        }
        debugLog("createCopilotHistorySubmenu: hasNoData=false, continuing")
        
        if state.isStale {
            debugLog("createCopilotHistorySubmenu: data is stale")
            let staleItem = NSMenuItem()
            staleItem.view = createDisabledLabelView(
                text: "Data is stale",
                icon: NSImage(systemSymbolName: "clock.badge.exclamationmark", accessibilityDescription: "Data is stale")
            )
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
                let billedAmount = day.billedAmount
                let overageReq = Int(day.billedRequests)
                let label: String
                if isToday {
                    label = String(format: "%@ (Today): %d overage ($%.2f)", dateStr, overageReq, billedAmount)
                } else {
                    label = String(format: "%@: %d overage ($%.2f)", dateStr, overageReq, billedAmount)
                }
                
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: label, monospaced: true)
                submenu.addItem(item)
            }
            debugLog("createCopilotHistorySubmenu: all history items added")
        } else {
            debugLog("createCopilotHistorySubmenu: no history")
        }
         
         debugLog("createCopilotHistorySubmenu: completed successfully")
         return submenu
    }
}
