import AppKit
import SwiftUI
import ServiceManagement
import WebKit
import os.log

private let logger = Logger(subsystem: "com.copilotmonitor", category: "StatusBarController")

// MARK: - Refresh Interval
enum RefreshInterval: Int, CaseIterable {
    case tenSeconds = 10
    case thirtySeconds = 30
    case oneMinute = 60
    case fiveMinutes = 300
    case thirtyMinutes = 1800
    
    var title: String {
        switch self {
        case .tenSeconds: return "10s"
        case .thirtySeconds: return "30s"
        case .oneMinute: return "1m"
        case .fiveMinutes: return "5m"
        case .thirtyMinutes: return "30m"
        }
    }
    
    static var defaultInterval: RefreshInterval { .thirtySeconds }
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

// MARK: - Status Bar Icon View
final class StatusBarIconView: NSView {
    private var percentage: Double = 0
    private var usedCount: Int = 0
    private var addOnCost: Double = 0
    private var isLoading = false
    private var hasError = false
    
    /// Dynamic width calculation based on content
    /// - Copilot icon (16px) + padding (6px) = 22px base
    /// - With add-on cost: icon + cost text width
    /// - Without add-on cost: icon + circle (8px) + padding (4px) + number text width
    override var intrinsicContentSize: NSSize {
        let baseIconWidth: CGFloat = 22 // icon (16) + right padding (6)
        
        if addOnCost > 0 {
            // Calculate cost text width dynamically
            let costText = formatCost(addOnCost)
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            let textWidth = (costText as NSString).size(withAttributes: [.font: font]).width
            return NSSize(width: baseIconWidth + textWidth + 4, height: 22)
        } else {
            // Circle (8px) + padding (4px) + number text width
            let text = isLoading ? "..." : (hasError ? "Err" : "\(usedCount)")
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
            return NSSize(width: baseIconWidth + 8 + 4 + textWidth + 4, height: 22)
        }
    }
    
    func update(used: Int, limit: Int, cost: Double = 0) {
        usedCount = used
        addOnCost = cost
        percentage = limit > 0 ? min((Double(used) / Double(limit)) * 100, 100) : 0
        isLoading = false
        hasError = false
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
    
    func showLoading() {
        isLoading = true
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
    
    func showError() {
        hasError = true
        isLoading = false
        addOnCost = 0  // Reset add-on cost to hide dollar sign
        usedCount = 0
        percentage = 0
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        
        drawCopilotIcon(at: NSPoint(x: 2, y: 3), size: 16, isDark: isDark)
        
        if addOnCost > 0 {
            drawCostText(at: NSPoint(x: 22, y: 3), isDark: isDark)
        } else {
            let progressRect = NSRect(x: 22, y: 7, width: 8, height: 8)
            drawCircularProgress(in: progressRect, isDark: isDark)
            drawUsageText(at: NSPoint(x: 34, y: 3), isDark: isDark)
        }
    }
    
    private func drawCopilotIcon(at origin: NSPoint, size: CGFloat, isDark: Bool) {
        guard let icon = NSImage(named: "CopilotIcon") else { return }
        icon.isTemplate = true
        
        let tintedImage = NSImage(size: icon.size)
        tintedImage.lockFocus()
        NSColor.white.set()
        let imageRect = NSRect(origin: .zero, size: icon.size)
        imageRect.fill()
        icon.draw(in: imageRect, from: .zero, operation: .destinationIn, fraction: 1.0)
        tintedImage.unlockFocus()
        tintedImage.isTemplate = false
        
        let iconRect = NSRect(x: origin.x, y: origin.y, width: size, height: size)
        tintedImage.draw(in: iconRect)
    }
    
    private func drawCircularProgress(in rect: NSRect, isDark: Bool) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 0.5
        let lineWidth: CGFloat = 2
        
        NSColor.white.withAlphaComponent(0.2).setStroke()
        let bgPath = NSBezierPath()
        bgPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        bgPath.lineWidth = lineWidth
        bgPath.stroke()
        
        if isLoading {
            NSColor.white.withAlphaComponent(0.6).setStroke()
            let loadingPath = NSBezierPath()
            loadingPath.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 180)
            loadingPath.lineWidth = lineWidth
            loadingPath.stroke()
            return
        }
        
        if hasError {
            NSColor.white.withAlphaComponent(0.6).setStroke()
            let errorPath = NSBezierPath()
            errorPath.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 90, clockwise: true)
            errorPath.lineWidth = lineWidth
            errorPath.stroke()
            return
        }
        
