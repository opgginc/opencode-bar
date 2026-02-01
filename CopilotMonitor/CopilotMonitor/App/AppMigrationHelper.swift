import AppKit
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "Migration")

/// Handles app bundle name migration from old names to "OpenCode Bar.app"
/// This is needed because Sparkle updates replace bundle contents but keep the folder name,
/// causing "damaged or incomplete" errors when bundle name doesn't match executable name.
@MainActor
final class AppMigrationHelper {
    
    static let shared = AppMigrationHelper()
    
    /// The correct app bundle name that should be used
    private let targetBundleName = "OpenCode Bar.app"
    
    /// List of old bundle names that need migration
    private let legacyBundleNames = [
        "CopilotMonitor.app",
        "OpenCodeUsageMonitor.app",
        "ClaudeProvidersMonitor.app"
    ]
    
    private init() {}
    
    /// Check if migration is needed and perform it if necessary
    /// Returns true if migration was initiated (app will restart), false if no migration needed
    func checkAndMigrateIfNeeded() -> Bool {
        guard let bundlePath = Bundle.main.bundlePath as String? else {
            logger.error("❌ [Migration] Cannot get bundle path")
            return false
        }
        
        let currentBundleName = (bundlePath as NSString).lastPathComponent
        
        logger.info("📦 [Migration] Current bundle: \(currentBundleName) at \(bundlePath)")
        
        if currentBundleName == targetBundleName {
            logger.info("✅ [Migration] Bundle name is correct, no migration needed")
            return false
        }
        
        guard legacyBundleNames.contains(currentBundleName) else {
            logger.info("ℹ️ [Migration] Unknown bundle name '\(currentBundleName)', skipping migration")
            return false
        }
        
        logger.warning("⚠️ [Migration] Legacy bundle detected: \(currentBundleName) → \(self.targetBundleName)")
        
        return performMigration(from: bundlePath, currentName: currentBundleName)
    }
    
    private func performMigration(from currentPath: String, currentName: String) -> Bool {
        let parentDirectory = (currentPath as NSString).deletingLastPathComponent
        let targetPath = (parentDirectory as NSString).appendingPathComponent(targetBundleName)
        
        let fileManager = FileManager.default
        
        if fileManager.fileExists(atPath: targetPath) {
            logger.info("🔄 [Migration] Target exists, removing old version at \(targetPath)")
            do {
                try fileManager.removeItem(atPath: targetPath)
            } catch {
                logger.error("❌ [Migration] Failed to remove existing target: \(error.localizedDescription)")
                showMigrationError(message: "Failed to remove existing app at:\n\(targetPath)\n\nPlease remove it manually and restart.")
                return false
            }
        }
        
        logger.info("📋 [Migration] Copying \(currentPath) → \(targetPath)")
        do {
            try fileManager.copyItem(atPath: currentPath, toPath: targetPath)
        } catch {
            logger.error("❌ [Migration] Failed to copy app: \(error.localizedDescription)")
            showMigrationError(message: "Failed to migrate app:\n\(error.localizedDescription)\n\nPlease reinstall from the DMG.")
            return false
        }
        
        logger.info("🚀 [Migration] Launching migrated app at \(targetPath)")
        
        // Script: wait for quit → remove old bundle → launch new app
        let cleanupScript = """
            sleep 1
            rm -rf "\(currentPath)"
            open "\(targetPath)"
            """
        
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", cleanupScript]
        
        do {
            try task.run()
        } catch {
            logger.error("❌ [Migration] Failed to launch cleanup script: \(error.localizedDescription)")
            NSWorkspace.shared.open(URL(fileURLWithPath: targetPath))
        }
        
        logger.info("👋 [Migration] Quitting old app instance")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
        
        return true
    }
    
    private func showMigrationError(message: String) {
        let alert = NSAlert()
        alert.messageText = "Migration Failed"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    
    /// Called by the newly launched app to clean up after migration
    /// Checks if there's an old bundle that should be removed
    func cleanupLegacyBundlesIfNeeded() {
        guard let bundlePath = Bundle.main.bundlePath as String? else { return }
        
        let currentBundleName = (bundlePath as NSString).lastPathComponent
        guard currentBundleName == targetBundleName else { return }
        
        let parentDirectory = (bundlePath as NSString).deletingLastPathComponent
        let fileManager = FileManager.default
        
        for legacyName in legacyBundleNames {
            let legacyPath = (parentDirectory as NSString).appendingPathComponent(legacyName)
            if fileManager.fileExists(atPath: legacyPath) {
                logger.info("🧹 [Migration] Found legacy bundle to clean up: \(legacyPath)")
                
                do {
                    try fileManager.removeItem(atPath: legacyPath)
                    logger.info("✅ [Migration] Removed legacy bundle: \(legacyName)")
                } catch {
                    logger.warning("⚠️ [Migration] Could not remove legacy bundle: \(error.localizedDescription)")
                }
            }
        }
    }
}
