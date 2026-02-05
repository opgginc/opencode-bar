import AppKit
import SwiftUI
import ServiceManagement
import WebKit
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "StatusBarController")

enum UsageFetcherError: LocalizedError {
    case noCustomerId
    case noUsageData
    case invalidJSResult
    case parsingFailed(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .noCustomerId:
            return "Customer ID not found"
        case .noUsageData:
            return "Usage data not found"
        case .invalidJSResult:
            return "Invalid JS result"
        case .parsingFailed(let detail):
            return "Parsing failed: \(detail)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var statusBarIconView: StatusBarIconView?
    private var menu: NSMenu!
    private var signInItem: NSMenuItem!
    private var resetLoginItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var installCLIItem: NSMenuItem!
    private var refreshIntervalMenu: NSMenu!
    private var refreshTimer: Timer?

    private var currentUsage: CopilotUsage?
    private var lastFetchTime: Date?
    private var isFetching = false

    // History fetch properties
    private var historyFetchTimer: Timer?
    private var customerId: String?

    // History properties (for Copilot provider via CopilotHistoryService)
    private var usageHistory: UsageHistory?
    private var lastHistoryFetchResult: HistoryFetchResult = .none

    // History UI properties
    private var historySubmenu: NSMenu!
    private var historyMenuItem: NSMenuItem!
    var predictionPeriodMenu: NSMenu!

     // Multi-provider properties
     private var providerResults: [ProviderIdentifier: ProviderResult] = [:]
     private var loadingProviders: Set<ProviderIdentifier> = []
     private var enabledProvidersMenu: NSMenu!
     private var lastProviderErrors: [ProviderIdentifier: String] = [:]
     private var viewErrorDetailsItem: NSMenuItem!
     private var orphanedSubscriptionKeys: [String] = []
     private var orphanedSubscriptionTotal: Double = 0

    private var usagePredictor: UsagePredictor {
        UsagePredictor(weights: predictionPeriod.weights)
    }

    enum HistoryFetchResult {
        case none
        case success
        case failedWithCache
        case failedNoCache
    }

    struct HistoryUIState {
        let history: UsageHistory?
        let prediction: UsagePrediction?
        let isStale: Bool
        let hasNoData: Bool
    }

    private var refreshInterval: RefreshInterval {
        get {
            let rawValue = UserDefaults.standard.integer(forKey: "refreshInterval")
            return RefreshInterval(rawValue: rawValue) ?? .defaultInterval
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "refreshInterval")
            restartRefreshTimer()
            updateRefreshIntervalMenu()
        }
    }

