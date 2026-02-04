import AppKit
import Foundation

extension StatusBarController {

    func createDetailSubmenu(_ details: DetailedUsage, identifier: ProviderIdentifier, accountId: String? = nil) -> NSMenu {
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

        case .copilot:
            // === Usage ===
            if let used = details.copilotUsedRequests, let limit = details.copilotLimitRequests, limit > 0 {
                let filledBlocks = Int((Double(used) / Double(max(limit, 1))) * 10)
                let emptyBlocks = 10 - filledBlocks
                let progressBar = String(repeating: "═", count: filledBlocks) + String(repeating: "░", count: emptyBlocks)
                let progressItem = NSMenuItem()
                progressItem.view = createDisabledLabelView(text: "[\(progressBar)] \(used)/\(limit)")
                submenu.addItem(progressItem)

                let usagePercent = (Double(used) / Double(limit)) * 100
                let items = createUsageWindowRow(label: "Monthly", usagePercent: usagePercent, resetDate: details.copilotQuotaResetDateUTC, isMonthly: true)
                items.forEach { submenu.addItem($0) }
            } else {
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: "Usage data unavailable")
                submenu.addItem(item)
            }

            // === Plan & Quota ===
            submenu.addItem(NSMenuItem.separator())

            if let planType = details.planType {
                // Replicate CopilotUsage.planDisplayName logic since DetailedUsage stores raw plan string
                let planName: String
                switch planType.lowercased() {
                case "individual_pro": planName = "Pro"
                case "individual_free": planName = "Free"
                case "business": planName = "Business"
                case "enterprise": planName = "Enterprise"
                default: planName = planType.replacingOccurrences(of: "_", with: " ").capitalized
                }
                let planItem = NSMenuItem()
                planItem.view = createDisabledLabelView(
                    text: "Plan: \(planName)",
                    icon: NSImage(systemSymbolName: "crown", accessibilityDescription: "Plan")
                )
                submenu.addItem(planItem)
            }

            if let limit = details.copilotLimitRequests {
                let freeItem = NSMenuItem()
                freeItem.view = createDisabledLabelView(text: "Quota Limit: \(limit)")
                submenu.addItem(freeItem)
            }

            // === Account Info ===
            submenu.addItem(NSMenuItem.separator())

            if let email = details.email {
                let emailItem = NSMenuItem()
                emailItem.view = createDisabledLabelView(
                    text: "Account: \(email)",
                    icon: NSImage(systemSymbolName: "person.circle", accessibilityDescription: "User Account"),
                    multiline: false
                )
                submenu.addItem(emailItem)
            }

            let authSource = details.authSource ?? "Browser Cookies (Chrome/Brave/Arc/Edge)"
            let authItem = NSMenuItem()
            authItem.view = createDisabledLabelView(
                text: "Token From: \(authSource)",
                icon: NSImage(systemSymbolName: "key", accessibilityDescription: "Auth Source"),
                multiline: true
            )
            submenu.addItem(authItem)

            // === Subscription ===
            addSubscriptionItems(to: submenu, provider: .copilot, accountId: accountId)

        case .claude:
            // === Usage Windows ===
            if let fiveHour = details.fiveHourUsage {
                let items = createUsageWindowRow(
                    label: "5h",
                    usagePercent: fiveHour,
                    resetDate: details.fiveHourReset,
                    windowHours: 5
                )
                items.forEach { submenu.addItem($0) }
            }
            if let sevenDay = details.sevenDayUsage {
                let items = createUsageWindowRow(
                    label: "Weekly",
                    usagePercent: sevenDay,
                    resetDate: details.sevenDayReset,
                    windowHours: 168
                )
                items.forEach { submenu.addItem($0) }
            }

            // === Model Breakdown ===
            submenu.addItem(NSMenuItem.separator())
            if let sonnet = details.sonnetUsage {
                let items = createUsageWindowRow(
                    label: "Sonnet (Weekly)",
                    usagePercent: sonnet,
                    resetDate: details.sonnetReset,
                    windowHours: 168
                )
                items.forEach { submenu.addItem($0) }
            }
            if let opus = details.opusUsage {
                let items = createUsageWindowRow(
                    label: "Opus (Weekly)",
                    usagePercent: opus,
                    resetDate: details.opusReset,
                    windowHours: 168
                )
                items.forEach { submenu.addItem($0) }
            }

