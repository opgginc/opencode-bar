import AppKit
import Foundation

extension StatusBarController {

    func createDetailSubmenu(_ details: DetailedUsage, identifier: ProviderIdentifier) -> NSMenu {
        let submenu = NSMenu()

        switch identifier {
        case .openRouter:
            if let remaining = details.creditsRemaining {
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: String(format: "Credits: $%.0f", remaining))
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
                    formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
                    formatter.timeZone = TimeZone.current
                    let resetItem = NSMenuItem()
                    resetItem.view = createDisabledLabelView(text: "Resets: \(formatter.string(from: reset))", indent: 18)
                    submenu.addItem(resetItem)

                    let paceInfo = calculatePace(usage: fiveHour, resetTime: reset, windowHours: 5)
                    let paceItem = NSMenuItem()
                    paceItem.view = createPaceView(paceInfo: paceInfo)
                    submenu.addItem(paceItem)
                }
            }
            if let sevenDay = details.sevenDayUsage {
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: String(format: "7d Window: %.0f%%", sevenDay))
                submenu.addItem(item)
                if let reset = details.sevenDayReset {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
                    formatter.timeZone = TimeZone.current
                    let resetItem = NSMenuItem()
                    resetItem.view = createDisabledLabelView(text: "Resets: \(formatter.string(from: reset))", indent: 18)
                    submenu.addItem(resetItem)

                    let paceInfo = calculatePace(usage: sevenDay, resetTime: reset, windowHours: 168)
                    let paceItem = NSMenuItem()
                    paceItem.view = createPaceView(paceInfo: paceInfo)
                    submenu.addItem(paceItem)
                }
            }
            submenu.addItem(NSMenuItem.separator())
            if let sonnet = details.sonnetUsage {
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: String(format: "Sonnet (7d): %.0f%%", sonnet))
                submenu.addItem(item)
                if let reset = details.sonnetReset {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
                    formatter.timeZone = TimeZone.current
                    let resetItem = NSMenuItem()
                    resetItem.view = createDisabledLabelView(text: "Resets: \(formatter.string(from: reset))", indent: 18)
                    submenu.addItem(resetItem)

                    let paceInfo = calculatePace(usage: sonnet, resetTime: reset, windowHours: 168)
                    let paceItem = NSMenuItem()
                    paceItem.view = createPaceView(paceInfo: paceInfo)
                    submenu.addItem(paceItem)
                }
            }
            if let opus = details.opusUsage {
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: String(format: "Opus (7d): %.0f%%", opus))
                submenu.addItem(item)
                if let reset = details.opusReset {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
                    formatter.timeZone = TimeZone.current
                    let resetItem = NSMenuItem()
                    resetItem.view = createDisabledLabelView(text: "Resets: \(formatter.string(from: reset))", indent: 18)
                    submenu.addItem(resetItem)

                    let paceInfo = calculatePace(usage: opus, resetTime: reset, windowHours: 168)
                    let paceItem = NSMenuItem()
                    paceItem.view = createPaceView(paceInfo: paceInfo)
                    submenu.addItem(paceItem)
                }
            }
            if let extraUsage = details.extraUsageEnabled {
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: "Extra Usage: \(extraUsage ? "ON" : "OFF")")
                submenu.addItem(item)
            }

            addSubscriptionItems(to: submenu, provider: .claude)

        case .codex:
            if let primary = details.dailyUsage {
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: String(format: "Primary: %.0f%%", primary))
                submenu.addItem(item)
                if let reset = details.primaryReset {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
                    formatter.timeZone = TimeZone.current
                    let resetItem = NSMenuItem()
                    resetItem.view = createDisabledLabelView(text: "Resets: \(formatter.string(from: reset))", indent: 18)
                    submenu.addItem(resetItem)

                    let paceInfo = calculatePace(usage: primary, resetTime: reset, windowHours: 24)
                    let paceItem = NSMenuItem()
                    paceItem.view = createPaceView(paceInfo: paceInfo)
                    submenu.addItem(paceItem)
                }
            }
            if let secondary = details.secondaryUsage {
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: String(format: "Secondary: %.0f%%", secondary))
                submenu.addItem(item)
                if let reset = details.secondaryReset {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
                    formatter.timeZone = TimeZone.current
                    let resetItem = NSMenuItem()
                    resetItem.view = createDisabledLabelView(text: "Resets: \(formatter.string(from: reset))", indent: 18)
                    submenu.addItem(resetItem)

                    let paceInfo = calculatePace(usage: secondary, resetTime: reset, windowHours: 24)
                    let paceItem = NSMenuItem()
                    paceItem.view = createPaceView(paceInfo: paceInfo)
                    submenu.addItem(paceItem)
                }
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

            addSubscriptionItems(to: submenu, provider: .codex)

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

            addSubscriptionItems(to: submenu, provider: .geminiCLI, accountId: details.email)

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

            addSubscriptionItems(to: submenu, provider: .antigravity)

        case .kimi:
            if let fiveHour = details.fiveHourUsage {
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: String(format: "5h Window: %.0f%%", fiveHour))
                submenu.addItem(item)
                if let reset = details.fiveHourReset {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
                    formatter.timeZone = TimeZone.current
                    let resetItem = NSMenuItem()
                    resetItem.view = createDisabledLabelView(text: "Resets: \(formatter.string(from: reset))", indent: 18)
                    submenu.addItem(resetItem)

                    let paceInfo = calculatePace(usage: fiveHour, resetTime: reset, windowHours: 5)
                    let paceItem = NSMenuItem()
                    paceItem.view = createPaceView(paceInfo: paceInfo)
                    submenu.addItem(paceItem)
                }
            }
            if let weekly = details.sevenDayUsage {
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: String(format: "Weekly: %.0f%%", weekly))
                submenu.addItem(item)
                if let reset = details.sevenDayReset {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
                    formatter.timeZone = TimeZone.current
                    let resetItem = NSMenuItem()
                    resetItem.view = createDisabledLabelView(text: "Resets: \(formatter.string(from: reset))", indent: 18)
                    submenu.addItem(resetItem)

                    let paceInfo = calculatePace(usage: weekly, resetTime: reset, windowHours: 168)
                    let paceItem = NSMenuItem()
                    paceItem.view = createPaceView(paceInfo: paceInfo)
                    submenu.addItem(paceItem)
                }
            }
            if let plan = details.planType {
                submenu.addItem(NSMenuItem.separator())
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: "Plan: \(plan)")
                submenu.addItem(item)
            }

            addSubscriptionItems(to: submenu, provider: .kimi)

        case .zaiCodingPlan:
            let numberFormatter = NumberFormatter()
            numberFormatter.numberStyle = .decimal
            numberFormatter.maximumFractionDigits = 0

            if let tokenUsage = details.tokenUsagePercent {
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: String(format: "Tokens (5h): %.0f%% used", tokenUsage))
                submenu.addItem(item)

                if let reset = details.tokenUsageReset {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
                    formatter.timeZone = TimeZone.current
                    let resetItem = NSMenuItem()
                    resetItem.view = createDisabledLabelView(text: "Resets: \(formatter.string(from: reset))", indent: 18)
                    submenu.addItem(resetItem)

                    let paceInfo = calculatePace(usage: tokenUsage, resetTime: reset, windowHours: 5)
                    let paceItem = NSMenuItem()
                    paceItem.view = createPaceView(paceInfo: paceInfo)
                    submenu.addItem(paceItem)
                }
            }

            if let tokenUsed = details.tokenUsageUsed, let tokenTotal = details.tokenUsageTotal {
                let usedText = numberFormatter.string(from: NSNumber(value: tokenUsed)) ?? "\(tokenUsed)"
                let totalText = numberFormatter.string(from: NSNumber(value: tokenTotal)) ?? "\(tokenTotal)"
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: "Tokens Used: \(usedText) / \(totalText)")
                submenu.addItem(item)
            }

            if let mcpUsage = details.mcpUsagePercent {
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: String(format: "MCP (Month): %.0f%% used", mcpUsage))
                submenu.addItem(item)

                if let reset = details.mcpUsageReset {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
                    formatter.timeZone = TimeZone.current
                    let resetItem = NSMenuItem()
                    resetItem.view = createDisabledLabelView(text: "Resets: \(formatter.string(from: reset))", indent: 18)
                    submenu.addItem(resetItem)

                    let paceInfo = calculateMonthlyPace(usagePercent: mcpUsage, resetDate: reset)
                    let paceItem = NSMenuItem()
                    paceItem.view = createPaceView(paceInfo: paceInfo)
                    submenu.addItem(paceItem)
                }
            }

            if let mcpUsed = details.mcpUsageUsed, let mcpTotal = details.mcpUsageTotal {
                let usedText = numberFormatter.string(from: NSNumber(value: mcpUsed)) ?? "\(mcpUsed)"
                let totalText = numberFormatter.string(from: NSNumber(value: mcpTotal)) ?? "\(mcpTotal)"
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: "MCP Used: \(usedText) / \(totalText)")
                submenu.addItem(item)
            }

            if details.modelUsageTokens != nil || details.modelUsageCalls != nil {
                submenu.addItem(NSMenuItem.separator())
                let headerItem = NSMenuItem()
                headerItem.view = createHeaderView(title: "Last 24h")
                submenu.addItem(headerItem)
            }

            if let tokens = details.modelUsageTokens {
                let tokensText = numberFormatter.string(from: NSNumber(value: tokens)) ?? "\(tokens)"
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: "Tokens Used: \(tokensText)")
                submenu.addItem(item)
            }

            if let calls = details.modelUsageCalls {
                let callsText = numberFormatter.string(from: NSNumber(value: calls)) ?? "\(calls)"
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: "Model Calls: \(callsText)")
                submenu.addItem(item)
            }

            if details.toolNetworkSearchCount != nil || details.toolWebReadCount != nil || details.toolZreadCount != nil {
                submenu.addItem(NSMenuItem.separator())
                let headerItem = NSMenuItem()
                headerItem.view = createHeaderView(title: "Tool Usage (24h)")
                submenu.addItem(headerItem)
            }

            if let networkSearch = details.toolNetworkSearchCount {
                let countText = numberFormatter.string(from: NSNumber(value: networkSearch)) ?? "\(networkSearch)"
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: "Network Search: \(countText)")
                submenu.addItem(item)
            }

            if let webRead = details.toolWebReadCount {
                let countText = numberFormatter.string(from: NSNumber(value: webRead)) ?? "\(webRead)"
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: "Web Read: \(countText)")
                submenu.addItem(item)
            }

            if let zread = details.toolZreadCount {
                let countText = numberFormatter.string(from: NSNumber(value: zread)) ?? "\(zread)"
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: "ZRead: \(countText)")
                submenu.addItem(item)
            }

            addSubscriptionItems(to: submenu, provider: .zaiCodingPlan)

        case .chutes:
            if let daily = details.dailyUsage,
               let limit = details.limit {
                let used = Int(daily)
                let total = Int(limit)
                let remaining = max(0, total - used)
                let percentage = total > 0 ? Int((Double(used) / Double(total)) * 100) : 0

                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: String(format: "Daily: %d/%d (%d%%)", used, total, percentage))
                submenu.addItem(item)

                if let resetPeriod = details.resetPeriod {
                    let resetItem = NSMenuItem()
                    resetItem.view = createDisabledLabelView(text: "Resets: \(resetPeriod)", indent: 18)
                    submenu.addItem(resetItem)
                }
            }

            if let plan = details.planType {
                submenu.addItem(NSMenuItem.separator())
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: "Tier: \(plan)")
                submenu.addItem(item)
            }

            addSubscriptionItems(to: submenu, provider: .chutes)

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

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        formatter.timeZone = TimeZone.current

        for (model, quota) in account.modelBreakdown.sorted(by: { $0.key < $1.key }) {
            let item = NSMenuItem()
            item.view = createDisabledLabelView(text: String(format: "%@: %.0f%%", model, quota))
            submenu.addItem(item)

            if let resetDate = account.modelResetTimes[model] {
                let resetItem = NSMenuItem()
                resetItem.view = createDisabledLabelView(text: "Resets: \(formatter.string(from: resetDate))", indent: 18)
                submenu.addItem(resetItem)

                let usagePercent = 100 - quota
                let paceInfo = calculatePace(usage: usagePercent, resetTime: resetDate, windowHours: 24)
                let paceItem = NSMenuItem()
                paceItem.view = createPaceView(paceInfo: paceInfo)
                submenu.addItem(paceItem)
            }
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

        addSubscriptionItems(to: submenu, provider: .geminiCLI, accountId: account.email)

        return submenu
    }

    func addSubscriptionItems(to submenu: NSMenu, provider: ProviderIdentifier, accountId: String? = nil) {
        let subscriptionKey = SubscriptionSettingsManager.shared.subscriptionKey(for: provider, accountId: accountId)
        let currentPlan = SubscriptionSettingsManager.shared.getPlan(forKey: subscriptionKey)
        let presets = ProviderSubscriptionPresets.presets(for: provider)

        submenu.addItem(NSMenuItem.separator())

        let headerItem = NSMenuItem()
        headerItem.view = createHeaderView(title: "Subscription")
        submenu.addItem(headerItem)

        let noneItem = NSMenuItem(title: "None ($0)", action: #selector(subscriptionPlanSelected(_:)), keyEquivalent: "")
        noneItem.target = self
        noneItem.representedObject = SubscriptionMenuAction(subscriptionKey: subscriptionKey, plan: .none)
        noneItem.state = (currentPlan == .none) ? .on : .off
        submenu.addItem(noneItem)

        for preset in presets {
            let item = NSMenuItem(
                title: "\(preset.name) ($\(Int(preset.cost))/m)",
                action: #selector(subscriptionPlanSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = SubscriptionMenuAction(subscriptionKey: subscriptionKey, plan: .preset(preset.name, preset.cost))
            if case .preset(_, let currentCost) = currentPlan, currentCost == preset.cost {
                item.state = .on
            }
            submenu.addItem(item)
        }

        let customItem = NSMenuItem(title: "Set custom...", action: #selector(customSubscriptionSelected(_:)), keyEquivalent: "")
        customItem.target = self
        customItem.representedObject = subscriptionKey
        if case .custom(let amount) = currentPlan {
            customItem.state = .on
            customItem.title = "Set custom ($\(Int(amount))/m)"
        }
        submenu.addItem(customItem)
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

    enum PaceStatus {
        case onTrack
        case slightlyFast
        case tooFast

        var color: NSColor {
            switch self {
            case .onTrack: return .systemGreen
            case .slightlyFast: return .systemOrange
            case .tooFast: return .systemRed
            }
        }
    }

    struct PaceInfo {
        let elapsedRatio: Double
        let usageRatio: Double
        let predictedFinalUsage: Double

        var status: PaceStatus {
            if usageRatio <= elapsedRatio {
                return .onTrack
            } else if predictedFinalUsage <= 130 {
                return .slightlyFast
            } else {
                return .tooFast
            }
        }

        var predictText: String {
            if predictedFinalUsage > 100 {
                return String(format: "+%.0f%%", predictedFinalUsage)
            } else {
                return String(format: "%.0f%%", predictedFinalUsage)
            }
        }

        var statusText: String {
            switch status {
            case .onTrack: return "On Track"
            case .slightlyFast: return "Slightly Fast"
            case .tooFast: return "Too Fast"
            }
        }
    }

    func calculatePace(usage: Double, resetTime: Date, windowHours: Int) -> PaceInfo {
        let windowSeconds = Double(windowHours * 3600)
        let now = Date()
        let remainingSeconds = resetTime.timeIntervalSince(now)
        let elapsedSeconds = windowSeconds - remainingSeconds

        let elapsedRatio = max(0, min(1, elapsedSeconds / windowSeconds))
        let usageRatio = usage / 100.0

        let predictedFinalUsage: Double
        if elapsedRatio > 0.01 {
            predictedFinalUsage = min(999, (usageRatio / elapsedRatio) * 100.0)
        } else {
            predictedFinalUsage = usage
        }

        return PaceInfo(
            elapsedRatio: elapsedRatio,
            usageRatio: usageRatio,
            predictedFinalUsage: predictedFinalUsage
        )
    }

    func calculateMonthlyPace(usagePercent: Double, resetDate: Date) -> PaceInfo {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        if let utc = TimeZone(identifier: "UTC") {
            calendar.timeZone = utc
        }

        guard let billingStart = calendar.date(byAdding: DateComponents(month: -1), to: resetDate) else {
            return PaceInfo(elapsedRatio: 0, usageRatio: usagePercent / 100.0, predictedFinalUsage: usagePercent)
        }

        let totalSeconds = resetDate.timeIntervalSince(billingStart)
        let elapsedSeconds = now.timeIntervalSince(billingStart)

        guard totalSeconds > 0 else {
            return PaceInfo(elapsedRatio: 0, usageRatio: usagePercent / 100.0, predictedFinalUsage: usagePercent)
        }

        let elapsedRatio = max(0, min(1, elapsedSeconds / totalSeconds))
        let usageRatio = usagePercent / 100.0

        let predictedFinalUsage: Double
        if elapsedRatio > 0.01 {
            predictedFinalUsage = min(999, (usageRatio / elapsedRatio) * 100.0)
        } else {
            predictedFinalUsage = usagePercent
        }

        return PaceInfo(
            elapsedRatio: elapsedRatio,
            usageRatio: usageRatio,
            predictedFinalUsage: predictedFinalUsage
        )
    }

    func createPaceView(paceInfo: PaceInfo) -> NSView {
        let menuWidth: CGFloat = MenuDesignToken.Dimension.menuWidth
        let itemHeight: CGFloat = MenuDesignToken.Dimension.itemHeight
        let leadingOffset: CGFloat = MenuDesignToken.Spacing.leadingOffset
        let trailingMargin: CGFloat = MenuDesignToken.Spacing.trailingMargin
        let statusDotSize: CGFloat = MenuDesignToken.Dimension.statusDotSize
        let fontSize: CGFloat = MenuDesignToken.Dimension.fontSize

        let view = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: itemHeight))

        let indentedLeading: CGFloat = leadingOffset + 18
        let leftTextField = NSTextField(labelWithString: "Pace: \(paceInfo.statusText)")
        leftTextField.font = NSFont.systemFont(ofSize: fontSize)
        leftTextField.textColor = .secondaryLabelColor
        leftTextField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(leftTextField)
        NSLayoutConstraint.activate([
            leftTextField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: indentedLeading),
            leftTextField.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        let hasTooFast = paceInfo.status == .tooFast
        var rightEdge = menuWidth - trailingMargin

        if hasTooFast {
            let rabbitView = createRunningRabbitView()
            rabbitView.frame = NSRect(x: rightEdge - 14, y: 3, width: 14, height: 16)
            view.addSubview(rabbitView)
            rightEdge -= 18
        }

        let dotY: CGFloat = (itemHeight - statusDotSize) / 2
        let dotImageView = NSImageView(frame: NSRect(x: rightEdge - statusDotSize, y: dotY, width: statusDotSize, height: statusDotSize))
        if let dotImage = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Status") {
            let config = NSImage.SymbolConfiguration(pointSize: statusDotSize, weight: .regular)
            dotImageView.image = dotImage.withSymbolConfiguration(config)
            dotImageView.contentTintColor = paceInfo.status.color
        }
        view.addSubview(dotImageView)
        rightEdge -= (statusDotSize + 6)

        let rightTextField = NSTextField(labelWithString: "")
        let rightAttributedString = NSMutableAttributedString()
        rightAttributedString.append(NSAttributedString(
            string: "Predict: ",
            attributes: [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.disabledControlTextColor]
        ))
        rightAttributedString.append(NSAttributedString(
            string: paceInfo.predictText,
            attributes: [.font: NSFont.boldSystemFont(ofSize: fontSize), .foregroundColor: paceInfo.status.color]
        ))
        rightTextField.attributedStringValue = rightAttributedString
        rightTextField.isBezeled = false
        rightTextField.isEditable = false
        rightTextField.isSelectable = false
        rightTextField.drawsBackground = false
        rightTextField.sizeToFit()
        rightTextField.frame = NSRect(x: rightEdge - rightTextField.frame.width, y: 3, width: rightTextField.frame.width, height: itemHeight - 6)
        view.addSubview(rightTextField)

        return view
    }

    func createRunningRabbitView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 30, height: 16))
        view.wantsLayer = true

        let rabbitLabel = NSTextField(labelWithString: "🐰")
        rabbitLabel.font = NSFont.systemFont(ofSize: 11)
        rabbitLabel.frame = NSRect(x: 0, y: 0, width: 20, height: 16)
        rabbitLabel.wantsLayer = true
        view.addSubview(rabbitLabel)

        let bounceAnimation = CAKeyframeAnimation(keyPath: "position.y")
        bounceAnimation.values = [0, -3, 0, -2, 0]
        bounceAnimation.keyTimes = [0, 0.25, 0.5, 0.75, 1.0]
        bounceAnimation.duration = 0.4
        bounceAnimation.repeatCount = .infinity
        bounceAnimation.isAdditive = true

        let hopAnimation = CAKeyframeAnimation(keyPath: "position.x")
        hopAnimation.values = [0, 3, 0]
        hopAnimation.keyTimes = [0, 0.5, 1.0]
        hopAnimation.duration = 0.4
        hopAnimation.repeatCount = .infinity
        hopAnimation.isAdditive = true

        rabbitLabel.layer?.add(bounceAnimation, forKey: "bounce")
        rabbitLabel.layer?.add(hopAnimation, forKey: "hop")

        return view
    }
}
