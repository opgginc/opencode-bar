import AppKit
import SwiftUI
import ServiceManagement
import WebKit
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "StatusBarController")

@MainActor
final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var statusBarIconView: StatusBarIconView!
    private var menu: NSMenu!
    private var signInItem: NSMenuItem!
    private var resetLoginItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var refreshIntervalMenu: NSMenu!
    private var refreshTimer: Timer?
    
    private var currentUsage: CopilotUsage?
    private var lastFetchTime: Date?
    private var isFetching = false
    
    // History fetch properties
    private var historyFetchTimer: Timer?
    private var usageHistory: UsageHistory?
    private var lastHistoryFetchResult: HistoryFetchResult = .none
    private var customerId: String?
    
    // History UI properties
    private var historySubmenu: NSMenu!
    private var historyMenuItem: NSMenuItem!
    var predictionPeriodMenu: NSMenu!
    
     // Multi-provider properties
     private var providerResults: [ProviderIdentifier: ProviderResult] = [:]
     private var loadingProviders: Set<ProviderIdentifier> = []
     private var enabledProvidersMenu: NSMenu!
    
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
        }
    }
    
    override init() {
        super.init()
        debugLog("StatusBarController init started")
        setupStatusItem()
        debugLog("setupStatusItem completed")
        setupMenu()
        debugLog("setupMenu completed")
        setupNotificationObservers()
        debugLog("setupNotificationObservers completed")
        startRefreshTimer()
        debugLog("startRefreshTimer completed")
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
        statusBarIconView.showLoading()
        statusItem.button?.addSubview(statusBarIconView)
        statusItem.button?.frame = statusBarIconView.frame
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
        
        signInItem = NSMenuItem(title: "Sign In", action: #selector(signInClicked), keyEquivalent: "")
        signInItem.image = NSImage(systemSymbolName: "person.crop.circle.badge.checkmark", accessibilityDescription: "Sign In")
        signInItem.target = self
        signInItem.isHidden = true
        menu.addItem(signInItem)

        resetLoginItem = NSMenuItem(title: "Reset Login", action: #selector(resetLoginClicked), keyEquivalent: "")
        resetLoginItem.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset Login")
        resetLoginItem.target = self
        resetLoginItem.isHidden = true
        menu.addItem(resetLoginItem)
        
        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(launchAtLoginClicked), keyEquivalent: "")
        launchAtLoginItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Launch at Login")
        launchAtLoginItem.target = self
        updateLaunchAtLoginState()
        menu.addItem(launchAtLoginItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let versionItem = NSMenuItem(title: "Version \(version)", action: nil, keyEquivalent: "")
        versionItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Version")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Quit")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
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
        NotificationCenter.default.addObserver(forName: Notification.Name("billingPageLoaded"), object: nil, queue: .main) { [weak self] _ in
            logger.info("Notification received: billingPageLoaded")
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                self?.fetchUsage()
                self?.startHistoryFetchTimer()
            }
        }
        NotificationCenter.default.addObserver(forName: Notification.Name("sessionExpired"), object: nil, queue: .main) { [weak self] _ in
            logger.info("Notification received: sessionExpired")
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                self?.updateUIForLoggedOut()
                self?.historyFetchTimer?.invalidate()
                self?.historyFetchTimer = nil
            }
        }
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
        AuthManager.shared.loadBillingPage()
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
        statusBarIconView.showLoading()
        
        debugLog("fetchUsage: creating Task")
        Task { @MainActor in
            debugLog("fetchUsage Task: calling performFetchUsage")
            await performFetchUsage()
            debugLog("fetchUsage Task: performFetchUsage completed")
            debugLog("fetchUsage Task: calling fetchMultiProviderData")
            await fetchMultiProviderData()
            debugLog("fetchUsage Task: fetchMultiProviderData completed")
            debugLog("fetchUsage Task: all done, setting isFetching=false")
            self.isFetching = false
        }
        debugLog("fetchUsage: Task created")
    }
    
    // MARK: - Fetch Usage Helpers (Split for Swift compiler type-check performance on older Xcode)
    
    private func performFetchUsage() async {
        debugLog("performFetchUsage: started")
        let webView = AuthManager.shared.webView
        debugLog("performFetchUsage: got webView")
        let customerId = await fetchCustomerId(webView: webView)
        debugLog("performFetchUsage: fetchCustomerId returned \(customerId ?? "nil")")
        
        if let validId = customerId {
            self.customerId = validId
            debugLog("performFetchUsage: calling fetchAndProcessUsageData")
            let success = await fetchAndProcessUsageData(webView: webView, customerId: validId)
            debugLog("performFetchUsage: fetchAndProcessUsageData returned \(success)")
            if success {
                debugLog("performFetchUsage: success, returning (isFetching will be reset by Task)")
                return
            }
        }
        
        debugLog("performFetchUsage: calling handleFetchFallback")
        handleFetchFallback()
        debugLog("performFetchUsage: completed")
    }
    

    
    private func fetchCustomerId(webView: WKWebView) async -> String? {
        if let apiId = await fetchCustomerIdFromAPI(webView: webView) {
            return apiId
        }
        if let domId = await fetchCustomerIdFromDOM(webView: webView) {
            return domId
        }
        if let htmlId = await fetchCustomerIdFromHTML(webView: webView) {
            return htmlId
        }
        return nil
    }
    
    private func fetchCustomerIdFromAPI(webView: WKWebView) async -> String? {
        logger.info("fetchUsage: [Step 1] Attempting to obtain ID via API(/api/v3/user)")
        
        let userApiJS = """
        return await (async function() {
            try {
                const response = await fetch('/api/v3/user', {
                    headers: { 'Accept': 'application/json' }
                });
                if (!response.ok) return JSON.stringify({ error: 'HTTP ' + response.status });
                const data = await response.json();
                return JSON.stringify(data);
            } catch (e) {
                return JSON.stringify({ error: e.toString() });
            }
        })()
        """
        
        do {
            let result = try await webView.callAsyncJavaScript(userApiJS, arguments: [:], in: nil, contentWorld: .defaultClient)
            
            if let jsonString = result as? String,
               let data = jsonString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = json["id"] as? Int {
                logger.info("fetchUsage: API ID obtained successfully - \(id)")
                return String(id)
            }
        } catch {
            logger.error("fetchUsage: Error during API call - \(error.localizedDescription)")
        }
        
        return nil
    }
    
    private func fetchCustomerIdFromDOM(webView: WKWebView) async -> String? {
        logger.info("fetchUsage: [Step 2] Attempting DOM extraction")
        
        let extractionJS = """
        return (function() {
            const el = document.querySelector('script[data-target="react-app.embeddedData"]');
            if (el) {
                try {
                    const data = JSON.parse(el.textContent);
                    if (data && data.payload && data.payload.customer && data.payload.customer.customerId) {
                        return data.payload.customer.customerId.toString();
                    }
                } catch(e) {}
            }
            return null;
        })()
        """
        
        if let extracted = try? await evalJSONString(extractionJS, in: webView) {
            logger.info("fetchUsage: customerId extracted from DOM successfully - \(extracted)")
            return extracted
        }
        
        return nil
    }
    
    private func fetchCustomerIdFromHTML(webView: WKWebView) async -> String? {
        logger.info("fetchUsage: [Step 3] Attempting HTML Regex")
        
        let htmlJS = "return document.documentElement.outerHTML"
        guard let html = try? await webView.callAsyncJavaScript(htmlJS, arguments: [:], in: nil, contentWorld: .defaultClient) as? String else {
            return nil
        }
        
        let patterns = [
            #"customerId":(\d+)"#,
            #"customerId&quot;:(\d+)"#,
            #"customer_id=(\d+)"#,
            #"data-customer-id="(\d+)""#
        ]
        
        for pattern in patterns {
            if let customerId = extractCustomerIdWithPattern(pattern, from: html) {
                logger.info("fetchUsage: ID found in HTML - \(customerId)")
                return customerId
            }
        }
        
        return nil
    }
    
    private func extractCustomerIdWithPattern(_ pattern: String, from html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[range])
    }
    
    private func fetchAndProcessUsageData(webView: WKWebView, customerId: String) async -> Bool {
        debugLog("fetchAndProcessUsageData: started")
        let cardJS = """
        return await (async function() {
            try {
                const res = await fetch('/settings/billing/copilot_usage_card?customer_id=\(customerId)&period=3', {
                    headers: { 'Accept': 'application/json', 'x-requested-with': 'XMLHttpRequest' }
                });
                const text = await res.text();
                try {
                    const json = JSON.parse(text);
                    json._debug_timestamp = new Date().toISOString();
                    return json;
                } catch (e) {
                    return { error: 'JSON Parse Error', body: text };
                }
            } catch(e) { return { error: e.toString() }; }
        })()
        """
        
        do {
            debugLog("fetchAndProcessUsageData: calling JS")
            let result = try await webView.callAsyncJavaScript(cardJS, arguments: [:], in: nil, contentWorld: .defaultClient)
            debugLog("fetchAndProcessUsageData: JS completed")
            
            guard let rootDict = result as? [String: Any] else {
                debugLog("fetchAndProcessUsageData: rootDict cast failed")
                return false
            }
            
            debugLog("fetchAndProcessUsageData: parsing usage")
            if let usage = parseUsageFromResponse(rootDict) {
                currentUsage = usage
                lastFetchTime = Date()
                debugLog("fetchAndProcessUsageData: calling updateUIForSuccess")
                updateUIForSuccess(usage: usage)
                debugLog("fetchAndProcessUsageData: updateUIForSuccess completed")
                debugLog("fetchAndProcessUsageData: calling saveCache")
                saveCache(usage: usage)
                debugLog("fetchAndProcessUsageData: saveCache completed")
                logger.info("fetchUsage: Success")
                debugLog("fetchAndProcessUsageData: returning true")
                return true
            }
            debugLog("fetchAndProcessUsageData: parseUsageFromResponse returned nil")
        } catch {
            debugLog("fetchAndProcessUsageData: JS error - \(error.localizedDescription)")
            logger.error("fetchUsage: Error during JS execution - \(error.localizedDescription)")
        }
        
        debugLog("fetchAndProcessUsageData: returning false")
        return false
    }
    
    private func parseUsageFromResponse(_ rootDict: [String: Any]) -> CopilotUsage? {
        var dict = rootDict
        if let payload = rootDict["payload"] as? [String: Any] {
            dict = payload
        } else if let data = rootDict["data"] as? [String: Any] {
            dict = data
        }
        
        logger.info("fetchUsage: Attempting data parsing (Keys: \(dict.keys.joined(separator: ", ")))")
        
        let netBilledAmount = parseDoubleValue(from: dict, keys: ["netBilledAmount", "net_billed_amount"])
        let netQuantity = parseDoubleValue(from: dict, keys: ["netQuantity", "net_quantity"])
        let discountQuantity = parseDoubleValue(from: dict, keys: ["discountQuantity", "discount_quantity"])
        let limit = parseIntValue(from: dict, keys: ["userPremiumRequestEntitlement", "user_premium_request_entitlement", "quantity"])
        let filteredLimit = parseIntValue(from: dict, keys: ["filteredUserPremiumRequestEntitlement"])
        
        return CopilotUsage(
            netBilledAmount: netBilledAmount,
            netQuantity: netQuantity,
            discountQuantity: discountQuantity,
            userPremiumRequestEntitlement: limit,
            filteredUserPremiumRequestEntitlement: filteredLimit
        )
    }
    
    private func parseDoubleValue(from dict: [String: Any], keys: [String]) -> Double {
        for key in keys {
            if let value = dict[key] as? Double {
                return value
            }
            if let value = dict[key] as? Int {
                return Double(value)
            }
            if let value = dict[key] as? NSNumber {
                return value.doubleValue
            }
        }
        return 0.0
    }
    
    private func parseIntValue(from dict: [String: Any], keys: [String]) -> Int {
        for key in keys {
            if let value = dict[key] as? Int {
                return value
            }
            if let value = dict[key] as? Double {
                return Int(value)
            }
        }
        return 0
    }
    
    private func handleFetchFallback() {
        if let cached = loadCache() {
            updateUIForSuccess(usage: cached.usage)
            isFetching = false
        } else {
            handleFetchError(UsageFetcherError.noUsageData)
            isFetching = false
        }
    }
    
    // MARK: - Multi-Provider Fetch
    
      private func fetchMultiProviderData() async {
          debugLog("fetchMultiProviderData: started")
          let enabledProviders = ProviderManager.shared.getAllProviders().filter { provider in
              isProviderEnabled(provider.identifier) && provider.identifier != .copilot
          }
          debugLog("fetchMultiProviderData: enabledProviders count=\(enabledProviders.count)")
          
          guard !enabledProviders.isEmpty else {
              logger.info("fetchMultiProviderData: No enabled providers, skipping")
              debugLog("fetchMultiProviderData: No enabled providers, returning")
              return
          }
          
          loadingProviders = Set(enabledProviders.map { $0.identifier })
          debugLog("fetchMultiProviderData: marked \(loadingProviders.count) providers as loading")
          updateMultiProviderMenu()
          
          logger.info("fetchMultiProviderData: Fetching \(enabledProviders.count) providers")
          debugLog("fetchMultiProviderData: calling ProviderManager.fetchAll()")
          let results = await ProviderManager.shared.fetchAll()
          debugLog("fetchMultiProviderData: fetchAll returned \(results.count) results")
          
          let filteredResults = results.filter { (identifier, _) in
              isProviderEnabled(identifier) && identifier != .copilot
          }
          debugLog("fetchMultiProviderData: filteredResults count=\(filteredResults.count)")
          
          for identifier in filteredResults.keys {
              loadingProviders.remove(identifier)
          }
          debugLog("fetchMultiProviderData: cleared loading state for \(filteredResults.count) providers")
          
          self.providerResults = filteredResults
          debugLog("fetchMultiProviderData: calling updateMultiProviderMenu")
          self.updateMultiProviderMenu()
          debugLog("fetchMultiProviderData: updateMultiProviderMenu completed")
          
          logger.info("fetchMultiProviderData: Completed with \(filteredResults.count) results")
          debugLog("fetchMultiProviderData: completed")
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
         
          let hasCopilotData = currentUsage != nil
          debugLog("updateMultiProviderMenu: hasCopilotData=\(hasCopilotData), providerResults.count=\(providerResults.count)")
          
          if !providerResults.isEmpty {
              let providerNames = providerResults.keys.map { $0.rawValue }.joined(separator: ", ")
              debugLog("updateMultiProviderMenu: providers=[\(providerNames)]")
          }
          
          guard !providerResults.isEmpty || hasCopilotData else {
              debugLog("updateMultiProviderMenu: no data, returning")
              return
          }
        
        var insertIndex = separatorIndex + 1
        
         let separator1 = NSMenuItem.separator()
         separator1.tag = 999
         menu.insertItem(separator1, at: insertIndex)
         insertIndex += 1
         
          let total = calculatePayAsYouGoTotal(providerResults: providerResults, copilotUsage: currentUsage)
          let payAsYouGoHeader = NSMenuItem()
          payAsYouGoHeader.view = createHeaderView(title: String(format: "Pay-as-you-go    $%.2f", total))
          payAsYouGoHeader.tag = 999
          menu.insertItem(payAsYouGoHeader, at: insertIndex)
          insertIndex += 1
         
         var hasPayAsYouGo = false
         
           // Copilot Add-on (always show, even when $0.00)
            if let copilotUsage = currentUsage {
                hasPayAsYouGo = true
               let addOnItem = NSMenuItem(
                   title: String(format: "Copilot Add-on    $%.2f", copilotUsage.netBilledAmount),
                   action: nil,
                   keyEquivalent: ""
               )
               addOnItem.image = iconForProvider(.copilot)
               addOnItem.tag = 999
               
               let submenu = NSMenu()
               let overageItem = NSMenuItem()
               overageItem.view = createDisabledLabelView(text: String(format: "Overage Requests: %.0f", copilotUsage.netQuantity))
               submenu.addItem(overageItem)
               
                 submenu.addItem(NSMenuItem.separator())
                 let historyItem = NSMenuItem(title: "Usage History", action: nil, keyEquivalent: "")
                 historyItem.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Usage History")
                 debugLog("updateMultiProviderMenu: calling createCopilotHistorySubmenu")
                 historyItem.submenu = createCopilotHistorySubmenu()
                 debugLog("updateMultiProviderMenu: createCopilotHistorySubmenu completed")
                  submenu.addItem(historyItem)
                 
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
                  
                  submenu.addItem(NSMenuItem.separator())
                  
                  let openBillingItem = NSMenuItem(title: "Open Billing", action: #selector(openBillingClicked), keyEquivalent: "b")
                  openBillingItem.image = NSImage(systemSymbolName: "creditcard", accessibilityDescription: "Open Billing")
                  openBillingItem.target = self
                  submenu.addItem(openBillingItem)
                  
                  addOnItem.submenu = submenu
                
                menu.insertItem(addOnItem, at: insertIndex)
                insertIndex += 1
           }
         
            let payAsYouGoOrder: [ProviderIdentifier] = [.openRouter, .openCodeZen]
            for identifier in payAsYouGoOrder {
                guard isProviderEnabled(identifier) else { continue }
                
                if let result = providerResults[identifier] {
                    if case .payAsYouGo(_, let cost, _) = result.usage {
                        hasPayAsYouGo = true
                        let costValue = cost ?? 0.0
                        let item = NSMenuItem(
                            title: String(format: "%@    $%.2f", identifier.displayName, costValue),
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
                } else if loadingProviders.contains(identifier) {
                    hasPayAsYouGo = true
                    let item = NSMenuItem()
                    item.view = createDisabledLabelView(
                        text: "\(identifier.displayName)    Loading...",
                        icon: iconForProvider(identifier)
                    )
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
         quotaHeader.view = createHeaderView(title: "Quota Status")
         quotaHeader.tag = 999
         menu.insertItem(quotaHeader, at: insertIndex)
         insertIndex += 1
         
         var hasQuota = false
         
          // Copilot Quota (always show if currentUsage exists)
          if let copilotUsage = currentUsage {
              hasQuota = true
              let limit = copilotUsage.userPremiumRequestEntitlement
              let used = copilotUsage.usedRequests
              let remaining = limit - used
              let percentage = limit > 0 ? (Double(remaining) / Double(limit)) * 100 : 0
              
              let quotaItem = NSMenuItem(
                  title: String(format: "Copilot    %.0f%% remaining", percentage),
                  action: nil,
                  keyEquivalent: ""
              )
              quotaItem.image = iconForProvider(.copilot)
              if percentage < 20 {
                  quotaItem.image = tintedImage(iconForProvider(.copilot), color: .systemRed)
              }
              quotaItem.tag = 999
              
              let submenu = NSMenu()
              
              let filledBlocks = Int((Double(used) / Double(max(limit, 1))) * 10)
              let emptyBlocks = 10 - filledBlocks
              let progressBar = String(repeating: "═", count: filledBlocks) + String(repeating: "░", count: emptyBlocks)
              let progressItem = NSMenuItem()
              progressItem.view = createDisabledLabelView(text: "[\(progressBar)] \(used)/\(limit)")
              submenu.addItem(progressItem)
              
              let usedItem = NSMenuItem()
              usedItem.view = createDisabledLabelView(text: "This Month: \(used) used")
              submenu.addItem(usedItem)
              let freeItem = NSMenuItem()
              freeItem.view = createDisabledLabelView(text: "Free Quota: \(limit)")
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
              
              quotaItem.submenu = submenu
              
              menu.insertItem(quotaItem, at: insertIndex)
              insertIndex += 1
          }
         
           let quotaOrder: [ProviderIdentifier] = [.claude, .codex, .antigravity]
            for identifier in quotaOrder {
                guard isProviderEnabled(identifier) else { continue }
                
                if let result = providerResults[identifier] {
                    if case .quotaBased(let remaining, let entitlement, _) = result.usage {
                        hasQuota = true
                        let percentage = entitlement > 0 ? (Double(remaining) / Double(entitlement)) * 100 : 0
                        let item = createQuotaMenuItem(identifier: identifier, percentage: percentage)
                        item.tag = 999
                        
                        if let details = result.details, details.hasAnyValue {
                            item.submenu = createDetailSubmenu(details, identifier: identifier)
                        }
                        
                        menu.insertItem(item, at: insertIndex)
                        insertIndex += 1
                    }
                 } else if loadingProviders.contains(identifier) {
                     hasQuota = true
                     let item = NSMenuItem()
                     item.view = createDisabledLabelView(
                         text: "\(identifier.displayName)    Loading...",
                         icon: iconForProvider(identifier)
                     )
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
                    
                    for account in geminiAccounts {
                        hasQuota = true
                        let accountNumber = account.accountIndex + 1
                        let title = geminiAccounts.count > 1
                            ? String(format: "Gemini CLI (#%d)    %.0f%% remaining", accountNumber, account.remainingPercentage)
                            : String(format: "Gemini CLI    %.0f%% remaining", account.remainingPercentage)
                        
                        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                        item.image = iconForProvider(.geminiCLI)
                        if account.remainingPercentage < 20 {
                            item.image = tintedImage(iconForProvider(.geminiCLI), color: .systemRed)
                        }
                        item.tag = 999
                        
                        item.submenu = createGeminiAccountSubmenu(account)
                        
                        menu.insertItem(item, at: insertIndex)
                        insertIndex += 1
                    }
                } else if loadingProviders.contains(.geminiCLI) {
                    hasQuota = true
                    let item = NSMenuItem()
                    item.view = createDisabledLabelView(
                        text: "Gemini CLI    Loading...",
                        icon: iconForProvider(.geminiCLI)
                    )
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
        
        let separator3 = NSMenuItem.separator()
        separator3.tag = 999
        menu.insertItem(separator3, at: insertIndex)
        
        if let usage = currentUsage {
            let totalCost = calculatePayAsYouGoTotal(providerResults: providerResults, copilotUsage: usage)
            statusBarIconView.update(used: usage.usedRequests, limit: usage.limitRequests, cost: totalCost)
        }
        debugLog("updateMultiProviderMenu: completed successfully")
        logMenuStructure()
    }
    
    private func logMenuStructure() {
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
    
    private func createQuotaMenuItem(identifier: ProviderIdentifier, percentage: Double) -> NSMenuItem {
        let title = String(format: "%@    %.0f%% remaining", identifier.displayName, percentage)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = iconForProvider(identifier)
        
        if percentage < 20 {
            item.image = tintedImage(iconForProvider(identifier), color: .systemRed)
        }
        
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
        var leadingOffset: CGFloat = 14 + indent
        let menuWidth: CGFloat = 300
        let labelFont = font ?? (monospaced ? NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular) : NSFont.systemFont(ofSize: 13))
        
        if icon != nil {
            leadingOffset = 36
        }
        
        let availableWidth = menuWidth - leadingOffset - 14
        var viewHeight: CGFloat = 22
        
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
          // Menu bar shows total Pay-as-you-go cost (Copilot Add-on + OpenRouter + OpenCode Zen + etc.)
          let totalPayAsYouGoCost = calculatePayAsYouGoTotal(providerResults: providerResults, copilotUsage: usage)
          statusBarIconView.update(used: usage.usedRequests, limit: usage.limitRequests, cost: totalPayAsYouGoCost)
          signInItem.isHidden = true
          updateHistorySubmenu()
          updateMultiProviderMenu()
      }
    
    private func updateUIForLoggedOut() {
        statusBarIconView.showError()
        signInItem.isHidden = false
    }
    
    private func handleFetchError(_ error: Error) {
        statusBarIconView.showError()
    }
    
    @objc private func signInClicked() {
        NotificationCenter.default.post(name: Notification.Name("sessionExpired"), object: nil)
    }
    
    @objc private func refreshClicked() {
        logger.info("refreshClicked called")
        fetchUsage()
    }

    @objc private func resetLoginClicked() {
        Task { @MainActor in
            await AuthManager.shared.resetSession()
            clearCaches()
            currentUsage = nil
            customerId = nil
            usageHistory = nil
            lastHistoryFetchResult = .none
            historyFetchTimer?.invalidate()
            historyFetchTimer = nil
            updateUIForLoggedOut()
            NotificationCenter.default.post(name: Notification.Name("sessionExpired"), object: nil)
        }
    }
    
    @objc private func openBillingClicked() {
        if let url = URL(string: "https://github.com/settings/billing/premium_requests_usage") { NSWorkspace.shared.open(url) }
    }
    
    @objc private func quitClicked() {
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
    
    private func saveCache(usage: CopilotUsage) {
        if let data = try? JSONEncoder().encode(CachedUsage(usage: usage, timestamp: Date())) {
            UserDefaults.standard.set(data, forKey: "copilot.usage.cache")
        }
    }

    private func clearCaches() {
        UserDefaults.standard.removeObject(forKey: "copilot.usage.cache")
        UserDefaults.standard.removeObject(forKey: "copilot.history.cache")
    }
    
    private func loadCache() -> CachedUsage? {
        guard let data = UserDefaults.standard.data(forKey: "copilot.usage.cache") else { return nil }
        return try? JSONDecoder().decode(CachedUsage.self, from: data)
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
    
    private func fetchUsageHistoryNow() {
        guard let customerId = self.customerId else {
            logger.warning("fetchUsageHistoryNow: customerId is nil, skipping")
            return
        }
        
        logger.info("fetchUsageHistoryNow: started, customerId=\(customerId)")
        
        let webView = AuthManager.shared.webView
        
        Task { @MainActor in
            let js = """
            return await (async function() {
                try {
                    const res = await fetch('/settings/billing/copilot_usage_table?customer_id=\(customerId)&group=0&period=3&query=&page=1', {
                        headers: { 'Accept': 'application/json', 'x-requested-with': 'XMLHttpRequest' }
                    });
                    return await res.json();
                } catch(e) { return { error: e.toString() }; }
            })()
            """
            
            do {
                let result = try await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .defaultClient)
                
                guard let rootDict = result as? [String: Any] else {
                    logger.error("fetchUsageHistoryNow: failed - result is not dictionary")
                    self.lastHistoryFetchResult = self.usageHistory != nil ? .failedWithCache : .failedNoCache
                    return
                }
                
                if let error = rootDict["error"] as? String {
                    logger.error("fetchUsageHistoryNow: failed - JS error: \(error)")
                    self.lastHistoryFetchResult = self.usageHistory != nil ? .failedWithCache : .failedNoCache
                    return
                }
                
                guard let table = rootDict["table"] as? [String: Any],
                      let rows = table["rows"] as? [[String: Any]] else {
                    logger.error("fetchUsageHistoryNow: failed - failed to parse table/rows")
                    self.lastHistoryFetchResult = self.usageHistory != nil ? .failedWithCache : .failedNoCache
                    return
                }
                
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z 'utc'"
                dateFormatter.locale = Locale(identifier: "en_US_POSIX")
                dateFormatter.timeZone = TimeZone(identifier: "UTC")
                
                var dailyUsages: [DailyUsage] = []
                
                for row in rows {
                    guard let cells = row["cells"] as? [[String: Any]],
                          cells.count >= 5 else {
                        continue
                    }
                    
                    guard let dateStr = cells[0]["sortValue"] as? String,
                          let date = dateFormatter.date(from: dateStr) else {
                        continue
                    }
                    
                    let includedRequests = parseDoubleFromCell(cells[1]["value"])
                    let billedRequests = parseDoubleFromCell(cells[2]["value"])
                    let grossAmount = parseCurrencyFromCell(cells[3]["value"])
                    let billedAmount = parseCurrencyFromCell(cells[4]["value"])
                    
                    dailyUsages.append(DailyUsage(
                        date: date,
                        includedRequests: includedRequests,
                        billedRequests: billedRequests,
                        grossAmount: grossAmount,
                        billedAmount: billedAmount
                    ))
                }
                
                dailyUsages.sort { $0.date > $1.date }
                
                let history = UsageHistory(fetchedAt: Date(), days: dailyUsages)
                self.usageHistory = history
                self.lastHistoryFetchResult = .success
                self.saveHistoryCache(history)
                
                logger.info("fetchUsageHistoryNow: completed, days.count=\(history.days.count), totalRequests=\(history.totalRequests)")
                self.updateHistorySubmenu()
            } catch {
                logger.error("fetchUsageHistoryNow: failed - \(error.localizedDescription)")
                self.handleHistoryFetchFailure()
                self.updateHistorySubmenu()
            }
        }
    }
    
    private func parseDoubleFromCell(_ value: Any?) -> Double {
        guard let str = value as? String else { return 0 }
        let cleaned = str.replacingOccurrences(of: ",", with: "")
        return Double(cleaned) ?? 0
    }
    
    private func parseCurrencyFromCell(_ value: Any?) -> Double {
        guard let str = value as? String else { return 0 }
        let cleaned = str.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
        return Double(cleaned) ?? 0
    }
    
    private func handleHistoryFetchFailure() {
        if let cached = loadHistoryCache() {
            if hasMonthChanged(cached.fetchedAt) {
                UserDefaults.standard.removeObject(forKey: "copilot.history.cache")
                self.usageHistory = nil
                self.lastHistoryFetchResult = .failedNoCache
            } else {
                self.usageHistory = cached
                self.lastHistoryFetchResult = .failedWithCache
            }
        } else {
            self.usageHistory = nil
            self.lastHistoryFetchResult = .failedNoCache
        }
    }
    
    private func startHistoryFetchTimer() {
        historyFetchTimer?.invalidate()
        fetchUsageHistoryNow()
        historyFetchTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            self?.fetchUsageHistoryNow()
        }
    }
    
    func getHistoryUIState() -> HistoryUIState {
        guard let history = usageHistory else {
            return HistoryUIState(history: nil, prediction: nil, isStale: false, hasNoData: true)
        }
        
        let stale = isHistoryStale(history)
        
        var prediction: UsagePrediction? = nil
        if let currentUsage = self.currentUsage {
            prediction = usagePredictor.predict(history: history, currentUsage: currentUsage)
        }
        
        return HistoryUIState(
            history: history,
            prediction: prediction,
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
            if dayData.breakdown.count > 0 {
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
        predictionPeriodItem.submenu = predictionPeriodMenu
        historySubmenu.addItem(predictionPeriodItem)
        debugLog("updateHistorySubmenu: completed successfully")
    }
}