    private var predictionPeriod: PredictionPeriod {
        get {
            let rawValue = UserDefaults.standard.integer(forKey: "predictionPeriod")
            return PredictionPeriod(rawValue: rawValue) ?? .defaultPeriod
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "predictionPeriod")
            updatePredictionPeriodMenu()
            updateHistorySubmenu()
            updateMultiProviderMenu()
        }
    }

    override init() {
        super.init()
        debugLog("StatusBarController init started")

        TokenManager.shared.logDebugEnvironmentInfo()
        debugLog("Environment debug info logged")

        setupStatusItem()
        debugLog("setupStatusItem completed")
        setupMenu()
        debugLog("setupMenu completed")
        setupNotificationObservers()
        debugLog("setupNotificationObservers completed")
        startRefreshTimer()
        debugLog("startRefreshTimer completed")
        checkAndPromptGitHubStar()
        debugLog("checkAndPromptGitHubStar called")
        logger.info("Init completed")
        debugLog("Init completed")
    }

    func debugLog(_ message: String) {
        let msg = "[\(Date())] \(message)\n"
        if let data = msg.data(using: .utf8) {
            let path = "/tmp/provider_debug.log"
            if FileManager.default.fileExists(atPath: path) {
                if let handle = FileHandle(forWritingAtPath: path) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusBarIconView = StatusBarIconView(frame: NSRect(x: 0, y: 0, width: 70, height: 23))
        statusBarIconView?.showLoading()
        statusItem?.button?.addSubview(statusBarIconView!)
        statusItem?.button?.frame = statusBarIconView!.frame
    }

    private func setupMenu() {
        menu = NSMenu()

        historyMenuItem = NSMenuItem(title: "Usage History", action: nil, keyEquivalent: "")
        historyMenuItem.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Usage History")
        historySubmenu = NSMenu()
        historyMenuItem.submenu = historySubmenu
        let loadingItem = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
        loadingItem.isEnabled = false
        historySubmenu.addItem(loadingItem)
        // Removed: History now in Copilot submenu only (see createCopilotHistorySubmenu())
        // menu.addItem(historyMenuItem)

        // Load cached history immediately on startup (before API fetch completes)
        loadCachedHistoryOnStartup()

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let checkForUpdatesItem = NSMenuItem(title: "Check for Updates...", action: #selector(AppDelegate.checkForUpdates), keyEquivalent: "u")
        checkForUpdatesItem.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Check for Updates")
        checkForUpdatesItem.target = NSApp.delegate
        menu.addItem(checkForUpdatesItem)

        let refreshIntervalItem = NSMenuItem(title: "Auto Refresh", action: nil, keyEquivalent: "")
        refreshIntervalItem.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Auto Refresh")
        refreshIntervalMenu = NSMenu()
        for interval in RefreshInterval.allCases {
            let item = NSMenuItem(title: interval.title, action: #selector(refreshIntervalSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = interval.rawValue
            refreshIntervalMenu.addItem(item)
        }
        refreshIntervalItem.submenu = refreshIntervalMenu
        menu.addItem(refreshIntervalItem)
        updateRefreshIntervalMenu()

        predictionPeriodMenu = NSMenu()
        for period in PredictionPeriod.allCases {
            let item = NSMenuItem(title: period.title, action: #selector(predictionPeriodSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = period.rawValue
            predictionPeriodMenu.addItem(item)
        }
        updatePredictionPeriodMenu()

        menu.addItem(NSMenuItem.separator())

        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(launchAtLoginClicked), keyEquivalent: "")
        launchAtLoginItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Launch at Login")
        launchAtLoginItem.target = self
        updateLaunchAtLoginState()
        menu.addItem(launchAtLoginItem)

        installCLIItem = NSMenuItem(title: "Install CLI (opencodebar)", action: #selector(installCLIClicked), keyEquivalent: "")
        installCLIItem.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Install CLI")
        installCLIItem.target = self
        menu.addItem(installCLIItem)
        updateCLIInstallState()

        menu.addItem(NSMenuItem.separator())

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let versionItem = NSMenuItem(title: "OpenCode Bar v\(version)", action: #selector(openGitHub), keyEquivalent: "")
        versionItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Version")
        versionItem.target = self
        menu.addItem(versionItem)

         let quitItem = NSMenuItem(title: "Quit", action: #selector(quitClicked), keyEquivalent: "q")
         quitItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Quit")
         quitItem.target = self
         menu.addItem(quitItem)
         
         menu.addItem(NSMenuItem.separator())
         
         viewErrorDetailsItem = NSMenuItem(title: "View Error Details...", action: #selector(viewErrorDetailsClicked), keyEquivalent: "e")
         viewErrorDetailsItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "View Error Details")
         viewErrorDetailsItem.target = self
         viewErrorDetailsItem.isHidden = true
         menu.addItem(viewErrorDetailsItem)
         
         statusItem?.menu = menu
         logMenuStructure()
     }

    /// Attach the existing menu to an external NSStatusItem (for MenuBarExtraAccess bridge)
    func attachTo(_ statusItem: NSStatusItem) {
        debugLog("attachTo: called with statusItem")
        self.statusItem = statusItem
        statusItem.menu = self.menu
        statusItem.length = NSStatusItem.variableLength
        
        if let iconView = statusBarIconView {
            debugLog("attachTo: setting up iconView")
            statusItem.button?.subviews.forEach { $0.removeFromSuperview() }
            statusItem.button?.addSubview(iconView)
            statusItem.button?.frame = iconView.frame
            debugLog("attachTo: iconView frame = \(iconView.frame)")
        } else {
            debugLog("attachTo: iconView is nil!")
        }
    }

    private func updateRefreshIntervalMenu() {
        for item in refreshIntervalMenu.items {
            item.state = (item.tag == refreshInterval.rawValue) ? .on : .off
        }
    }

    @objc private func refreshIntervalSelected(_ sender: NSMenuItem) {
        if let interval = RefreshInterval(rawValue: sender.tag) {
            refreshInterval = interval
        }
    }

    private func updatePredictionPeriodMenu() {
        for item in predictionPeriodMenu.items {
            item.state = (item.tag == predictionPeriod.rawValue) ? .on : .off
        }
    }

    @objc func predictionPeriodSelected(_ sender: NSMenuItem) {
        if let period = PredictionPeriod(rawValue: sender.tag) {
            predictionPeriod = period
        }
    }

    private func isProviderEnabled(_ identifier: ProviderIdentifier) -> Bool {
        let key = "provider.\(identifier.rawValue).enabled"
        if UserDefaults.standard.object(forKey: key) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    @objc private func toggleProvider(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let identifier = ProviderIdentifier(rawValue: idString) else { return }
        let key = "provider.\(identifier.rawValue).enabled"
        let current = isProviderEnabled(identifier)
        UserDefaults.standard.set(!current, forKey: key)
        updateEnabledProvidersMenu()
        refreshClicked()
    }

    private func updateEnabledProvidersMenu() {
        for item in enabledProvidersMenu.items {
            guard let idString = item.representedObject as? String,
                  let identifier = ProviderIdentifier(rawValue: idString) else { continue }
            item.state = isProviderEnabled(identifier) ? .on : .off
        }
    }

    private func restartRefreshTimer() {
        startRefreshTimer()
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(forName: .openCodeZenHistoryUpdated, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                self?.updateMultiProviderMenu()
            }
        }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()

        let interval = TimeInterval(refreshInterval.rawValue)
        let intervalTitle = refreshInterval.title
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            logger.info("Timer triggered (\(intervalTitle))")
            Task { @MainActor [weak self] in
                self?.triggerRefresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.triggerRefresh()
        }
    }

    func triggerRefresh() {
        logger.info("triggerRefresh started")
        fetchUsage()
    }

    private func fetchUsage() {
        debugLog("fetchUsage: called")
        logger.info("fetchUsage started, isFetching: \(self.isFetching)")

        guard !isFetching else {
            debugLog("fetchUsage: already fetching, returning")
            return
        }
        isFetching = true
        debugLog("fetchUsage: showing loading")
        statusBarIconView?.showLoading()

        debugLog("fetchUsage: creating Task")
        Task { @MainActor in
            debugLog("fetchUsage Task: calling fetchMultiProviderData")
            await fetchMultiProviderData()
            debugLog("fetchUsage Task: fetchMultiProviderData completed")
            debugLog("fetchUsage Task: all done, setting isFetching=false")
            self.isFetching = false
        }
        debugLog("fetchUsage: Task created")
    }

    // MARK: - Multi-Provider Fetch

     private func fetchMultiProviderData() async {
           debugLog("🔵 fetchMultiProviderData: started")
           logger.info("🔵 [StatusBarController] fetchMultiProviderData() started")
           
           let enabledProviders = await ProviderManager.shared.getAllProviders().filter { provider in
               isProviderEnabled(provider.identifier)
           }
           debugLog("🔵 fetchMultiProviderData: enabledProviders count=\(enabledProviders.count)")
           logger.debug("🔵 [StatusBarController] enabledProviders: \(enabledProviders.map { $0.identifier.displayName }.joined(separator: ", "))")

           guard !enabledProviders.isEmpty else {
               logger.info("🟡 [StatusBarController] fetchMultiProviderData: No enabled providers, skipping")
               debugLog("🟡 fetchMultiProviderData: No enabled providers, returning")
               return
           }

           loadingProviders = Set(enabledProviders.map { $0.identifier })
           let loadingCount = loadingProviders.count
           let loadingNames = loadingProviders.map { $0.displayName }.joined(separator: ", ")
           debugLog("🟡 fetchMultiProviderData: marked \(loadingCount) providers as loading")
           logger.debug("🟡 [StatusBarController] loadingProviders set: \(loadingNames)")
           updateMultiProviderMenu()

           logger.info("🟡 [StatusBarController] fetchMultiProviderData: Calling ProviderManager.fetchAll()")
           debugLog("🟡 fetchMultiProviderData: calling ProviderManager.fetchAll()")
           let fetchResult = await ProviderManager.shared.fetchAll()
           debugLog("🟢 fetchMultiProviderData: fetchAll returned \(fetchResult.results.count) results, \(fetchResult.errors.count) errors")
           logger.info("🟢 [StatusBarController] fetchMultiProviderData: fetchAll() returned \(fetchResult.results.count) results, \(fetchResult.errors.count) errors")

           let filteredResults = fetchResult.results.filter { identifier, _ in
               isProviderEnabled(identifier)
           }
           let filteredNames = filteredResults.keys.map { $0.displayName }.joined(separator: ", ")
           debugLog("🟢 fetchMultiProviderData: filteredResults count=\(filteredResults.count)")
           logger.debug("🟢 [StatusBarController] filteredResults: \(filteredNames)")

           self.providerResults = filteredResults
            
            // Extract CopilotUsage from provider result if available
            if let copilotResult = filteredResults[.copilot],
               let details = copilotResult.details,
               let usedRequests = details.copilotUsedRequests,
               let limitRequests = details.copilotLimitRequests {
                self.currentUsage = CopilotUsage(
                    netBilledAmount: details.copilotOverageCost ?? 0.0,
                    netQuantity: details.copilotOverageRequests ?? 0.0,
                    discountQuantity: Double(usedRequests),
                    userPremiumRequestEntitlement: limitRequests,
                    filteredUserPremiumRequestEntitlement: 0,
                    copilotPlan: details.planType,
                    quotaResetDateUTC: details.copilotQuotaResetDateUTC
                )
                debugLog("🟢 fetchMultiProviderData: currentUsage set from Copilot provider - used: \(usedRequests), limit: \(limitRequests)")
                logger.info("🟢 [StatusBarController] currentUsage set from Copilot provider")
            } else {
                debugLog("🟡 fetchMultiProviderData: No Copilot data available, currentUsage not set")
            }
            
            let filteredErrors = fetchResult.errors.filter { identifier, _ in
                isProviderEnabled(identifier)
            }
            self.lastProviderErrors = filteredErrors

           for identifier in filteredResults.keys {
               loadingProviders.remove(identifier)
           }
           for identifier in filteredErrors.keys {
               loadingProviders.remove(identifier)
           }
           let remainingLoading = loadingProviders.map { $0.displayName }.joined(separator: ", ")
           debugLog("🟢 fetchMultiProviderData: cleared loading state for \(filteredResults.count) results, \(filteredErrors.count) errors")
           logger.debug("🟢 [StatusBarController] loadingProviders after clear: \(remainingLoading)")
           self.viewErrorDetailsItem.isHidden = filteredErrors.isEmpty
           debugLog("📍 fetchMultiProviderData: viewErrorDetailsItem.isHidden = \(filteredErrors.isEmpty)")
           
           if !filteredErrors.isEmpty {
               let errorNames = filteredErrors.keys.map { $0.displayName }.joined(separator: ", ")
               debugLog("🔴 fetchMultiProviderData: errors from: \(errorNames)")
               logger.warning("🔴 [StatusBarController] Errors from providers: \(errorNames)")
           }
           debugLog("🟢 fetchMultiProviderData: calling updateMultiProviderMenu")
           logger.debug("🟢 [StatusBarController] providerResults updated, calling updateMultiProviderMenu()")
           self.updateMultiProviderMenu()
           debugLog("🟢 fetchMultiProviderData: updateMultiProviderMenu completed")
           logger.info("🟢 [StatusBarController] fetchMultiProviderData: updateMultiProviderMenu() completed")

           logger.info("🟢 [StatusBarController] fetchMultiProviderData: Completed with \(filteredResults.count) results")
           debugLog("🟢 fetchMultiProviderData: completed")
       }

    private func calculatePayAsYouGoTotal(providerResults: [ProviderIdentifier: ProviderResult], copilotUsage: CopilotUsage?) -> Double {
        var total = 0.0

        if let copilot = copilotUsage {
            total += copilot.netBilledAmount
        }

        for (_, result) in providerResults {
            if case .payAsYouGo(_, let cost, _) = result.usage, let cost = cost {
                total += cost
            }
        }

        return total
    }

    private func calculateTotalWithSubscriptions(providerResults: [ProviderIdentifier: ProviderResult], copilotUsage: CopilotUsage?) -> Double {
        let payAsYouGo = calculatePayAsYouGoTotal(providerResults: providerResults, copilotUsage: copilotUsage)
        let subscriptions = SubscriptionSettingsManager.shared.getTotalMonthlySubscriptionCost()
        return payAsYouGo + subscriptions
    }

    private func sanitizedSubscriptionKey(_ key: String) -> String {
        let parts = key.split(separator: ".", maxSplits: 1)
        if parts.count > 1 {
            return "\(parts[0]).<redacted>"
        }
        return String(parts[0])
    }

    private func orphanedIcon() -> NSImage? {
        let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Orphaned")
        let sizeConfig = NSImage.SymbolConfiguration(pointSize: MenuDesignToken.Dimension.iconSize, weight: .regular)
        let colorConfig = NSImage.SymbolConfiguration(hierarchicalColor: NSColor.systemOrange)
        let config = sizeConfig.applying(colorConfig)
        let image = symbol?.withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    }

    private func italicMenuTitle(_ text: String) -> NSAttributedString {
        let baseFont = MenuDesignToken.Typography.defaultFont
        let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        return NSAttributedString(string: text, attributes: [.font: italicFont])
    }

    private func providerIdentifier(for subscriptionKey: String) -> ProviderIdentifier? {
        let prefix = subscriptionKey.split(separator: ".", maxSplits: 1).first
        guard let prefix else { return nil }
        return ProviderIdentifier(rawValue: String(prefix))
    }

    private func collectVisibleSubscriptionKeys(providerResults: [ProviderIdentifier: ProviderResult]) -> Set<String> {
        var keys = Set<String>()

        for (identifier, result) in providerResults {
            guard isProviderEnabled(identifier) else { continue }

            if identifier == .geminiCLI,
               let details = result.details,
               let geminiAccounts = details.geminiAccounts,
               !geminiAccounts.isEmpty {
                for account in geminiAccounts {
                    let key = SubscriptionSettingsManager.shared.subscriptionKey(for: .geminiCLI, accountId: account.email)
                    keys.insert(key)
                }
                continue
            }

            if let accounts = result.accounts, !accounts.isEmpty {
                for account in accounts {
                    if let accountId = account.accountId, !accountId.isEmpty {
                        keys.insert(SubscriptionSettingsManager.shared.subscriptionKey(for: identifier, accountId: accountId))
                    } else {
                        keys.insert(SubscriptionSettingsManager.shared.subscriptionKey(for: identifier))
                    }
                }
            } else {
                keys.insert(SubscriptionSettingsManager.shared.subscriptionKey(for: identifier))
            }
        }

        return keys
    }

    private func calculateOrphanedSubscriptions(providerResults: [ProviderIdentifier: ProviderResult]) -> (keys: [String], total: Double) {
        let visibleKeys = collectVisibleSubscriptionKeys(providerResults: providerResults)
        let allKeys = SubscriptionSettingsManager.shared.getAllSubscriptionKeys()

        var orphaned: [String] = []
        var total = 0.0

        for key in allKeys {
            if visibleKeys.contains(key) {
                continue
            }
            // Skip if provider is currently loading, disabled, or not visible in results
            // This prevents false positives when:
            // 1. Provider is disabled in settings
            // 2. Network error caused fetch to fail (provider not in providerResults)
            // 3. Provider is still loading
            if let provider = providerIdentifier(for: key) {
                if loadingProviders.contains(provider) {
                    continue
                }
                if !isProviderEnabled(provider) {
                    continue
                }
                // If provider is enabled but not in results, it likely failed to fetch
                // Don't mark as orphaned in this case
                if !providerResults.keys.contains(provider) {
                    continue
                }
            } else {
                // Unknown provider prefix - skip to avoid false orphan detection
                // This handles corrupted keys or keys for future/unsupported providers
                continue
            }

            let plan = SubscriptionSettingsManager.shared.getPlan(forKey: key)
            if plan.cost <= 0 {
                continue
            }

            orphaned.append(key)
            total += plan.cost
        }

        if orphaned.isEmpty {
            debugLog("Orphaned subscriptions: none")
        } else {
            let formattedTotal = String(format: "%.2f", total)
            let sanitizedKeys = orphaned.map { sanitizedSubscriptionKey($0) }.joined(separator: ", ")
            debugLog("Orphaned subscriptions detected: \(orphaned.count) key(s), total=$\(formattedTotal), keys=[\(sanitizedKeys)]")
        }

        return (orphaned, total)
    }

      private func updateMultiProviderMenu() {
          debugLog("updateMultiProviderMenu: started")
          guard let separatorIndex = menu.items.firstIndex(where: { $0.isSeparatorItem }) else {
              debugLog("updateMultiProviderMenu: no separator found, returning")
              return
          }
          debugLog("updateMultiProviderMenu: separatorIndex=\(separatorIndex)")

          var itemsToRemove: [NSMenuItem] = []
          let startIndex = separatorIndex + 1
          if startIndex < menu.items.count {
              for i in startIndex..<menu.items.count {
                  let item = menu.items[i]
                  if item.tag == 999 {
                      itemsToRemove.append(item)
                  }
              }
          }
          debugLog("updateMultiProviderMenu: removing \(itemsToRemove.count) old items")
          itemsToRemove.forEach { menu.removeItem($0) }

          debugLog("updateMultiProviderMenu: providerResults.count=\(providerResults.count)")

          if !providerResults.isEmpty {
              let providerNames = providerResults.keys.map { $0.rawValue }.joined(separator: ", ")
              debugLog("updateMultiProviderMenu: providers=[\(providerNames)]")
          }

          guard !providerResults.isEmpty else {
              debugLog("updateMultiProviderMenu: no data, returning")
              return
          }

        var insertIndex = separatorIndex + 1

         let separator1 = NSMenuItem.separator()
         separator1.tag = 999
         menu.insertItem(separator1, at: insertIndex)
         insertIndex += 1

          let payAsYouGoTotal = calculatePayAsYouGoTotal(providerResults: providerResults, copilotUsage: currentUsage)
          let subscriptionTotal = SubscriptionSettingsManager.shared.getTotalMonthlySubscriptionCost()
          
          let payAsYouGoHeader = NSMenuItem()
          payAsYouGoHeader.view = createHeaderView(title: String(format: "Pay-as-you-go: $%.2f", payAsYouGoTotal))
          payAsYouGoHeader.tag = 999
          menu.insertItem(payAsYouGoHeader, at: insertIndex)
          insertIndex += 1

         var hasPayAsYouGo = false

            let payAsYouGoOrder: [ProviderIdentifier] = [.openRouter, .openCodeZen]
            for identifier in payAsYouGoOrder {
                guard isProviderEnabled(identifier) else { continue }

                if let result = providerResults[identifier] {
                    if case .payAsYouGo(_, let cost, _) = result.usage {
                        hasPayAsYouGo = true
                        let costValue = cost ?? 0.0
                        let item = NSMenuItem(
                            title: String(format: "%@ ($%.2f)", identifier.displayName, costValue),
                            action: nil, keyEquivalent: ""
                        )
                        item.image = iconForProvider(identifier)
                        item.tag = 999

                        if let details = result.details, details.hasAnyValue {
                            item.submenu = createDetailSubmenu(details, identifier: identifier)
                        }

                       menu.insertItem(item, at: insertIndex)
                       insertIndex += 1
                   }
                } else if let errorMessage = lastProviderErrors[identifier] {
                    hasPayAsYouGo = true
                    let item = createErrorMenuItem(identifier: identifier, errorMessage: errorMessage)
                    menu.insertItem(item, at: insertIndex)
                    insertIndex += 1
                } else if loadingProviders.contains(identifier) {
                    hasPayAsYouGo = true
                    let item = NSMenuItem(title: "\(identifier.displayName) (Loading...)", action: nil, keyEquivalent: "")
                    item.image = iconForProvider(identifier)
                    item.isEnabled = false
                    item.tag = 999
                    menu.insertItem(item, at: insertIndex)
                    insertIndex += 1
                }
           }

            // Copilot Add-on (always show, even when $0.00)
            if isProviderEnabled(.copilot) {
                if let copilotResult = providerResults[.copilot],
                   let details = copilotResult.details,
                   let overageCost = details.copilotOverageCost {
                    hasPayAsYouGo = true
                    let addOnItem = NSMenuItem(
                        title: String(format: "Copilot Add-on ($%.2f)", overageCost),
                        action: nil, keyEquivalent: ""
                    )
                    addOnItem.image = iconForProvider(.copilot)
                    addOnItem.tag = 999

                    let submenu = NSMenu()
                    let overageRequests = details.copilotOverageRequests ?? 0
                    let overageItem = NSMenuItem()
                    overageItem.view = createDisabledLabelView(text: String(format: "Overage Requests: %.0f", overageRequests))
                    submenu.addItem(overageItem)

                    submenu.addItem(NSMenuItem.separator())
                    let historyItem = NSMenuItem(title: "Usage History", action: nil, keyEquivalent: "")
                    historyItem.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Usage History")
                    debugLog("updateMultiProviderMenu: calling createCopilotHistorySubmenu")
                    historyItem.submenu = createCopilotHistorySubmenu()
                    debugLog("updateMultiProviderMenu: createCopilotHistorySubmenu completed")
                    submenu.addItem(historyItem)

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

                    if let authSource = details.authSource {
                        let authItem = NSMenuItem()
                        authItem.view = createDisabledLabelView(
                            text: "Token From: \(authSource)",
                            icon: NSImage(systemSymbolName: "key", accessibilityDescription: "Auth Source"),
                            multiline: true
                        )
                        submenu.addItem(authItem)
                    }

                    addOnItem.submenu = submenu
                    menu.insertItem(addOnItem, at: insertIndex)
                    insertIndex += 1
                    debugLog("updateMultiProviderMenu: Copilot Add-on inserted with cost $\(overageCost)")
                } else if loadingProviders.contains(.copilot) {
                    hasPayAsYouGo = true
                    let item = NSMenuItem(title: "Copilot Add-on (Loading...)", action: nil, keyEquivalent: "")
                    item.image = iconForProvider(.copilot)
                    item.isEnabled = false
                    item.tag = 999
                    menu.insertItem(item, at: insertIndex)
                    insertIndex += 1
                }
            }

        if !hasPayAsYouGo {
            let noItem = NSMenuItem()
            noItem.view = createDisabledLabelView(text: "No providers")
            noItem.tag = 999
            menu.insertItem(noItem, at: insertIndex)
            insertIndex += 1
        }

        if hasPayAsYouGo {
            insertIndex = insertPredictedEOMSection(at: insertIndex)
        }

        let separator2 = NSMenuItem.separator()
        separator2.tag = 999
        menu.insertItem(separator2, at: insertIndex)
        insertIndex += 1

         let quotaHeader = NSMenuItem()
         let quotaTitle = subscriptionTotal > 0
             ? String(format: "Quota Status: $%.0f/m", subscriptionTotal)
             : "Quota Status"
         quotaHeader.view = createHeaderView(title: quotaTitle)
         quotaHeader.tag = 999
         menu.insertItem(quotaHeader, at: insertIndex)
         insertIndex += 1

         var hasQuota = false

            if let copilotResult = providerResults[.copilot],
               let accounts = copilotResult.accounts,
               !accounts.isEmpty {
                let copilotAuthLabels = Set(
                    accounts.map { account in
                        authSourceLabel(for: account.details?.authSource, provider: .copilot) ?? "Unknown"
                    }
                )
                let showCopilotAuthLabel = copilotAuthLabels.count > 1
                let baseName = multiAccountBaseName(for: .copilot)
                for account in accounts {
                    hasQuota = true
                    var displayName = accounts.count > 1 ? "\(baseName) #\(account.accountIndex + 1)" : baseName
                    if accounts.count > 1, showCopilotAuthLabel {
                        let sourceLabel = authSourceLabel(for: account.details?.authSource, provider: .copilot) ?? "Unknown"
                        displayName += " (\(sourceLabel))"
                    }
                    if (account.usage.totalEntitlement ?? 0) == 0 {
                        displayName += " (No usage data)"
                    }
                    let usedPercent = account.usage.usagePercentage
                    let quotaItem = createNativeQuotaMenuItem(
                        name: displayName,
                        usedPercent: usedPercent,
                        icon: iconForProvider(.copilot)
                    )
                    quotaItem.tag = 999

                    if let details = account.details, details.hasAnyValue {
                        quotaItem.submenu = createDetailSubmenu(details, identifier: .copilot, accountId: account.accountId)
                    }

                    menu.insertItem(quotaItem, at: insertIndex)
                    insertIndex += 1
                }
            } else if let copilotUsage = currentUsage {
                hasQuota = true
                let limit = copilotUsage.userPremiumRequestEntitlement
                let used = copilotUsage.usedRequests
                let usedPercent = limit > 0 ? (Double(used) / Double(limit)) * 100 : 0

                let quotaItem = createNativeQuotaMenuItem(
                    name: ProviderIdentifier.copilot.displayName,
                    usedPercent: usedPercent,
                    icon: iconForProvider(.copilot)
                )
                quotaItem.tag = 999

                if let details = providerResults[.copilot]?.details, details.hasAnyValue {
                    quotaItem.submenu = createDetailSubmenu(details, identifier: .copilot)
                } else {
                    let submenu = NSMenu()
                    let filledBlocks = Int((Double(used) / Double(max(limit, 1))) * 10)
                    let emptyBlocks = 10 - filledBlocks
                    let progressBar = String(repeating: "═", count: filledBlocks) + String(repeating: "░", count: emptyBlocks)
                    let progressItem = NSMenuItem()
                    progressItem.view = createDisabledLabelView(text: "[\(progressBar)] \(used)/\(limit)")
                    submenu.addItem(progressItem)

                    let usagePercent = limit > 0 ? (Double(used) / Double(limit)) * 100 : 0
                    let usedItem = NSMenuItem()
                    usedItem.view = createDisabledLabelView(text: String(format: "Monthly Usage: %.0f%%", usagePercent))
                    submenu.addItem(usedItem)

                    if let resetDate = copilotUsage.quotaResetDateUTC {
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yyyy-MM-dd HH:mm"
                        formatter.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
                        let resetItem = NSMenuItem()
                        resetItem.view = createDisabledLabelView(text: "Resets: \(formatter.string(from: resetDate)) UTC", indent: 18)
                        submenu.addItem(resetItem)

                        let paceInfo = calculateMonthlyPace(usagePercent: usagePercent, resetDate: resetDate)
                        let paceItem = NSMenuItem()
                        paceItem.view = createPaceView(paceInfo: paceInfo)
                        submenu.addItem(paceItem)
                    }

                    submenu.addItem(NSMenuItem.separator())

                    if let planName = copilotUsage.planDisplayName {
                        let planItem = NSMenuItem()
                        planItem.view = createDisabledLabelView(
                            text: "Plan: \(planName)",
                            icon: NSImage(systemSymbolName: "crown", accessibilityDescription: "Plan")
                        )
                        submenu.addItem(planItem)
                    }

                    let freeItem = NSMenuItem()
                    freeItem.view = createDisabledLabelView(text: "Quota Limit: \(limit)")
                    submenu.addItem(freeItem)

                    submenu.addItem(NSMenuItem.separator())

                    if let email = providerResults[.copilot]?.details?.email {
                        let emailItem = NSMenuItem()
                        emailItem.view = createDisabledLabelView(
                            text: "Email: \(email)",
                            icon: NSImage(systemSymbolName: "person.circle", accessibilityDescription: "User Email"),
                            multiline: false
                        )
                        submenu.addItem(emailItem)
                    }

                    let authItem = NSMenuItem()
                    authItem.view = createDisabledLabelView(
                        text: "Token From: Browser Cookies (Chrome/Brave/Arc/Edge)",
                        icon: NSImage(systemSymbolName: "key", accessibilityDescription: "Auth Source"),
                        multiline: true
                    )
                    submenu.addItem(authItem)

                    addSubscriptionItems(to: submenu, provider: .copilot)

                    quotaItem.submenu = submenu
                }

                menu.insertItem(quotaItem, at: insertIndex)
                insertIndex += 1
            }

        let quotaOrder: [ProviderIdentifier] = [
            .claude,
            .kimi,
            .codex,
            .zaiCodingPlan,
            .antigravity,
            .chutes,
            .synthetic
        ]
        for identifier in quotaOrder {
            guard isProviderEnabled(identifier) else { continue }

            if let result = providerResults[identifier] {
                if let accounts = result.accounts, !accounts.isEmpty {
                    let authLabels = Set(
                        accounts.map { account in
                            authSourceLabel(for: account.details?.authSource, provider: identifier) ?? "Unknown"
                        }
                    )
                    let showAuthLabel = authLabels.count > 1
                    let baseName = multiAccountBaseName(for: identifier)
                    for account in accounts {
                        hasQuota = true
                        var displayName = accounts.count > 1 ? "\(baseName) #\(account.accountIndex + 1)" : baseName
                        if accounts.count > 1, showAuthLabel {
                            let sourceLabel = authSourceLabel(for: account.details?.authSource, provider: identifier) ?? "Unknown"
                            displayName += " (\(sourceLabel))"
                        }
                        if (account.usage.totalEntitlement ?? 0) == 0 {
                            displayName += " (No usage data)"
                        }

                        // Build percentage array for display
                        // Claude/Kimi: show both 5h and 7d usage windows
                        // Codex: show both primary (5h) and secondary (weekly) windows
                        // Other providers: show single usage percentage
                        let usedPercents: [Double]
                        if identifier == .claude || identifier == .kimi,
                           let fiveHour = account.details?.fiveHourUsage,
                           let sevenDay = account.details?.sevenDayUsage {
                            usedPercents = [fiveHour, sevenDay]
                        } else if identifier == .codex,
                                  let secondary = account.details?.secondaryUsage {
                            usedPercents = [account.usage.usagePercentage, secondary]
                        } else {
                            usedPercents = [account.usage.usagePercentage]
                        }
                        let item = createNativeQuotaMenuItem(name: displayName, usedPercents: usedPercents, icon: iconForProvider(identifier))
                        item.tag = 999

                        if let details = account.details, details.hasAnyValue {
                            item.submenu = createDetailSubmenu(details, identifier: identifier, accountId: account.accountId)
                        }

                        menu.insertItem(item, at: insertIndex)
                        insertIndex += 1
                    }
                } else if case .quotaBased(let remaining, let entitlement, _) = result.usage {
                    hasQuota = true
                    let singlePercent = entitlement > 0 ? (Double(entitlement - remaining) / Double(entitlement)) * 100 : 0

                    let usedPercents: [Double]
                    if identifier == .claude || identifier == .kimi,
                       let fiveHour = result.details?.fiveHourUsage,
                       let sevenDay = result.details?.sevenDayUsage {
                        usedPercents = [fiveHour, sevenDay]
                    } else if identifier == .codex,
                              let secondary = result.details?.secondaryUsage {
                        usedPercents = [singlePercent, secondary]
                    } else {
                        usedPercents = [singlePercent]
                    }
                    let item = createNativeQuotaMenuItem(name: identifier.displayName, usedPercents: usedPercents, icon: iconForProvider(identifier))
                    item.tag = 999

                    if let details = result.details, details.hasAnyValue {
                        item.submenu = createDetailSubmenu(details, identifier: identifier)
                    }

                    menu.insertItem(item, at: insertIndex)
                    insertIndex += 1
                }
            } else if let errorMessage = lastProviderErrors[identifier] {
                hasQuota = true
                let item = createErrorMenuItem(identifier: identifier, errorMessage: errorMessage)
                menu.insertItem(item, at: insertIndex)
                insertIndex += 1
            } else if loadingProviders.contains(identifier) {
                hasQuota = true
                let item = NSMenuItem(title: "\(identifier.displayName) (Loading...)", action: nil, keyEquivalent: "")
                item.image = iconForProvider(identifier)
                item.isEnabled = false
                item.tag = 999
                menu.insertItem(item, at: insertIndex)
                insertIndex += 1
            }
        }

        if isProviderEnabled(.geminiCLI) {
            if let result = providerResults[.geminiCLI],
               let details = result.details,
               let geminiAccounts = details.geminiAccounts,
               !geminiAccounts.isEmpty {
                let geminiAuthLabels = Set(
                    geminiAccounts.map { account in
                        authSourceLabel(for: account.authSource, provider: .geminiCLI) ?? "Unknown"
                    }
                )
                let showGeminiAuthLabel = geminiAuthLabels.count > 1

                for account in geminiAccounts {
                    hasQuota = true
                    let accountNumber = account.accountIndex + 1
                    let usedPercent = 100 - account.remainingPercentage
                    var displayName = geminiAccounts.count > 1
                        ? "Gemini CLI #\(accountNumber)"
                        : "Gemini CLI"
                    if geminiAccounts.count > 1, showGeminiAuthLabel {
                        let sourceLabel = authSourceLabel(for: account.authSource, provider: .geminiCLI) ?? "Unknown"
                        displayName += " (\(sourceLabel))"
                    }
                    let item = createNativeQuotaMenuItem(
                        name: displayName,
                        usedPercent: usedPercent,
                        icon: iconForProvider(.geminiCLI)
                    )
                    item.tag = 999

                    item.submenu = createGeminiAccountSubmenu(account)

                    menu.insertItem(item, at: insertIndex)
                    insertIndex += 1
                }
            } else if let errorMessage = lastProviderErrors[.geminiCLI] {
                hasQuota = true
                let item = createErrorMenuItem(identifier: .geminiCLI, errorMessage: errorMessage)
                menu.insertItem(item, at: insertIndex)
                insertIndex += 1
            } else if loadingProviders.contains(.geminiCLI) {
                hasQuota = true
                let item = NSMenuItem(title: "Gemini CLI (Loading...)", action: nil, keyEquivalent: "")
                item.image = iconForProvider(.geminiCLI)
                item.isEnabled = false
                item.tag = 999
                menu.insertItem(item, at: insertIndex)
                insertIndex += 1
            }
        }

        if !hasQuota {
            let noItem = NSMenuItem()
            noItem.view = createDisabledLabelView(text: "No providers")
            noItem.tag = 999
            menu.insertItem(noItem, at: insertIndex)
            insertIndex += 1
        }

        let orphaned = calculateOrphanedSubscriptions(providerResults: providerResults)
        orphanedSubscriptionKeys = orphaned.keys
        orphanedSubscriptionTotal = orphaned.total
        if orphaned.total > 0 {
            let title = String(format: "Orphaned ($%.2f)", orphaned.total)
            let orphanedItem = NSMenuItem(
                title: title,
                action: #selector(confirmResetOrphanedSubscriptions(_:)),
                keyEquivalent: ""
            )
            orphanedItem.target = self
            orphanedItem.attributedTitle = italicMenuTitle(title)
            orphanedItem.image = orphanedIcon()
            orphanedItem.tag = 999
            menu.insertItem(orphanedItem, at: insertIndex)
            insertIndex += 1
        }

        let separator3 = NSMenuItem.separator()
        separator3.tag = 999
        menu.insertItem(separator3, at: insertIndex)

        let totalCost = calculateTotalWithSubscriptions(providerResults: providerResults, copilotUsage: currentUsage)
        statusBarIconView?.update(cost: totalCost)
        debugLog("updateMultiProviderMenu: completed successfully, totalCost=$\(totalCost)")
        logMenuStructure()
    }

    private func logMenuStructure() {
        let total = menu.items.count
        let separators = menu.items.filter { $0.isSeparatorItem }.count
        let withAction = menu.items.filter { !$0.isSeparatorItem && $0.action != nil }.count
        let withSubmenu = menu.items.filter { $0.hasSubmenu }.count

        logger.info("📋 [Menu] Items: \(total) (sep:\(separators), actions:\(withAction), submenus:\(withSubmenu))")

        var output = "\n========== MENU STRUCTURE ==========\n"
        for (index, item) in menu.items.enumerated() {
            output += logMenuItem(item, depth: 0, index: index)
        }
        output += "====================================\n"
        debugLog(output)
    }

    private func logMenuItem(_ item: NSMenuItem, depth: Int, index: Int) -> String {
        let indent = String(repeating: "  ", count: depth)
        var line = ""

        if item.isSeparatorItem {
            line = "\(indent)[\(index)] ─────────────\n"
        } else if let view = item.view {
            let viewType = String(describing: type(of: view))
            if let label = view.subviews.compactMap({ $0 as? NSTextField }).first {
                line = "\(indent)[\(index)] [VIEW:\(viewType)] \(label.stringValue)\n"
            } else {
                line = "\(indent)[\(index)] [VIEW:\(viewType)]\n"
            }
        } else {
            line = "\(indent)[\(index)] \(item.title)\n"
        }

        if let submenu = item.submenu {
            for (subIndex, subItem) in submenu.items.enumerated() {
                line += logMenuItem(subItem, depth: depth + 1, index: subIndex)
            }
        }

        return line
    }

    private func createPayAsYouGoMenuItem(identifier: ProviderIdentifier, utilization: Double) -> NSMenuItem {
        let title = String(format: "%@    %.1f%%", identifier.displayName, utilization)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = iconForProvider(identifier)
        return item
    }

    private func multiAccountBaseName(for identifier: ProviderIdentifier) -> String {
        switch identifier {
        case .codex:
            return "ChatGPT"
        default:
            return identifier.displayName
        }
    }

    private func authSourceLabel(for authSource: String?, provider: ProviderIdentifier) -> String? {
        guard let authSource = authSource, !authSource.isEmpty else { return nil }
        let lowercased = authSource.lowercased()

        if lowercased.contains("opencode") {
            return "OpenCode"
        }

        switch provider {
        case .codex:
            if lowercased.contains(".codex") || lowercased.contains("/codex/") {
                return "Codex"
            }
        case .claude:
            if lowercased.contains("keychain") {
                return "Claude Code (Keychain)"
            }
            if lowercased.contains("claude-code") {
                return "Claude Code"
            }
            if lowercased.contains(".credentials.json") || lowercased.contains(".claude") {
                return "Claude Code (Legacy)"
            }
        case .copilot:
            if lowercased.contains("browser cookies") {
                return "Browser Cookies"
            }
            if lowercased.contains("github-copilot") {
                if lowercased.contains("hosts.json") {
                    return "VS Code (hosts.json)"
                }
                if lowercased.contains("apps.json") {
                    return "VS Code (apps.json)"
                }
                return "VS Code"
            }
        case .geminiCLI:
            if lowercased.contains("antigravity") {
                return "Antigravity"
            }
        default:
            break
        }

        if lowercased.contains("keychain") {
            return "Keychain"
        }

        return nil
    }

    /// Color for usage percentage: 70%+ → orange, 90%+ → red
    private func colorForUsagePercent(_ percent: Double) -> NSColor {
        if percent >= 90 {
            return .systemRed
        } else if percent >= 70 {
            return .systemOrange
        } else {
            return .secondaryLabelColor
        }
    }
    
    /// Creates NSMenuItem for quota providers with colored percentages.
    /// Color: 70%+ orange, 90%+ red, 100%+ red+bold
    private func createNativeQuotaMenuItem(name: String, usedPercents: [Double], icon: NSImage?) -> NSMenuItem {
        let attributed = NSMutableAttributedString()
        
        attributed.append(NSAttributedString(
            string: "\(name)",
            attributes: [.font: MenuDesignToken.Typography.defaultFont]
        ))

        let defaultFontUsagePercent: NSFont = MenuDesignToken.Typography.monospacedFont

        attributed.append(NSAttributedString(
            string: ": ",
            attributes: [
                .font: defaultFontUsagePercent,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        ))
        
        for (index, percent) in usedPercents.enumerated() {
            let percentText = String(format: "%.0f%%", percent)
            let percentColor = colorForUsagePercent(percent)
            let font: NSFont = percent >= 100 ? MenuDesignToken.Typography.monospacedBoldFont : defaultFontUsagePercent
            
            attributed.append(NSAttributedString(
                string: percentText,
                attributes: [
                    .font: font,
                    .foregroundColor: percentColor
                ]
            ))
            
            if index < usedPercents.count - 1 {
                attributed.append(NSAttributedString(
                    string: ", ",
                    attributes: [
                        .font: defaultFontUsagePercent,
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                ))
            }
        }
        
        // attributed.append(NSAttributedString(
        //     string: ")",
        //     attributes: [.font: MenuDesignToken.Typography.defaultFont]
        // ))
        
        let item = NSMenuItem()
        item.attributedTitle = attributed
        item.image = icon
        
        if let maxPercent = usedPercents.max(), maxPercent >= 70, let icon = icon {
            let iconColor: NSColor = maxPercent >= 90 ? .systemRed : .systemOrange
            item.image = tintedImage(icon, color: iconColor)
        }
        
        return item
    }
    
    private func createNativeQuotaMenuItem(name: String, usedPercent: Double, icon: NSImage?) -> NSMenuItem {
        return createNativeQuotaMenuItem(name: name, usedPercents: [usedPercent], icon: icon)
    }

    // MARK: - Error State Helpers

    /// Checks for keywords like "Authentication failed", "not found", "API key", etc.
    private func isAuthenticationError(_ errorMessage: String) -> Bool {
        let authPatterns = [
            "Authentication failed",
            "not found",
            "not available",
            "access token",
            "API key",
            "No Gemini accounts",
            "credentials"
        ]
        let lowercased = errorMessage.lowercased()
        return authPatterns.contains { lowercased.contains($0.lowercased()) }
    }

    private func createErrorMenuItem(identifier: ProviderIdentifier, errorMessage: String) -> NSMenuItem {
        let isAuthError = isAuthenticationError(errorMessage)
        let isSubscriptionError = errorMessage.lowercased().contains("subscription")
        let statusText = isSubscriptionError ? "No Subscription" : (isAuthError ? "No Credentials" : "Error")
        let title = "\(identifier.displayName) (\(statusText))"

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = tintedImage(iconForProvider(identifier), color: .systemOrange)
        item.isEnabled = false
        item.tag = 999
        item.toolTip = errorMessage

        return item
    }

    private func iconForProvider(_ identifier: ProviderIdentifier) -> NSImage? {
        var image: NSImage?

        switch identifier {
        case .copilot:
            image = NSImage(named: "CopilotIcon")
        case .claude:
            image = NSImage(named: "ClaudeIcon")
        case .codex:
            image = NSImage(named: "CodexIcon")
        case .geminiCLI:
            image = NSImage(named: "GeminiIcon")
        case .openCode:
            image = NSImage(named: "OpencodeIcon")
        case .openRouter:
            image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: identifier.displayName)
        case .antigravity:
            image = NSImage(systemSymbolName: identifier.iconName, accessibilityDescription: identifier.displayName)
        case .openCodeZen:
            image = NSImage(named: "OpencodeIcon")
        case .kimi:
            image = NSImage(systemSymbolName: identifier.iconName, accessibilityDescription: identifier.displayName)
        case .zaiCodingPlan:
            image = NSImage(named: "ZaiIcon")
        case .synthetic:
            image = NSImage(named: "SyntheticIcon")
        case .chutes:
            image = NSImage(named: "ChutesIcon")
        }

         // Resize icons to 16x16 for consistent menu appearance
         if let image = image {
             image.size = NSSize(width: 16, height: 16)
         }
         return image
     }

     private func tintedImage(_ image: NSImage?, color: NSColor) -> NSImage? {
         guard let image = image else { return nil }
         let tinted = image.copy() as! NSImage
         tinted.lockFocus()
         color.set()
         let rect = NSRect(origin: .zero, size: tinted.size)
         rect.fill(using: .sourceAtop)
         tinted.unlockFocus()
         return tinted
     }

    // MARK: - Subscription Actions

    @objc func subscriptionPlanSelected(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? SubscriptionMenuAction else { return }

        SubscriptionSettingsManager.shared.setPlan(action.plan, forKey: action.subscriptionKey)
        menu.cancelTracking()
        updateMultiProviderMenu()
    }

    @objc func customSubscriptionSelected(_ sender: NSMenuItem) {
        guard let subscriptionKey = sender.representedObject as? String else { return }

        var shouldPrompt = true
        while shouldPrompt {
            let alert = NSAlert()
            alert.messageText = "Custom Subscription Cost"
            alert.informativeText = "Enter the monthly subscription cost:"
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")

            let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            if case .custom(let currentCost) = SubscriptionSettingsManager.shared.getPlan(forKey: subscriptionKey) {
                inputField.stringValue = String(format: "%.0f", currentCost)
            } else {
                inputField.stringValue = ""
            }
            inputField.placeholderString = "Enter amount in USD"
            alert.accessoryView = inputField

            NSApp.activate(ignoringOtherApps: true)

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let cost = Double(inputField.stringValue), cost >= 0 {
                    SubscriptionSettingsManager.shared.setPlan(.custom(cost), forKey: subscriptionKey)
                    menu.cancelTracking()
                    updateMultiProviderMenu()
                    shouldPrompt = false
                } else {
                    let errorAlert = NSAlert()
                    errorAlert.messageText = "Invalid Amount"
                    errorAlert.informativeText = "Please enter a valid non-negative number."
                    errorAlert.addButton(withTitle: "OK")
                    errorAlert.runModal()
                }
            } else {
                shouldPrompt = false
            }
        }
    }

     // MARK: - Custom Menu Item Views

    func createHeaderView(title: String) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 23))

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        // Use secondaryLabelColor which adapts properly to dark/light mode in menu items
        label.textColor = NSColor.secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        return view
    }

    func createDisabledLabelView(
        text: String,
        icon: NSImage? = nil,
        font: NSFont? = nil,
        underline: Bool = false,
        monospaced: Bool = false,
        multiline: Bool = false,
        indent: CGFloat = 0
    ) -> NSView {
        var leadingOffset: CGFloat = MenuDesignToken.Spacing.leadingOffset + indent
        let menuWidth: CGFloat = MenuDesignToken.Dimension.menuWidth
        let labelFont = font ?? (monospaced ? NSFont.monospacedDigitSystemFont(ofSize: MenuDesignToken.Dimension.fontSize, weight: .regular) : NSFont.systemFont(ofSize: MenuDesignToken.Dimension.fontSize))

        if icon != nil {
            leadingOffset = MenuDesignToken.Spacing.leadingWithIcon
        }

        let availableWidth = menuWidth - leadingOffset - MenuDesignToken.Spacing.trailingMargin
        var viewHeight: CGFloat = MenuDesignToken.Dimension.itemHeight

        if multiline {
            let size = NSSize(width: availableWidth, height: .greatestFiniteMagnitude)
            let rect = (text as NSString).boundingRect(
                with: size,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: labelFont]
            )
            viewHeight = max(22, ceil(rect.height) + 8)
        }

        let view = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: viewHeight))

        if let icon = icon {
            let iconY = multiline ? viewHeight - 19 : 3
            let imageView = NSImageView(frame: NSRect(x: 14, y: iconY, width: 16, height: 16))
            imageView.image = icon
            imageView.imageScaling = .scaleProportionallyUpOrDown
            view.addSubview(imageView)
        }

        let label = NSTextField(labelWithString: "")

        var attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: labelFont
        ]

        if underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        label.attributedStringValue = NSAttributedString(string: text, attributes: attrs)
        label.translatesAutoresizingMaskIntoConstraints = false

        if multiline {
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            label.preferredMaxLayoutWidth = availableWidth
        }

        view.addSubview(label)

        if multiline {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: leadingOffset),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
                label.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
                label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4)
            ])
        } else {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: leadingOffset),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        }

        return view
    }

    private func evalJSONString(_ js: String, in webView: WKWebView) async throws -> String {
        let result = try await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .defaultClient)

        if let json = result as? String {
            return json
        } else if let dict = result as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: dict),
                  let json = String(data: data, encoding: .utf8) {
            return json
        } else {
            throw UsageFetcherError.invalidJSResult
        }
    }

      private func updateUIForSuccess(usage: CopilotUsage) {
          let totalCost = calculateTotalWithSubscriptions(providerResults: providerResults, copilotUsage: usage)
          statusBarIconView?.update(cost: totalCost)
          signInItem.isHidden = true
          updateHistorySubmenu()
          updateMultiProviderMenu()
      }

    private func updateUIForLoggedOut() {
        logger.info("updateUIForLoggedOut: showing default status")
        debugLog("updateUIForLoggedOut: reset status bar icon to default")
        statusBarIconView?.update(cost: 0)
        signInItem.isHidden = false
    }

    private func handleFetchError(_ error: Error) {
        statusBarIconView?.showError()
    }

    @objc private func signInClicked() {
        NotificationCenter.default.post(name: Notification.Name("sessionExpired"), object: nil)
    }

    @objc private func refreshClicked() {
        logger.info("⌨️ [Keyboard] ⌘R Refresh triggered")
        debugLog("⌨️ refreshClicked: ⌘R shortcut activated")
        fetchUsage()
    }

    @objc private func openBillingClicked() {
        if let url = URL(string: "https://github.com/settings/billing/premium_requests_usage") { NSWorkspace.shared.open(url) }
    }

    @objc private func openGitHub() {
        logger.info("Opening GitHub repository")
        if let url = URL(string: "https://github.com/opgginc/opencode-bar") {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc private func viewErrorDetailsClicked() {
        logger.info("⌨️ [Keyboard] ⌘E View Error Details triggered")
        debugLog("⌨️ viewErrorDetailsClicked: ⌘E shortcut activated")
        showErrorDetailsAlert()
    }

    @objc private func confirmResetOrphanedSubscriptions(_ sender: NSMenuItem) {
        guard !orphanedSubscriptionKeys.isEmpty else {
            debugLog("confirmResetOrphanedSubscriptions: no orphaned subscriptions to reset")
            return
        }

        let orphanedCount = orphanedSubscriptionKeys.count
        let formattedTotal = String(format: "%.2f", orphanedSubscriptionTotal)
        let sanitizedKeys = orphanedSubscriptionKeys.map { sanitizedSubscriptionKey($0) }.joined(separator: ", ")
        debugLog("confirmResetOrphanedSubscriptions: \(orphanedCount) key(s) pending, total=$\(formattedTotal), keys=[\(sanitizedKeys)]")

        let entryLabel = orphanedCount == 1 ? "entry" : "entries"
        let detailText = "This will delete \(orphanedCount) stored subscription \(entryLabel) that no longer match any detected account or provider. This can happen after refactors, account removal, or auth changes. Total to clear: $\(formattedTotal)."

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Reset orphaned subscriptions?"
        alert.informativeText = detailText
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            resetOrphanedSubscriptions()
        } else {
            debugLog("confirmResetOrphanedSubscriptions: reset cancelled")
        }
    }

    private func resetOrphanedSubscriptions() {
        let orphanedCount = orphanedSubscriptionKeys.count
        let formattedTotal = String(format: "%.2f", orphanedSubscriptionTotal)
        let sanitizedKeys = orphanedSubscriptionKeys.map { sanitizedSubscriptionKey($0) }.joined(separator: ", ")
        debugLog("resetOrphanedSubscriptions: resetting \(orphanedCount) key(s), total=$\(formattedTotal), keys=[\(sanitizedKeys)]")
        logger.info("Resetting orphaned subscription entries: count=\(orphanedCount), total=$\(formattedTotal)")

        SubscriptionSettingsManager.shared.removePlans(forKeys: orphanedSubscriptionKeys)
        orphanedSubscriptionKeys = []
        orphanedSubscriptionTotal = 0
        updateMultiProviderMenu()
    }
    
    private func showErrorDetailsAlert() {
        guard !lastProviderErrors.isEmpty else {
            debugLog("showErrorDetailsAlert: no errors to show")
            return
        }
        
        NSApp.activate(ignoringOtherApps: true)
        
        var errorLogText = "Provider Errors:\n"
        errorLogText += String(repeating: "─", count: 40) + "\n\n"
        
        for (identifier, errorMessage) in lastProviderErrors.sorted(by: { $0.key.displayName < $1.key.displayName }) {
            errorLogText += "[\(identifier.displayName)]\n"
            errorLogText += "  \(errorMessage)\n\n"
        }
        
        errorLogText += String(repeating: "─", count: 40) + "\n"
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        errorLogText += "Time: \(dateFormatter.string(from: Date()))\n"
        errorLogText += "App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")\n"
        errorLogText += "\n"
        errorLogText += TokenManager.shared.getDebugEnvironmentInfo()
        errorLogText += "\n"
        
        let alert = NSAlert()
        alert.messageText = "Provider Errors Detected"
        alert.informativeText = "Some providers failed to fetch data. You can copy the error log and report this issue on GitHub."
        alert.alertStyle = .warning
        
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 450, height: 200))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        
        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = errorLogText
        textView.autoresizingMask = [.width, .height]
        
        scrollView.documentView = textView
        alert.accessoryView = scrollView
        
        alert.addButton(withTitle: "Copy & Report on GitHub")
        alert.addButton(withTitle: "Copy Log Only")
        alert.addButton(withTitle: "Close")
        
        let response = alert.runModal()
        
        switch response {
        case .alertFirstButtonReturn:
            debugLog("showErrorDetailsAlert: user chose Copy & Report on GitHub")
            copyToClipboard(errorLogText)
            openGitHubNewIssue()
            
        case .alertSecondButtonReturn:
            debugLog("showErrorDetailsAlert: user chose Copy Log Only")
            copyToClipboard(errorLogText)
            showCopiedConfirmation()
            
        default:
            debugLog("showErrorDetailsAlert: user closed")
        }
    }
    
    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        logger.info("Error log copied to clipboard")
    }
    
    private func showCopiedConfirmation() {
        let confirmAlert = NSAlert()
        confirmAlert.messageText = "Copied!"
        confirmAlert.informativeText = "Error log has been copied to clipboard."
        confirmAlert.alertStyle = .informational
        confirmAlert.addButton(withTitle: "OK")
        confirmAlert.runModal()
    }
    
    private func openGitHubNewIssue() {
        let title = "Bug Report: Provider fetch errors"
        let body = """
        **Describe the issue:**
        [Please describe what you were doing when the error occurred]
        
        **Error Log:**
        ```
        [Paste the copied error log here, or remove this section if it contains sensitive information]
        ```
        
        **Environment:**
        - App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
        - macOS Version: \(ProcessInfo.processInfo.operatingSystemVersionString)
        """
        
        let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        
        if let url = URL(string: "https://github.com/opgginc/opencode-bar/issues/new?title=\(encodedTitle)&body=\(encodedBody)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Prompts user to star GitHub repo once on first launch.
    private func checkAndPromptGitHubStar() {
        let dismissedKey = "githubStarPromptDismissed"
        guard !UserDefaults.standard.bool(forKey: dismissedKey) else {
            debugLog("GitHub star prompt: skipped (already dismissed)")
            return
        }

        debugLog("GitHub star prompt: showing alert")
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Support OpenCode Bar?"
        alert.informativeText = "If you find this app useful, would you like to star it on GitHub? It helps others discover this project."
        alert.addButton(withTitle: "Open GitHub")
        alert.addButton(withTitle: "No Thanks")
        alert.alertStyle = .informational

        let response = alert.runModal()
        UserDefaults.standard.set(true, forKey: dismissedKey)

        if response == .alertFirstButtonReturn {
            debugLog("GitHub star prompt: opening GitHub page")
            if let url = URL(string: "https://github.com/opgginc/opencode-bar") {
                NSWorkspace.shared.open(url)
            }
        } else {
            debugLog("GitHub star prompt: user declined")
        }
    }

    @objc private func quitClicked() {
        logger.info("⌨️ [Keyboard] ⌘Q Quit triggered")
        debugLog("⌨️ quitClicked: ⌘Q shortcut activated")
        NSApp.terminate(nil)
    }

    @objc private func launchAtLoginClicked() {
        let service = SMAppService.mainApp
        try? (service.status == .enabled ? service.unregister() : service.register())
        updateLaunchAtLoginState()
    }

    private func updateLaunchAtLoginState() {
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func installCLIClicked() {
        logger.info("⌨️ [Keyboard] Install CLI triggered")
        debugLog("⌨️ installCLIClicked: Install CLI menu item activated")
        
        // Resolve CLI binary path via bundle URL (Contents/MacOS/opencodebar-cli)
        let cliURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/opencodebar-cli")
        let cliPath = cliURL.path
        
        guard FileManager.default.fileExists(atPath: cliPath) else {
            logger.error("CLI binary not found in app bundle at \(cliPath)")
            debugLog("❌ CLI binary not found at expected path in app bundle")
            showAlert(title: "CLI Not Found", message: "CLI binary not found in app bundle. Please reinstall the app.")
            return
        }
        
        debugLog("✅ CLI binary found at: \(cliPath)")
        
        // Escape cliPath for safe inclusion in AppleScript string literal
        let escapedCliPath = cliPath.replacingOccurrences(of: "\"", with: "\\\"")
        
        // Use AppleScript's 'quoted form of' to safely escape the path for the shell command and prevent command injection
        let script = """
        set cliPath to "\(escapedCliPath)"
        do shell script "mkdir -p /usr/local/bin && cp " & quoted form of cliPath & " /usr/local/bin/opencodebar && chmod +x /usr/local/bin/opencodebar" with administrator privileges
        """
        
        debugLog("🔐 Executing AppleScript for privileged installation")
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            
            if let error = error {
                logger.error("CLI installation failed: \(error.description)")
                debugLog("❌ Installation failed: \(error.description)")
                showAlert(title: "Installation Failed", message: "Failed to install CLI: \(error.description)")
            } else {
                logger.info("CLI installed successfully to /usr/local/bin/opencodebar")
                debugLog("✅ CLI installed successfully")
                showAlert(title: "Success", message: "CLI installed to /usr/local/bin/opencodebar\n\nYou can now use 'opencodebar' command in Terminal.")
                updateCLIInstallState()
            }
        } else {
            logger.error("Failed to create AppleScript object")
            debugLog("❌ Failed to create AppleScript object")
            showAlert(title: "Installation Failed", message: "Failed to create installation script.")
        }
    }

    private func updateCLIInstallState() {
        let installed = FileManager.default.fileExists(atPath: "/usr/local/bin/opencodebar")
        
        if installed {
            installCLIItem.title = "CLI Installed (opencodebar)"
            installCLIItem.state = .on
            installCLIItem.isEnabled = false
            debugLog("✅ CLI is installed at /usr/local/bin/opencodebar")
        } else {
            installCLIItem.title = "Install CLI (opencodebar)"
            installCLIItem.state = .off
            installCLIItem.isEnabled = true
            debugLog("ℹ️ CLI is not installed")
        }
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .informational
        
        alert.runModal()
    }

    private func saveCache(usage: CopilotUsage) {
        if let data = try? JSONEncoder().encode(CachedUsage(usage: usage, timestamp: Date())) {
            UserDefaults.standard.set(data, forKey: "copilot.usage.cache")
        }
    }

    private func clearCaches() {
        UserDefaults.standard.removeObject(forKey: "copilot.history.cache")
    }

    private func saveHistoryCache(_ history: UsageHistory) {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: "copilot.history.cache")
        }
    }

    private func loadHistoryCache() -> UsageHistory? {
        guard let data = UserDefaults.standard.data(forKey: "copilot.history.cache") else { return nil }
        return try? JSONDecoder().decode(UsageHistory.self, from: data)
    }

    private func hasMonthChanged(_ date: Date) -> Bool {
        let calendar = Calendar.current
        return calendar.component(.month, from: date) != calendar.component(.month, from: Date())
            || calendar.component(.year, from: date) != calendar.component(.year, from: Date())
    }

    private func loadCachedHistoryOnStartup() {
        guard let cached = loadHistoryCache() else {
            logger.info("No cache - skipping history load")
            return
        }

        if hasMonthChanged(cached.fetchedAt) {
            logger.info("Month change detected - deleting cache")
            UserDefaults.standard.removeObject(forKey: "copilot.history.cache")
            return
        }

        self.usageHistory = cached
        self.lastHistoryFetchResult = .failedWithCache
        updateHistorySubmenu()
    }

    func getHistoryUIState() -> HistoryUIState {
        guard let history = usageHistory else {
            return HistoryUIState(history: nil, prediction: nil, isStale: false, hasNoData: true)
        }

        let stale = isHistoryStale(history)

        return HistoryUIState(
            history: history,
            prediction: nil,
            isStale: stale && lastHistoryFetchResult == .failedWithCache,
            hasNoData: false
        )
    }

    private func isHistoryStale(_ history: UsageHistory) -> Bool {
        let staleThreshold: TimeInterval = 30 * 60
        return Date().timeIntervalSince(history.fetchedAt) > staleThreshold
    }

    // MARK: - Predicted EOM Section (Aggregated Pay-as-you-go)

    private func insertPredictedEOMSection(at index: Int) -> Int {
        var insertIndex = index

        // Collect daily cost data from all Pay-as-you-go providers
        var aggregatedDailyCosts: [Date: [ProviderIdentifier: Double]] = [:]

        // 1. Copilot Add-on history
        if let history = usageHistory {
            for day in history.days {
                let dateKey = Calendar.current.startOfDay(for: day.date)
                if aggregatedDailyCosts[dateKey] == nil {
                    aggregatedDailyCosts[dateKey] = [:]
                }
                aggregatedDailyCosts[dateKey]?[.copilot] = day.billedAmount
            }
        }

        // 2. OpenCode Zen history
        if let zenResult = providerResults[.openCodeZen],
           let details = zenResult.details,
           let zenHistory = details.dailyHistory {
            for day in zenHistory {
                let dateKey = Calendar.current.startOfDay(for: day.date)
                if aggregatedDailyCosts[dateKey] == nil {
                    aggregatedDailyCosts[dateKey] = [:]
                }
                aggregatedDailyCosts[dateKey]?[.openCodeZen] = day.billedAmount
            }
        }

        // 3. OpenRouter - only has current cost, no daily history
        // We'll include today's cost if available
        if let routerResult = providerResults[.openRouter],
           case .payAsYouGo(_, let cost, _) = routerResult.usage,
           let dailyCost = routerResult.details?.dailyUsage {
            let today = Calendar.current.startOfDay(for: Date())
            if aggregatedDailyCosts[today] == nil {
                aggregatedDailyCosts[today] = [:]
            }
            aggregatedDailyCosts[today]?[.openRouter] = dailyCost
        }

        // If no data, skip this section
        guard !aggregatedDailyCosts.isEmpty else {
            return insertIndex
        }

        // Calculate predicted EOM
        let calendar = Calendar.current
        let today = Date()
        let currentDay = calendar.component(.day, from: today)
        let daysInMonth = calendar.range(of: .day, in: .month, for: today)?.count ?? 30
        let remainingDays = daysInMonth - currentDay

        // Get daily totals for prediction period
        let sortedDates = aggregatedDailyCosts.keys.sorted(by: >)
        let recentDays = Array(sortedDates.prefix(predictionPeriod.rawValue))

        var totalCostSoFar = 0.0
        var dailyTotals: [(date: Date, total: Double, breakdown: [ProviderIdentifier: Double])] = []

        for date in recentDays {
            if let providers = aggregatedDailyCosts[date] {
                let dayTotal = providers.values.reduce(0, +)
                totalCostSoFar += dayTotal
                dailyTotals.append((date: date, total: dayTotal, breakdown: providers))
            }
        }

        // Calculate weighted average daily cost
        let weights = predictionPeriod.weights
        var weightedSum = 0.0
        var weightTotal = 0.0

        for (index, dayData) in dailyTotals.enumerated() {
            let weight = index < weights.count ? weights[index] : 1.0
            weightedSum += dayData.total * weight
            weightTotal += weight
        }

        let avgDailyCost = weightTotal > 0 ? weightedSum / weightTotal : 0.0

        // Calculate current month total (sum all days in current month)
        let currentMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
        var currentMonthTotal = 0.0
        for (date, providers) in aggregatedDailyCosts {
            if date >= currentMonthStart {
                currentMonthTotal += providers.values.reduce(0, +)
            }
        }

        let predictedEOM = currentMonthTotal + (avgDailyCost * Double(remainingDays))

        // Create Predicted EOM menu item
        let eomItem = NSMenuItem(
            title: String(format: "Predicted EOM: $%.0f", predictedEOM),
            action: nil,
            keyEquivalent: ""
        )
        eomItem.image = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: "Predicted EOM")
        eomItem.tag = 999

        // Create submenu with daily breakdown
        let submenu = NSMenu()

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d (EEE)"

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let todayStart = utcCalendar.startOfDay(for: today)

        // Sort dailyTotals by date descending
        let sortedDailyTotals = dailyTotals.sorted { $0.date > $1.date }

        for dayData in sortedDailyTotals.prefix(predictionPeriod.rawValue) {
            let dayStart = utcCalendar.startOfDay(for: dayData.date)
            let isToday = dayStart == todayStart
            let dateStr = dateFormatter.string(from: dayData.date)

            let costStr: String
            if dayData.total < 0.01 {
                costStr = "Zero"
            } else {
                costStr = String(format: "$%.2f", dayData.total)
            }

            let label = isToday ? "\(dateStr): \(costStr) (Today)" : "\(dateStr): \(costStr)"

            // Create day item with provider breakdown submenu
            let dayItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            dayItem.tag = 999

            // Only add submenu if there's more than one provider or any cost
            if !dayData.breakdown.isEmpty {
                let breakdownSubmenu = NSMenu()

                // Sort by provider display order
                let providerOrder: [ProviderIdentifier] = [.openCodeZen, .openRouter, .copilot]
                for provider in providerOrder {
                    if let cost = dayData.breakdown[provider] {
                        let providerLabel: String
                        if cost < 0.01 {
                            providerLabel = "\(provider.displayName): Zero"
                        } else {
                            providerLabel = String(format: "%@: $%.2f", provider.displayName, cost)
                        }
                        let providerItem = NSMenuItem()
                        providerItem.view = createDisabledLabelView(
                            text: providerLabel,
                            icon: iconForProvider(provider)
                        )
                        breakdownSubmenu.addItem(providerItem)
                    }
                }

                dayItem.submenu = breakdownSubmenu
            }

            submenu.addItem(dayItem)
        }

        // Add separator before settings
        submenu.addItem(NSMenuItem.separator())

        // Prediction Period submenu
        let periodItem = NSMenuItem(title: "Prediction Period", action: nil, keyEquivalent: "")
        periodItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Prediction Period")

        // Create a fresh submenu for prediction period to avoid deadlock
        let periodSubmenu = NSMenu()
        for period in PredictionPeriod.allCases {
            let item = NSMenuItem(title: period.title, action: #selector(predictionPeriodSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = period.rawValue
            item.state = (period.rawValue == predictionPeriod.rawValue) ? .on : .off
            periodSubmenu.addItem(item)
        }
        periodItem.submenu = periodSubmenu
        submenu.addItem(periodItem)

        submenu.addItem(NSMenuItem.separator())
        let authItem = NSMenuItem()
        authItem.view = createDisabledLabelView(
            text: "Token From: ~/.local/share/opencode/auth.json",
            icon: NSImage(systemSymbolName: "key", accessibilityDescription: "Auth Source"),
            multiline: true
        )
        submenu.addItem(authItem)

        eomItem.submenu = submenu
        menu.insertItem(eomItem, at: insertIndex)
        insertIndex += 1

        return insertIndex
    }

    private func updateHistorySubmenu() {
        debugLog("updateHistorySubmenu: started")
        let state = getHistoryUIState()
        debugLog("updateHistorySubmenu: getHistoryUIState completed")
        historySubmenu.removeAllItems()
        debugLog("updateHistorySubmenu: removeAllItems completed")

        if state.hasNoData {
            debugLog("updateHistorySubmenu: hasNoData=true, returning early")
            let item = NSMenuItem()
            item.view = createDisabledLabelView(
                text: "No data",
                icon: NSImage(systemSymbolName: "tray", accessibilityDescription: "No data")
            )
            historySubmenu.addItem(item)
            return
        }
        debugLog("updateHistorySubmenu: hasNoData=false, continuing")

        if let prediction = state.prediction {
            debugLog("updateHistorySubmenu: prediction exists, processing")
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0

            debugLog("updateHistorySubmenu: creating monthlyText")
            let monthlyText = "Predicted EOM: \(formatter.string(from: NSNumber(value: prediction.predictedMonthlyRequests)) ?? "0") requests"
            debugLog("updateHistorySubmenu: creating monthlyItem")
            let monthlyItem = NSMenuItem()
            monthlyItem.view = createDisabledLabelView(
                text: monthlyText,
                icon: NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: "Predicted EOM"),
                font: NSFont.boldSystemFont(ofSize: 13)
            )
            debugLog("updateHistorySubmenu: adding monthlyItem to submenu")
            historySubmenu.addItem(monthlyItem)
            debugLog("updateHistorySubmenu: monthlyItem added")

            if prediction.predictedBilledAmount > 0 {
                let costText = String(format: "Predicted Add-on: $%.2f", prediction.predictedBilledAmount)
                let costItem = NSMenuItem()
                costItem.view = createDisabledLabelView(
                    text: costText,
                    icon: NSImage(systemSymbolName: "dollarsign.circle", accessibilityDescription: "Predicted Add-on"),
                    font: NSFont.boldSystemFont(ofSize: 13),
                    underline: true
                )
                historySubmenu.addItem(costItem)
            }

            if prediction.confidenceLevel == .low {
                let confItem = NSMenuItem()
                confItem.view = createDisabledLabelView(
                    text: "Low prediction accuracy",
                    icon: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Low accuracy")
                )
                historySubmenu.addItem(confItem)
            } else if prediction.confidenceLevel == .medium {
                let confItem = NSMenuItem()
                confItem.view = createDisabledLabelView(
                    text: "Medium prediction accuracy",
                    icon: NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Medium accuracy")
                )
                historySubmenu.addItem(confItem)
            }

            debugLog("updateHistorySubmenu: adding separator after prediction")
            historySubmenu.addItem(NSMenuItem.separator())
            debugLog("updateHistorySubmenu: separator added")
        } else {
            debugLog("updateHistorySubmenu: no prediction data")
        }

        if state.isStale {
            debugLog("updateHistorySubmenu: data is stale, adding stale item")
            let staleItem = NSMenuItem()
            staleItem.view = createDisabledLabelView(
                text: "Data is stale",
                icon: NSImage(systemSymbolName: "clock.badge.exclamationmark", accessibilityDescription: "Data is stale")
            )
            historySubmenu.addItem(staleItem)
            debugLog("updateHistorySubmenu: stale item added")
        }

        if let history = state.history {
            debugLog("updateHistorySubmenu: history exists, processing \(history.recentDays.count) days")
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMM d"
            dateFormatter.timeZone = TimeZone(identifier: "UTC")

            var utcCalendar = Calendar(identifier: .gregorian)
            if let utc = TimeZone(identifier: "UTC") {
                utcCalendar.timeZone = utc
            }
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

                let item = NSMenuItem()
                item.view = createDisabledLabelView(text: label, monospaced: true)
                historySubmenu.addItem(item)
            }
            debugLog("updateHistorySubmenu: all history items added")
        } else {
            debugLog("updateHistorySubmenu: no history data")
        }

        debugLog("updateHistorySubmenu: adding final separator and prediction period menu")
        historySubmenu.addItem(NSMenuItem.separator())
        let predictionPeriodItem = NSMenuItem(title: "Prediction Period", action: nil, keyEquivalent: "")
        predictionPeriodItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Prediction Period")
        
        // Create a fresh submenu to avoid NSMenu parent conflict
        let freshPeriodSubmenu = NSMenu()
        for period in PredictionPeriod.allCases {
            let item = NSMenuItem(title: period.title, action: #selector(predictionPeriodSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = period.rawValue
            item.state = (period.rawValue == predictionPeriod.rawValue) ? .on : .off
            freshPeriodSubmenu.addItem(item)
        }
        predictionPeriodItem.submenu = freshPeriodSubmenu
        historySubmenu.addItem(predictionPeriodItem)
        debugLog("updateHistorySubmenu: completed successfully")
    }
}