        NSColor.white.setStroke()
        let endAngle = 90 - (360 * percentage / 100)
        let progressPath = NSBezierPath()
        progressPath.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: CGFloat(endAngle), clockwise: true)
        progressPath.lineWidth = lineWidth
        progressPath.stroke()
    }
    
    private func drawUsageText(at origin: NSPoint, isDark: Bool) {
        let text: String
        
        if isLoading {
            text = "..."
        } else if hasError {
            text = "Err"
        } else {
            text = "\(usedCount)"
        }
        
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        
        let attrString = NSAttributedString(string: text, attributes: attributes)
        attrString.draw(at: origin)
    }
    
    private func drawCostText(at origin: NSPoint, isDark: Bool) {
        let text = formatCost(addOnCost)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        attrString.draw(at: origin)
    }
    
    private func formatCost(_ cost: Double) -> String {
        if cost >= 10 {
            return String(format: "$%.1f", cost)
        } else {
            return String(format: "$%.2f", cost)
        }
    }
    
    private func colorForPercentage(_ percentage: Double, isDark: Bool) -> NSColor {
        return NSColor.white
    }
}

// MARK: - Custom Usage View
final class UsageMenuItemView: NSView {
    private let progressBar: NSView
    private let progressFill: NSView
    private let usageLabel: NSTextField
    private let percentLabel: NSTextField
    private let costLabel: NSTextField
    
    private var fillWidthConstraint: NSLayoutConstraint?
    
    override var intrinsicContentSize: NSSize {
        return NSSize(width: 220, height: 68)
    }
    
