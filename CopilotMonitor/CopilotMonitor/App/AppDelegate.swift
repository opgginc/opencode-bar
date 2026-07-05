import AppKit
import Sparkle
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "AppDelegate")

// SwiftUI App lifecycle entry point: `@main struct ModernApp` (in
// `ModernApp.swift`) constructs this delegate via
// `@NSApplicationDelegateAdaptor`. The `MenuBarExtraAccess` bridge inside
// `ModernApp` calls `attachStatusItem(_:)` once SwiftUI has provisioned the
// underlying `NSSceneStatusItem`. We forward it to `StatusBarController`,
// queuing it if the controller has not been initialized yet (the bridge
// callback can fire before `applicationDidFinishLaunching` in some launch
// orderings).
class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    var statusBarController: StatusBarController!
    private(set) var updaterController: SPUStandardUpdaterController!

    // Bridge handoff: MenuBarExtraAccess calls this from ModernApp's body
    // evaluation. If `statusBarController` already exists (the normal case,
    // since `applicationDidFinishLaunching` runs first), we forward
    // directly. Otherwise we queue the item and drain the queue after the
    // controller is created in `applicationDidFinishLaunching`.
    private var pendingStatusItem: NSStatusItem?

    @objc func checkForUpdates() {
        logger.info("⌨️ [Keyboard] ⌘U Check for Updates triggered")
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(self)
    }

    @MainActor
    func attachStatusItem(_ statusItem: NSStatusItem) {
        if let controller = statusBarController {
            logger.info("🌉 [Bridge] attachStatusItem: forwarding to existing controller")
            controller.attachTo(statusItem)
            syncMenuToAllStatusWindows()
        } else {
            logger.info("🌉 [Bridge] attachStatusItem: controller not ready, queuing item")
            pendingStatusItem = statusItem
        }
    }

    /// After attaching the primary status item, also set our NSMenu on any
    /// other-display NSSceneStatusItems (replicants on macOS 26.x).
    /// Each display in Separate Spaces mode has its own NSStatusBarWindow;
    /// the bridge only calls the closure once for the first-matched item.
    ///
    /// Best-effort: we read `statusItem` via `Mirror` instead of KVC so a
    /// window that does not expose the private ivar does not trigger
    /// `valueForUndefinedKey:` (which raises NSException on macOS 26.x).
    /// Windows that don't have a statusItem ivar are simply skipped.
    @MainActor
    private func syncMenuToAllStatusWindows() {
        guard let controller = statusBarController,
              let primaryMenu = controller.menu,
              let primaryItem = controller.statusItem
        else { return }
        var attachedCount = 0
        for window in NSApp.windows {
            guard window.className.contains("NSStatusBarWindow") else { continue }
            guard let item = _safeStatusItem(from: window),
                  item !== primaryItem
            else { continue }
            item.menu = primaryMenu
            item.length = NSStatusItem.variableLength
            attachedCount += 1
        }
        if attachedCount > 0 {
            logger.info("🌉 [Bridge] syncMenuToAllStatusWindows: attached menu to \(attachedCount) secondary item(s)")
        }
    }

    /// Read `statusItem` from an `NSStatusBarWindow` via Swift reflection,
    /// avoiding the KVC `valueForKey:` path that can raise NSException on
    /// macOS 26.x when the private ivar is absent.
    @MainActor
    private func _safeStatusItem(from window: NSWindow) -> NSStatusItem? {
        Mirror(reflecting: window).descendant("statusItem") as? NSStatusItem
    }

    @MainActor
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
        statusBarController = StatusBarController(options: .production)
        closeAllWindows()

        // Drain the bridge queue if the bridge callback already fired
        // before the controller was constructed.
        if let pending = pendingStatusItem {
            logger.info("🌉 [Bridge] draining queued statusItem into controller")
            statusBarController?.attachTo(pending)
            pendingStatusItem = nil
        }
        syncMenuToAllStatusWindows()

        // B39: secondary display's NSSceneStatusItem may not exist yet at
        // launch. Wait a beat for SwiftUI's lazy scene creation, then retry.
        // Throttled: subsequent calls within 60s are skipped.
        scheduleResyncAfterLaunch()

        // Re-sync menu to all displays when display configuration changes
        // (second monitor hot-plug, screen arrangement changes, etc.)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reSyncMenu),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @MainActor
    @objc private func reSyncMenu() {
        // Throttle: do not log or re-run if we ran in the last 60 seconds.
        let now = Date()
        if let last = _lastResyncAt, now.timeIntervalSince(last) < 60 {
            return
        }
        _lastResyncAt = now
        logger.info("🌉 [Bridge] reSyncing menu after display parameter change")
        syncMenuToAllStatusWindows()
    }

    /// B39 timing: schedule a one-shot 1.0s resync after launch in case
    /// SwiftUI lazily created the secondary NSSceneStatusItem after our
    /// initial pass.
    @MainActor
    private func scheduleResyncAfterLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            // Only do work if the menu has actually been built (avoids
            // calling syncMenu while the controller is still warming up).
            guard self.statusBarController?.menu != nil else { return }
            self.syncMenuToAllStatusWindows()
        }
    }

    /// Tracks the last time `syncMenuToAllStatusWindows` ran, for throttling.
    private var _lastResyncAt: Date?
    
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
