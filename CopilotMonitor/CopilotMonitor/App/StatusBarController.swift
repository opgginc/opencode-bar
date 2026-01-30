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
    private var usageItem: NSMenuItem!
    private var usageView: UsageMenuItemView!
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
    private var predictionPeriodMenu: NSMenu!
    
    // Multi-provider properties
    private var providerResults: [ProviderIdentifier: ProviderResult] = [:]
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
        setupStatusItem()
        setupMenu()
        setupNotificationObservers()
        startRefreshTimer()
        logger.info("init 완료")
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        statusBarIconView = StatusBarIconView(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
        statusBarIconView.showLoading()
        statusItem.button?.addSubview(statusBarIconView)
        statusItem.button?.frame = statusBarIconView.frame
    }
    
    private func setupMenu() {
        menu = NSMenu()
        
        usageView = UsageMenuItemView(frame: NSRect(x: 0, y: 0, width: 220, height: 68))
        usageView.showLoading()
        usageItem = NSMenuItem()
        usageItem.view = usageView
        menu.addItem(usageItem)
        
        menu.addItem(NSMenuItem.separator())
        
        historyMenuItem = NSMenuItem(title: "Usage History", action: nil, keyEquivalent: "")
        historyMenuItem.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Usage History")
        historySubmenu = NSMenu()
        historyMenuItem.submenu = historySubmenu
        let loadingItem = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
        loadingItem.isEnabled = false
        historySubmenu.addItem(loadingItem)
        menu.addItem(historyMenuItem)
        
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
        
        let openBillingItem = NSMenuItem(title: "Open Billing", action: #selector(openBillingClicked), keyEquivalent: "b")
        openBillingItem.image = NSImage(systemSymbolName: "creditcard", accessibilityDescription: "Open Billing")
        openBillingItem.target = self
        menu.addItem(openBillingItem)
        
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
    
    @objc private func predictionPeriodSelected(_ sender: NSMenuItem) {
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
            logger.info("노티 수신: billingPageLoaded")
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                self?.fetchUsage()
                self?.startHistoryFetchTimer()
            }
        }
        NotificationCenter.default.addObserver(forName: Notification.Name("sessionExpired"), object: nil, queue: .main) { [weak self] _ in
            logger.info("노티 수신: sessionExpired")
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                self?.updateUIForLoggedOut()
                self?.historyFetchTimer?.invalidate()
                self?.historyFetchTimer = nil
            }
        }
    }
    
    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        
        let interval = TimeInterval(refreshInterval.rawValue)
        let intervalTitle = refreshInterval.title
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            logger.info("타이머 트리거 (\(intervalTitle))")
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
        logger.info("triggerRefresh 시작")
        AuthManager.shared.loadBillingPage()
    }
    
    private func fetchUsage() {
        logger.info("fetchUsage 시작, isFetching: \(self.isFetching)")
        guard !isFetching else { return }
        isFetching = true
        statusBarIconView.showLoading()
        usageView.showLoading()
        
        Task {
            await performFetchUsage()
            await fetchMultiProviderData()
        }
    }
    
    // MARK: - Fetch Usage Helpers (Split for Swift compiler type-check performance on older Xcode)
    
    private func performFetchUsage() async {
        let webView = AuthManager.shared.webView
        let customerId = await fetchCustomerId(webView: webView)
        
        if let validId = customerId {
            self.customerId = validId
            let success = await fetchAndProcessUsageData(webView: webView, customerId: validId)
            if success {
                isFetching = false
                return
            }
        }
        
        handleFetchFallback()
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
        logger.info("fetchUsage: [Step 1] API(/api/v3/user)를 통한 ID 확보 시도")
        
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
                logger.info("fetchUsage: API ID 확보 성공 - \(id)")
                return String(id)
            }
        } catch {
            logger.error("fetchUsage: API 호출 중 에러 - \(error.localizedDescription)")
        }
        
        return nil
    }
    
    private func fetchCustomerIdFromDOM(webView: WKWebView) async -> String? {
        logger.info("fetchUsage: [Step 2] DOM 추출 시도")
        
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
            logger.info("fetchUsage: DOM에서 customerId 추출 성공 - \(extracted)")
            return extracted
        }
        
        return nil
    }
    
    private func fetchCustomerIdFromHTML(webView: WKWebView) async -> String? {
        logger.info("fetchUsage: [Step 3] HTML Regex 시도")
        
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
                logger.info("fetchUsage: HTML에서 ID 발견 - \(customerId)")
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
            let result = try await webView.callAsyncJavaScript(cardJS, arguments: [:], in: nil, contentWorld: .defaultClient)
            
            guard let rootDict = result as? [String: Any] else {
                return false
            }
            
            if let usage = parseUsageFromResponse(rootDict) {
                currentUsage = usage
                lastFetchTime = Date()
                updateUIForSuccess(usage: usage)
                saveCache(usage: usage)
                logger.info("fetchUsage: 성공")
                return true
            }
        } catch {
            logger.error("fetchUsage: JS 실행 중 에러 - \(error.localizedDescription)")
        }
        
        return false
    }
    
    private func parseUsageFromResponse(_ rootDict: [String: Any]) -> CopilotUsage? {
        var dict = rootDict
        if let payload = rootDict["payload"] as? [String: Any] {
            dict = payload
        } else if let data = rootDict["data"] as? [String: Any] {
            dict = data
        }
        
        logger.info("fetchUsage: 데이터 파싱 시도 (Keys: \(dict.keys.joined(separator: ", ")))")
        
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
        let enabledProviders = ProviderManager.shared.getAllProviders().filter { provider in
            isProviderEnabled(provider.identifier) && provider.identifier != .copilot
        }
        
        // DEBUG: Log to file
        let enabledNames = enabledProviders.map { $0.identifier.displayName }
        let debugLog = "🔍 DEBUG fetchMultiProviderData: enabledProviders = \(enabledNames)\n"
        try? debugLog.write(toFile: "/tmp/copilot_debug.log", atomically: false, encoding: .utf8)
        
        guard !enabledProviders.isEmpty else {
            logger.info("fetchMultiProviderData: No enabled providers, skipping")
            print("🔍 DEBUG: No enabled providers, returning early")
            return
        }
        
        logger.info("fetchMultiProviderData: Fetching \(enabledProviders.count) providers")
        let results = await ProviderManager.shared.fetchAll()
        
        let fetchAllMsg = "📥 fetchAll returned \(results.count) results: \(results.keys.map { $0.displayName })\n"
        if let handle = FileHandle(forWritingAtPath: "/tmp/copilot_debug.log") {
            handle.seekToEndOfFile()
            handle.write(fetchAllMsg.data(using: .utf8)!)
            handle.closeFile()
        }
        
        let filteredResults = results.filter { (identifier, _) in
            isProviderEnabled(identifier) && identifier != .copilot
        }
        
        let filterMsg = "🔎 After filter: \(filteredResults.count) results: \(filteredResults.keys.map { $0.displayName })\n"
        if let handle = FileHandle(forWritingAtPath: "/tmp/copilot_debug.log") {
            handle.seekToEndOfFile()
            handle.write(filterMsg.data(using: .utf8)!)
            handle.closeFile()
        }
        
        await MainActor.run {
            let mainActorMsg = "🎯 MainActor.run: Setting providerResults and calling updateMultiProviderMenu\n"
            if let handle = FileHandle(forWritingAtPath: "/tmp/copilot_debug.log") {
                handle.seekToEndOfFile()
                handle.write(mainActorMsg.data(using: .utf8)!)
                handle.closeFile()
            }
            
            self.providerResults = filteredResults
            self.updateMultiProviderMenu()
        }
        
        logger.info("fetchMultiProviderData: Completed with \(filteredResults.count) results")
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
          // DEBUG: Log entry
          let debugEntry = "\n📋 updateMultiProviderMenu called\n"
          if let handle = FileHandle(forWritingAtPath: "/tmp/copilot_debug.log") {
              handle.seekToEndOfFile()
              handle.write(debugEntry.data(using: .utf8)!)
              handle.closeFile()
          }
          
          guard let historyIndex = menu.items.firstIndex(of: historyMenuItem) else {
              let debugMsg = "❌ historyMenuItem not found in menu!\n"
              if let handle = FileHandle(forWritingAtPath: "/tmp/copilot_debug.log") {
                  handle.seekToEndOfFile()
                  handle.write(debugMsg.data(using: .utf8)!)
                  handle.closeFile()
              }
              return
          }
          
          // DEBUG: Log historyIndex
          let debugIdx = "📍 historyIndex = \(historyIndex)\n"
          if let handle = FileHandle(forWritingAtPath: "/tmp/copilot_debug.log") {
              handle.seekToEndOfFile()
              handle.write(debugIdx.data(using: .utf8)!)
              handle.closeFile()
          }
          
          var itemsToRemove: [NSMenuItem] = []
          for i in (historyIndex + 1)..<menu.items.count {
              let item = menu.items[i]
              if item.tag == 999 {
                  itemsToRemove.append(item)
              }
          }
          itemsToRemove.forEach { menu.removeItem($0) }
         
         let hasCopilotData = currentUsage != nil
         
         // DEBUG: Log providerResults
         let debugResults = "📊 providerResults.count = \(providerResults.count), hasCopilotData = \(hasCopilotData)\n"
         if let handle = FileHandle(forWritingAtPath: "/tmp/copilot_debug.log") {
             handle.seekToEndOfFile()
             handle.write(debugResults.data(using: .utf8)!)
             handle.closeFile()
         }
         
         for (id, result) in providerResults {
             let debugItem = "  - \(id.displayName): \(result.usage)\n"
             if let handle = FileHandle(forWritingAtPath: "/tmp/copilot_debug.log") {
                 handle.seekToEndOfFile()
                 handle.write(debugItem.data(using: .utf8)!)
                 handle.closeFile()
             }
         }
         
         guard !providerResults.isEmpty || hasCopilotData else {
             let debugEmpty = "⚠️ No data to display, returning early\n"
             if let handle = FileHandle(forWritingAtPath: "/tmp/copilot_debug.log") {
                 handle.seekToEndOfFile()
                 handle.write(debugEmpty.data(using: .utf8)!)
                 handle.closeFile()
             }
             return
         }
        
        var insertIndex = historyIndex + 1
        
         let separator1 = NSMenuItem.separator()
         separator1.tag = 999
         menu.insertItem(separator1, at: insertIndex)
         insertIndex += 1
         
          let total = calculatePayAsYouGoTotal(providerResults: providerResults, copilotUsage: currentUsage)
          let payAsYouGoHeader = NSMenuItem(
              title: String(format: "Pay-as-you-go                    $%.2f", total),
              action: nil, keyEquivalent: ""
          )
         payAsYouGoHeader.isEnabled = false
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
               submenu.addItem(NSMenuItem(title: String(format: "Overage Requests: %.0f", copilotUsage.netQuantity), action: nil, keyEquivalent: ""))
               submenu.addItem(NSMenuItem(title: String(format: "Billed Amount: $%.2f", copilotUsage.netBilledAmount), action: nil, keyEquivalent: ""))
               addOnItem.submenu = submenu
               
               menu.insertItem(addOnItem, at: insertIndex)
               insertIndex += 1
           }
         
           for (identifier, result) in providerResults {
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
         }
        
        if !hasPayAsYouGo {
            let noItem = NSMenuItem(title: "  No providers", action: nil, keyEquivalent: "")
            noItem.isEnabled = false
            noItem.tag = 999
            menu.insertItem(noItem, at: insertIndex)
            insertIndex += 1
        }
        
        let separator2 = NSMenuItem.separator()
        separator2.tag = 999
        menu.insertItem(separator2, at: insertIndex)
        insertIndex += 1
        
         let quotaHeader = NSMenuItem(title: "Quota Status", action: nil, keyEquivalent: "")
         quotaHeader.isEnabled = false
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
              let quotaItem = createQuotaMenuItem(identifier: .copilot, percentage: percentage)
              quotaItem.tag = 999
              
              let submenu = NSMenu()
              submenu.addItem(NSMenuItem(title: String(format: "Used: %d / %d", used, limit), action: nil, keyEquivalent: ""))
              submenu.addItem(NSMenuItem(title: String(format: "Remaining: %d", remaining), action: nil, keyEquivalent: ""))
              submenu.addItem(NSMenuItem(title: String(format: "Free Quota: %d", limit), action: nil, keyEquivalent: ""))
              quotaItem.submenu = submenu
              
              menu.insertItem(quotaItem, at: insertIndex)
              insertIndex += 1
          }
         
          for (identifier, result) in providerResults {
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
         }
        
        if !hasQuota {
            let noItem = NSMenuItem(title: "  No providers", action: nil, keyEquivalent: "")
            noItem.isEnabled = false
            noItem.tag = 999
            menu.insertItem(noItem, at: insertIndex)
            insertIndex += 1
        }
        
        let separator3 = NSMenuItem.separator()
        separator3.tag = 999
        menu.insertItem(separator3, at: insertIndex)
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
             image = NSImage(systemSymbolName: identifier.iconName, accessibilityDescription: identifier.displayName)
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
    
    private func createDetailSubmenu(_ details: DetailedUsage, identifier: ProviderIdentifier) -> NSMenu {
        let submenu = NSMenu()
        
        // Add provider-specific details based on identifier
        switch identifier {
        case .openRouter:
            if let remaining = details.creditsRemaining, let total = details.creditsTotal {
                let percent = total > 0 ? (remaining / total) * 100 : 0
                submenu.addItem(NSMenuItem(title: String(format: "Credits: $%.0f/$%.0f (%.0f%%)", remaining, total, percent), action: nil, keyEquivalent: ""))
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
            if let sonnet = details.sonnetUsage {
                submenu.addItem(NSMenuItem(title: String(format: "Sonnet: %.0f%%", sonnet), action: nil, keyEquivalent: ""))
            }
            if let opus = details.opusUsage {
                submenu.addItem(NSMenuItem(title: String(format: "Opus: %.0f%%", opus), action: nil, keyEquivalent: ""))
            }
            
        case .codex:
            if let primary = details.dailyUsage {
                submenu.addItem(NSMenuItem(title: String(format: "Primary: %.0f%%", primary), action: nil, keyEquivalent: ""))
            }
            if let secondary = details.secondaryUsage {
                submenu.addItem(NSMenuItem(title: String(format: "Secondary: %.0f%%", secondary), action: nil, keyEquivalent: ""))
            }
            if let plan = details.planType {
                submenu.addItem(NSMenuItem(title: "Plan: \(plan)", action: nil, keyEquivalent: ""))
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
         statusBarIconView.update(used: usage.usedRequests, limit: usage.limitRequests, cost: usage.netBilledAmount)
         usageView.update(usage: usage)
         signInItem.isHidden = true
         updateHistorySubmenu()
         updateMultiProviderMenu()
     }
    
    private func updateUIForLoggedOut() {
        statusBarIconView.showError()
        usageView.showError("Sign in required")
        signInItem.isHidden = false
    }
    
    private func handleFetchError(_ error: Error) {
        statusBarIconView.showError()
        usageView.showError("Update Failed")
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
            logger.info("캐시 없음 - 히스토리 로드 스킵")
            return
        }
        
        if hasMonthChanged(cached.fetchedAt) {
            logger.info("월 변경 감지 - 캐시 삭제")
            UserDefaults.standard.removeObject(forKey: "copilot.history.cache")
            return
        }
        
        self.usageHistory = cached
        self.lastHistoryFetchResult = .failedWithCache
        updateHistorySubmenu()
    }
    
    private func fetchUsageHistoryNow() {
        guard let customerId = self.customerId else {
            logger.warning("fetchUsageHistoryNow: customerId가 nil, 스킵")
            return
        }
        
        logger.info("fetchUsageHistoryNow: 시작, customerId=\(customerId)")
        
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
                    logger.error("fetchUsageHistoryNow: 실패 - 결과가 dictionary가 아님")
                    self.lastHistoryFetchResult = self.usageHistory != nil ? .failedWithCache : .failedNoCache
                    return
                }
                
                if let error = rootDict["error"] as? String {
                    logger.error("fetchUsageHistoryNow: 실패 - JS 에러: \(error)")
                    self.lastHistoryFetchResult = self.usageHistory != nil ? .failedWithCache : .failedNoCache
                    return
                }
                
                guard let table = rootDict["table"] as? [String: Any],
                      let rows = table["rows"] as? [[String: Any]] else {
                    logger.error("fetchUsageHistoryNow: 실패 - table/rows 파싱 실패")
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
                
                logger.info("fetchUsageHistoryNow: 완료, days.count=\(history.days.count), totalRequests=\(history.totalRequests)")
                self.updateHistorySubmenu()
            } catch {
                logger.error("fetchUsageHistoryNow: 실패 - \(error.localizedDescription)")
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
    
    private func getHistoryUIState() -> HistoryUIState {
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
    
    private func updateHistorySubmenu() {
        let state = getHistoryUIState()
        historySubmenu.removeAllItems()
        
        if state.hasNoData {
            let item = NSMenuItem(title: "No data", action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "tray", accessibilityDescription: "No data")
            item.isEnabled = false
            historySubmenu.addItem(item)
            return
        }
        
        if let prediction = state.prediction {
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
            historySubmenu.addItem(monthlyItem)
            
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
                historySubmenu.addItem(costItem)
            }
            
            if prediction.confidenceLevel == .low {
                let confItem = NSMenuItem(title: "Low prediction accuracy", action: nil, keyEquivalent: "")
                confItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Low accuracy")
                confItem.isEnabled = false
                historySubmenu.addItem(confItem)
            } else if prediction.confidenceLevel == .medium {
                let confItem = NSMenuItem(title: "Medium prediction accuracy", action: nil, keyEquivalent: "")
                confItem.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Medium accuracy")
                confItem.isEnabled = false
                historySubmenu.addItem(confItem)
            }
            
            historySubmenu.addItem(NSMenuItem.separator())
        }
        
        if state.isStale {
            let staleItem = NSMenuItem(title: "Data is stale", action: nil, keyEquivalent: "")
            staleItem.image = NSImage(systemSymbolName: "clock.badge.exclamationmark", accessibilityDescription: "Data is stale")
            staleItem.isEnabled = false
            historySubmenu.addItem(staleItem)
        }
        
        if let history = state.history {
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
                historySubmenu.addItem(item)
            }
        }
        
        historySubmenu.addItem(NSMenuItem.separator())
        let predictionPeriodItem = NSMenuItem(title: "Prediction Period", action: nil, keyEquivalent: "")
        predictionPeriodItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Prediction Period")
        predictionPeriodItem.submenu = predictionPeriodMenu
        historySubmenu.addItem(predictionPeriodItem)
    }
}
