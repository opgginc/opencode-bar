import AppKit
import SwiftUI
import Sparkle
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "AppDelegate")

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    var loginWindow: NSWindow?
    var statusBarController: StatusBarController!
    private var sessionExpiredObserver: NSObjectProtocol?
    private var billingLoadedObserver: NSObjectProtocol?

    // Sparkle Updater Controller - 자동 업데이트 관리
    // XIB 없이 코드로 초기화해야 함 (Menu Bar 앱이므로)
    private(set) var updaterController: SPUStandardUpdaterController!
    
    private var updateCheckTimer: Timer?

    @objc func checkForUpdates() {
        logger.info("⌨️ [Keyboard] ⌘U Check for Updates triggered")
        // Menu Bar apps (LSUIElement) need to be activated for Sparkle update UI to show
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppMigrationHelper.shared.checkAndMigrateIfNeeded() {
            return
        }
        
        AppMigrationHelper.shared.cleanupLegacyBundlesIfNeeded()
        
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        
        configureAutomaticUpdates()

        statusBarController = StatusBarController()
        setupNotificationObservers()

        closeAllWindows()
        startUpdateCheckTimer()
    }
    
    private func configureAutomaticUpdates() {
        let updater = updaterController.updater
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = true
        updater.updateCheckInterval = 43200 // 12 hours
        
        logger.info("🔄 [Sparkle] Auto-update configured: checks=\(updater.automaticallyChecksForUpdates), downloads=\(updater.automaticallyDownloadsUpdates), interval=\(updater.updateCheckInterval)s")
    }
    
    // Info.plist's SUScheduledCheckInterval may not trigger reliably for long-running Menu Bar apps
    private func startUpdateCheckTimer() {
        updateCheckTimer?.invalidate()
        
        let checkInterval: TimeInterval = 21600 // 6 hours
        let initialDelay: TimeInterval = 30 // Allow app to finish launching
        
        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) { [weak self] in
            self?.performBackgroundUpdateCheck()
        }
        
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.performBackgroundUpdateCheck()
        }
        
        logger.info("🔄 [Sparkle] Update check timer started: interval=\(checkInterval)s")
    }
    
    private func performBackgroundUpdateCheck() {
        logger.info("🔄 [Sparkle] Performing background update check...")
        updaterController.updater.checkForUpdatesInBackground()
    }

    private func closeAllWindows() {
        for window in NSApp.windows where window.title.contains("Settings") {
            window.close()
        }
    }

    private func setupNotificationObservers() {
        sessionExpiredObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("sessionExpired"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showLoginWindow()
        }

        billingLoadedObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("billingPageLoaded"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hideLoginWindow()
        }
    }

    func showLoginWindow() {
        if let window = loginWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GitHub Login"
        window.center()
        window.contentView = NSHostingView(rootView: LoginView(webView: AuthManager.shared.webView))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        loginWindow = window
        AuthManager.shared.loadLoginPage()
    }

    func hideLoginWindow() {
        loginWindow?.orderOut(nil)
    }

    deinit {
        updateCheckTimer?.invalidate()
        if let observer = sessionExpiredObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = billingLoadedObserver { NotificationCenter.default.removeObserver(observer) }
    }
    
    // MARK: - SPUUpdaterDelegate
    
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        logger.info("🔄 [Sparkle] App will relaunch after update")
    }
    
    nonisolated func updaterDidRelaunchApplication(_ updater: SPUUpdater) {
        logger.info("✅ [Sparkle] App relaunched successfully")
    }
}
