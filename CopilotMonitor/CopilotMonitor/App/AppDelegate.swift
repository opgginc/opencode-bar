import AppKit
import Sparkle
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "AppDelegate")

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    var statusBarController: StatusBarController!
    private(set) var updaterController: SPUStandardUpdaterController!
    private var updateCheckTimer: Timer?

    @objc func checkForUpdates() {
        logger.info("⌨️ [Keyboard] ⌘U Check for Updates triggered")
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
        closeAllWindows()
        startUpdateCheckTimer()
    }
    
    private func configureAutomaticUpdates() {
        let updater = updaterController.updater
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = true
        updater.updateCheckInterval = 43200
        
        logger.info("🔄 [Sparkle] Auto-update configured: checks=\(updater.automaticallyChecksForUpdates), downloads=\(updater.automaticallyDownloadsUpdates), interval=\(updater.updateCheckInterval)s")
    }
    
    private func startUpdateCheckTimer() {
        updateCheckTimer?.invalidate()
        
        let checkInterval: TimeInterval = 21600
        let initialDelay: TimeInterval = 30
        
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

    deinit {
        updateCheckTimer?.invalidate()
    }
    
    // MARK: - SPUUpdaterDelegate
    
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        logger.info("🔄 [Sparkle] App will relaunch after update")
    }
    
    nonisolated func updaterDidRelaunchApplication(_ updater: SPUUpdater) {
        logger.info("✅ [Sparkle] App relaunched successfully")
    }
}