            // === Extra Usage ===
            if let extraUsage = details.extraUsageEnabled {
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: "Extra Usage: \(extraUsage ? "ON" : "OFF")")
                submenu.addItem(item)
            }

            // === Subscription (includes separator internally) ===
            addSubscriptionItems(to: submenu, provider: .claude, accountId: accountId)

        case .codex:
            // === Usage Windows ===
            if let primary = details.dailyUsage {
                // BUGFIX: Codex primary window is 5 hours, not 24
                let items = createUsageWindowRow(
                    label: "5h",
                    usagePercent: primary,
                    resetDate: details.primaryReset,
                    windowHours: 5
                )
                items.forEach { submenu.addItem($0) }
            }
            if let secondary = details.secondaryUsage {
                let items = createUsageWindowRow(
                    label: "Weekly",
                    usagePercent: secondary,
                    resetDate: details.secondaryReset,
                    windowHours: 168
                )
                items.forEach { submenu.addItem($0) }
            }

            // === Credits & Plan ===
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

            // === Subscription ===
            addSubscriptionItems(to: submenu, provider: .codex, accountId: accountId)

        case .geminiCLI:
            // modelBreakdown stores remaining% — convert to used% at display layer
            if let models = details.modelBreakdown, !models.isEmpty {
                for (model, remainingPercent) in models.sorted(by: { $0.key < $1.key }) {
                    let usedPercent = 100 - remainingPercent
                    let item = NSMenuItem()
                    item.view = createDisabledLabelView(text: String(format: "%@: %.0f%% used", model, usedPercent))
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

            addSubscriptionItems(to: submenu, provider: .geminiCLI, accountId: accountId ?? details.email)

        case .antigravity:
            // modelBreakdown stores remaining% — convert to used% at display layer
            if let models = details.modelBreakdown, !models.isEmpty {
                for (model, remainingPercent) in models.sorted(by: { $0.key < $1.key }) {
                    let usedPercent = 100 - remainingPercent
                    let item = NSMenuItem()
                    item.view = createDisabledLabelView(text: String(format: "%@: %.0f%% used", model, usedPercent))
                    submenu.addItem(item)
                }
            }

            var accountItems: [(sfSymbol: String, text: String)] = []
            if let plan = details.planType {
                accountItems.append((sfSymbol: "crown", text: "Plan: \(plan)"))
            }
            if let email = details.email {
                accountItems.append((sfSymbol: "person.circle", text: "Email: \(email)"))
            }
            if !accountItems.isEmpty {
                createAccountInfoSection(items: accountItems).forEach { submenu.addItem($0) }
            }

            addSubscriptionItems(to: submenu, provider: .antigravity, accountId: accountId)

        case .kimi:
            // === Usage Windows ===
            if let fiveHour = details.fiveHourUsage {
                let items = createUsageWindowRow(
                    label: "5h",
                    usagePercent: fiveHour,
                    resetDate: details.fiveHourReset,
                    windowHours: 5
                )
                items.forEach { submenu.addItem($0) }
            }
            if let weekly = details.sevenDayUsage {
                let items = createUsageWindowRow(
                    label: "Weekly",
                    usagePercent: weekly,
                    resetDate: details.sevenDayReset,
                    windowHours: 168
                )
                items.forEach { submenu.addItem($0) }
            }

            // === Plan ===
            if let plan = details.planType {
                submenu.addItem(NSMenuItem.separator())
                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: "Plan: \(plan)")
                submenu.addItem(item)
            }

            // === Subscription ===
            addSubscriptionItems(to: submenu, provider: .kimi, accountId: accountId)

        case .zaiCodingPlan:
            // === Token Usage ===
            if let tokenUsage = details.tokenUsagePercent {
                let items = createUsageWindowRow(
                    label: "Tokens (5h)",
                    usagePercent: tokenUsage,
                    resetDate: details.tokenUsageReset,
                    windowHours: 5
                )
                items.forEach { submenu.addItem($0) }
            }
            if let tokenUsed = details.tokenUsageUsed, let tokenTotal = details.tokenUsageTotal {
                let item = createLimitRow(label: "Tokens", used: Double(tokenUsed), total: Double(tokenTotal))
                submenu.addItem(item)
            }

            // === MCP Usage ===
            if let mcpUsage = details.mcpUsagePercent {
                let items = createUsageWindowRow(
                    label: "MCP (Monthly)",
                    usagePercent: mcpUsage,
                    resetDate: details.mcpUsageReset,
                    isMonthly: true
                )
                items.forEach { submenu.addItem($0) }
            }
            if let mcpUsed = details.mcpUsageUsed, let mcpTotal = details.mcpUsageTotal {
                let item = createLimitRow(label: "MCP", used: Double(mcpUsed), total: Double(mcpTotal))
                submenu.addItem(item)
            }

            // === Last 24h stats (provider-specific, keep as-is) ===
            let numberFormatter = NumberFormatter()
            numberFormatter.numberStyle = .decimal
            numberFormatter.maximumFractionDigits = 0

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

            // === Subscription ===
            addSubscriptionItems(to: submenu, provider: .zaiCodingPlan, accountId: accountId)

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

        // modelBreakdown stores remaining% — convert to used% at display layer
        // Gemini models have 24-hour quota windows
        for (model, remainingPercent) in account.modelBreakdown.sorted(by: { $0.key < $1.key }) {
            let usedPercent = 100 - remainingPercent
            let items = createUsageWindowRow(
                label: model,
                usagePercent: usedPercent,
                resetDate: account.modelResetTimes[model],
                windowHours: 24
            )
            items.forEach { submenu.addItem($0) }
        }

        let accountItems: [(sfSymbol: String, text: String)] = [
            (sfSymbol: "person.circle", text: "Email: \(account.email)"),
            (sfSymbol: "key", text: "Token From: \(account.authSource)")
        ]
        createAccountInfoSection(items: accountItems).forEach { submenu.addItem($0) }

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

    // MARK: - Shared UI Helpers for Unified Provider Menus

    /// Creates unified usage window display with optional reset time and pace indicator.
    /// Returns array of NSMenuItems: [usage row, reset row (optional), pace row (optional)]
    func createUsageWindowRow(
        label: String,
        usagePercent: Double,
        resetDate: Date? = nil,
        windowHours: Int? = nil,
        isMonthly: Bool = false
    ) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        let usageItem = NSMenuItem()
        usageItem.view = createDisabledLabelView(text: String(format: "%@: %.0f%% used", label, usagePercent))
        items.append(usageItem)

        if let resetDate = resetDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
            formatter.timeZone = TimeZone.current
            let resetItem = NSMenuItem()
            resetItem.view = createDisabledLabelView(text: "Resets: \(formatter.string(from: resetDate))", indent: 18)
            items.append(resetItem)

            let paceInfo: PaceInfo
            if isMonthly {
                paceInfo = calculateMonthlyPace(usagePercent: usagePercent, resetDate: resetDate)
            } else if let windowHours = windowHours {
                paceInfo = calculatePace(usage: usagePercent, resetTime: resetDate, windowHours: windowHours)
            } else {
                return items
            }

            let paceItem = NSMenuItem()
            paceItem.view = createPaceView(paceInfo: paceInfo)
            items.append(paceItem)
        }

        return items
    }

    /// Creates a "used/total" display row with optional unit prefix.
    /// Example: "Tokens: 12,345 / 100,000", "Credits: $3.50 / $10.00"
    func createLimitRow(label: String, used: Double, total: Double, unitPrefix: String = "") -> NSMenuItem {
        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal
        numberFormatter.maximumFractionDigits = 0

        let formattedUsed = numberFormatter.string(from: NSNumber(value: used)) ?? "\(Int(used))"
        let formattedTotal = numberFormatter.string(from: NSNumber(value: total)) ?? "\(Int(total))"

        let item = NSMenuItem()
        item.view = createDisabledLabelView(
            text: "\(label): \(unitPrefix)\(formattedUsed) / \(unitPrefix)\(formattedTotal)"
        )
        return item
    }

    /// Creates unified account info section with SF Symbol icons.
    /// Returns [separator, item1, item2, ...]. Enables multiline for "Token From:" items.
    func createAccountInfoSection(items: [(sfSymbol: String, text: String)]) -> [NSMenuItem] {
        var menuItems: [NSMenuItem] = []
        menuItems.append(NSMenuItem.separator())

        for item in items {
            let menuItem = NSMenuItem()
            let needsMultiline = item.text.hasPrefix("Token From:")
            menuItem.view = createDisabledLabelView(
                text: item.text,
                icon: NSImage(systemSymbolName: item.sfSymbol, accessibilityDescription: nil),
                multiline: needsMultiline
            )
            menuItems.append(menuItem)
        }

        return menuItems
    }

}
