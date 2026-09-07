import AppKit
import Sparkle
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "AppDelegate")

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    var statusBarController: StatusBarController!
    private(set) var updaterController: SPUStandardUpdaterController!

    @objc func checkForUpdates() {
        logger.info("⌨️ [Keyboard] ⌘U Check for Updates triggered")
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted XCTest runs exercise their own controllers without starting the live app.
        guard NSClassFromString("XCTestCase") == nil else {
            logger.debug("XCTest host launch: application services are disabled")
            return
        }
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
        statusBarController = StatusBarController(startBackgroundServices: true)
        closeAllWindows()
    }
    
    private func configureAutomaticUpdates() {
        let updater = updaterController.updater
        let desiredCheckInterval: TimeInterval = 21600

        // Sparkle persists user preferences for update behavior.
        // Do not override these values on launch.
        if updater.updateCheckInterval != desiredCheckInterval {
            updater.updateCheckInterval = desiredCheckInterval
            logger.info("🔄 [Sparkle] Update check interval updated to 6h (\(desiredCheckInterval)s)")
        }

        let checksEnabled = updater.automaticallyChecksForUpdates
        let downloadsEnabled = updater.automaticallyDownloadsUpdates
        let checkInterval = updater.updateCheckInterval
        
        logger.info("🔄 [Sparkle] Auto-update state loaded: checks=\(checksEnabled), downloads=\(downloadsEnabled), interval=\(checkInterval)s")
    }

    private func closeAllWindows() {
        for window in NSApp.windows where window.title.contains("Settings") {
            window.close()
        }
    }

    // MARK: - SPUUpdaterDelegate
    
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        logger.info("🔄 [Sparkle] App will relaunch after update")
    }
    
    nonisolated func updaterDidRelaunchApplication(_ updater: SPUUpdater) {
        logger.info("✅ [Sparkle] App relaunched successfully")
    }
}