    override init(frame frameRect: NSRect) {
        progressBar = NSView()
        progressFill = NSView()
        usageLabel = NSTextField(labelWithString: "")
        percentLabel = NSTextField(labelWithString: "")
        costLabel = NSTextField(labelWithString: "")
        
        super.init(frame: frameRect)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupViews() {
        usageLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        usageLabel.textColor = .labelColor
        usageLabel.alignment = .left
        usageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(usageLabel)
        
        percentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.alignment = .right
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(percentLabel)
        
        progressBar.wantsLayer = true
        progressBar.layer?.cornerRadius = 4
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressBar)
        
        progressFill.wantsLayer = true
        progressFill.layer?.cornerRadius = 3
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressBar.addSubview(progressFill)
        
        costLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        costLabel.textColor = .secondaryLabelColor
        costLabel.alignment = .right
        costLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(costLabel)
        
        updateColors()
        
        NSLayoutConstraint.activate([
            usageLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            usageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            
            percentLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            percentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            percentLabel.leadingAnchor.constraint(greaterThanOrEqualTo: usageLabel.trailingAnchor, constant: 8),
            
            progressBar.topAnchor.constraint(equalTo: usageLabel.bottomAnchor, constant: 6),
            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            progressBar.heightAnchor.constraint(equalToConstant: 8),
            
            progressFill.topAnchor.constraint(equalTo: progressBar.topAnchor, constant: 1),
            progressFill.bottomAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: -1),
            progressFill.leadingAnchor.constraint(equalTo: progressBar.leadingAnchor, constant: 1),
            
            costLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 6),
            costLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            costLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 14),
            costLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        
        fillWidthConstraint = progressFill.widthAnchor.constraint(equalToConstant: 0)
        fillWidthConstraint?.isActive = true
    }
    
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }
    
    private func updateColors() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        progressBar.layer?.backgroundColor = (isDark ? NSColor.white.withAlphaComponent(0.1) : NSColor.black.withAlphaComponent(0.08)).cgColor
    }
    
    static func colorForPercentage(_ percentage: Double) -> NSColor {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        switch percentage {
        case 0..<50:
            return isDark ? NSColor.systemGreen.withAlphaComponent(0.9) : NSColor.systemGreen
        case 50..<75:
            return isDark ? NSColor.systemYellow.withAlphaComponent(0.95) : NSColor.systemYellow.blended(withFraction: 0.3, of: .systemOrange) ?? .systemYellow
        case 75..<90:
            return isDark ? NSColor.systemOrange : NSColor.systemOrange.blended(withFraction: 0.2, of: .systemRed) ?? .systemOrange
        default:
            return NSColor.systemRed
        }
    }
    
    func update(usage: CopilotUsage) {
        let used = usage.usedRequests
        let limit = usage.limitRequests
        let percentage = limit > 0 ? min((Double(used) / Double(limit)) * 100, 100) : 0
        
        usageLabel.stringValue = "Used: \(used.formatted()) / \(limit.formatted())"
        percentLabel.stringValue = "\(Int(percentage))%"
        
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        let costString = formatter.string(from: NSNumber(value: usage.netBilledAmount)) ?? String(format: "$%.2f", usage.netBilledAmount)
        costLabel.stringValue = "Add-on Cost: \(costString)"
        
        if usage.netBilledAmount > 0 {
            costLabel.textColor = .systemOrange
        } else {
            costLabel.textColor = .secondaryLabelColor
        }
        
        let color = Self.colorForPercentage(percentage)
        progressFill.layer?.backgroundColor = color.cgColor
        percentLabel.textColor = color
        
        layoutSubtreeIfNeeded()
        let barWidth = progressBar.bounds.width - 2
        let fillWidth = barWidth * CGFloat(percentage / 100)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.allowsImplicitAnimation = true
            self.fillWidthConstraint?.constant = max(fillWidth, 0)
            self.layoutSubtreeIfNeeded()
        }
    }
    
    func showLoading() {
        usageLabel.stringValue = "Loading..."
        percentLabel.stringValue = ""
        costLabel.stringValue = ""
        progressFill.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        fillWidthConstraint?.constant = 40
    }
    
    func showError(_ message: String) {
        usageLabel.stringValue = message
        percentLabel.stringValue = "⚠️"
        costLabel.stringValue = ""
        percentLabel.textColor = .systemOrange
        progressFill.layer?.backgroundColor = NSColor.systemOrange.cgColor
        fillWidthConstraint?.constant = 0
    }
}

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
    private var providerResults: [ProviderIdentifier: ProviderUsage] = [:]
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
        
        signInItem = NSMenuItem(title: "Sign In", action: #selector(signInClicked), keyEquivalent: "")
        signInItem.image = NSImage(systemSymbolName: "person.crop.circle.badge.checkmark", accessibilityDescription: "Sign In")
        signInItem.target = self
        menu.addItem(signInItem)

        resetLoginItem = NSMenuItem(title: "Reset Login", action: #selector(resetLoginClicked), keyEquivalent: "")
        resetLoginItem.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset Login")
        resetLoginItem.target = self
        menu.addItem(resetLoginItem)
        
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
        
        let enabledProvidersItem = NSMenuItem(title: "Enabled Providers", action: nil, keyEquivalent: "")
        enabledProvidersItem.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Enabled Providers")
        enabledProvidersMenu = NSMenu()
        
        for identifier in ProviderIdentifier.allCases {
            let item = NSMenuItem(title: identifier.displayName, action: #selector(toggleProvider(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = identifier.rawValue
            item.state = isProviderEnabled(identifier) ? .on : .off
            enabledProvidersMenu.addItem(item)
        }
        
        enabledProvidersItem.submenu = enabledProvidersMenu
        menu.addItem(enabledProvidersItem)
        
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
