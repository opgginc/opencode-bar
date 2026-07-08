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

    // F2b: drives the 30s tick (extract → store → recompute month aggregates).
    // Started from `applicationDidFinishLaunching` after the controller is up
    // so the UI can read monthly totals via the cached accessor.
    private var refreshActor: RefreshActor?
    private var monthlyTotalsRefreshTask: Task<Void, Never>?

    // Bridge handoff: MenuBarExtraAccess calls this from ModernApp's body
    // evaluation. If `statusBarController` already exists (the normal case,
    // since `applicationDidFinishLaunching` runs first), we forward
    // directly. Otherwise we queue the item and drain the queue after the
    // controller is created in `applicationDidFinishLaunching`.
    private var pendingStatusItem: NSStatusItem?

    // Workaround: `MenuBarExtraAccess`'s `observerSetup()` runs ONCE on first
    // `body` evaluation. If that evaluation happens *before* SwiftUI has put
    // the NSStatusBarWindow into `NSApp.windows`, the introspection silently
    // returns nil and the bridge closure is never called. We detect this by
    // polling: if `bridgeHasFired` is still false after a few seconds, we
    // attach the status item ourselves by scanning `NSApp.windows` directly.
    private var bridgeHasFired = false

    /// B39: testability hook counting how many times the progressive post-launch
    /// resync scheduler has been entered.
    private(set) var resyncAfterLaunchCallCount = 0

    @objc func checkForUpdates() {
        logger.info("⌨️ [Keyboard] ⌘U Check for Updates triggered")
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(self)
    }

    @MainActor
    func attachStatusItem(_ statusItem: NSStatusItem) {
        bridgeHasFired = true
        if let controller = statusBarController {
            logger.info("🌉 [Bridge] attachStatusItem: forwarding to existing controller")
            controller.attachTo(statusItem)
            syncMenuToAllStatusWindows()
            observePrimaryStatusItemForImageOverwrites()
            dumpStatusBarLandscape("after attachStatusItem")
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
    @discardableResult
    func syncMenuToAllStatusWindows() -> (barWindows: Int, attached: Int, skipped: Int) {
        guard let controller = statusBarController,
              let primaryMenu = controller.menu,
              let primaryItem = controller.statusItem
        else {
            logger.info("🌉 [Bridge] syncMenuToAllStatusWindows: deferred — controller/menu/primaryItem not ready")
            return (0, 0, 0)
        }
        var attachedCount = 0
        var skippedWithNoItem = 0
        let barWindows = NSApp.windows.filter { $0.className.contains("NSStatusBarWindow") }
        controller.debugLog("syncMenuToAllStatusWindows: \(barWindows.count) NSStatusBarWindow(s); primary=\(primaryItem)")
        if barWindows.count > 1 {
            logger.info("🌉 [Bridge] syncMenuToAllStatusWindows: \(barWindows.count) NSStatusBarWindow(s); primary=\(primaryItem)")
        }
        for window in barWindows {
            let safeItem = _safeStatusItem(from: window)
            if safeItem == nil {
                skippedWithNoItem += 1
                logger.info("🌉 [Bridge] sync: window frame=\(String(describing: window.frame)) - Mirror.descendant(\"statusItem\") returned nil")
                continue
            }
            guard let item = safeItem, item !== primaryItem else { continue }
            item.menu = primaryMenu
            item.length = NSStatusItem.variableLength
            controller.attachToSecondaryItem(item)
            attachedCount += 1
            logger.info("🌉 [Bridge] sync: attached menu + icon to item @ \(String(describing: window.frame)) (count=\(attachedCount))")
        }
        if attachedCount > 0 {
            logger.info("🌉 [Bridge] syncMenuToAllStatusWindows: attached menu to \(attachedCount) secondary item(s)")
        }
        if skippedWithNoItem > 0 && attachedCount == 0 {
            logger.warning("🌉 [Bridge] syncMenuToAllStatusWindows: \(skippedWithNoItem) secondary window(s) had no Mirror.statusItem")
        }
        controller.debugLog("syncMenuToAllStatusWindows: finished barWindows=\(barWindows.count) attached=\(attachedCount) skipped=\(skippedWithNoItem)")
        return (barWindows.count, attachedCount, skippedWithNoItem)
    }

    /// Read `statusItem` from an `NSStatusBarWindow` via Swift reflection,
    /// avoiding the KVC `valueForKey:` path that can raise NSException on
    /// macOS 26.x when the private ivar is absent. If Mirror also fails to
    /// find the ivar (e.g., the replicant window on a secondary display
    /// has a differently-named ivar), fall back to KVC and tolerate nil.
    @MainActor
    func _safeStatusItem(from window: NSWindow) -> NSStatusItem? {
        if let viaMirror = Mirror(reflecting: window).descendant("statusItem") as? NSStatusItem {
            return viaMirror
        }
        return window.value(forKey: "statusItem") as? NSStatusItem
    }

    /// Observability: log `controller.statusItem.button.image` setter calls
    /// to detect when SwiftUI label overrides our rendered bitmap. Pure KVO;
    /// no production behavior change. (B40 / OpenClaw "SwiftUI can vend a
    /// replacement status item during connection churn" hypothesis verification)
    private var _buttonImageKVOToken: NSKeyValueObservation?
    private var _buttonTitleKVOToken: NSKeyValueObservation?

    @MainActor
    private func observePrimaryStatusItemForImageOverwrites() {
        // Detach any previous observers before re-attaching (idempotent across
        // screen-configuration changes and our own item replacements).
        _buttonImageKVOToken?.invalidate()
        _buttonTitleKVOToken?.invalidate()

        guard let item = statusBarController?.statusItem, let button = item.button else {
            Self.observ("🔍 observability: no controller.statusItem.button yet — deferring KVO")
            return
        }
        let itemAddr = String(format: "%p", item)
        Self.observ("🔍 observability: attaching KVO to button.image / button.title on item=\(itemAddr)")

        _buttonImageKVOToken = button.observe(\.image, options: [.new]) { _, change in
            let desc = Self.describeImage(change.newValue ?? nil)
            Self.observ("🔍 KVO button.image → \(desc)")
        }

        _buttonTitleKVOToken = button.observe(\.title, options: [.new]) { button, _ in
            Self.observ("🔍 KVO button.title → \"\(button.title)\"")
        }
    }

    @MainActor
    private static func describeImage(_ image: NSImage?) -> String {
        guard let image = image else { return "nil" }
        if let bmp = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            return "NSBitmapImageRep pixels=\(bmp.pixelsWide)x\(bmp.pixelsHigh)"
        }
        if let sym = image.representations.first {
            return "rep=\(type(of: sym))"
        }
        return "empty"
    }

    /// Post-connect deep dump: capture who is alive right now.
    @MainActor
    private func dumpStatusBarLandscape(_ tag: String) {
        let screens = NSScreen.screens
        let wins = NSApp.windows.filter { $0.className.contains("NSStatusBarWindow") }
        var lines: [String] = []
        lines.append("🔍 DUMP[\(tag)] screens=\(screens.count) nsBarWindows=\(wins.count)")
        for (i, w) in wins.enumerated() {
            let screen = w.screen
            let screenName = screen?.localizedName ?? "?"
            let frame = w.frame
            let safeItem = _safeStatusItem(from: w)
            if let it = safeItem {
                let itemAddr = String(format: "%p", it)
                let btn = it.button
                let imgDesc = Self.describeImage(btn?.image)
                let menuCount = it.menu?.items.count ?? 0
                lines.append("🔍   win[\(i)] screen=\(screenName) frame=(x=\(frame.origin.x),y=\(frame.origin.y),w=\(frame.width),h=\(frame.height)) item=\(itemAddr) btn.image=\(imgDesc) menuItems=\(menuCount)")
            } else {
                lines.append("🔍   win[\(i)] screen=\(screenName) frame=(x=\(frame.origin.x),y=\(frame.origin.y),w=\(frame.width),h=\(frame.height)) - no item (Mirror.descendant and KVC both returned nil)")
            }
        }
        // File mirror — logger.info is unreadable in macOS 26.5 via `log show`.
        Self.writeObservability(lines: lines, tag: tag)
    }

    /// Standalone file writer for observability — survives the lifetime of the
    /// debug session independent of `logger.info` (unreadable on macOS 26.5).
    nonisolated static func writeObservability(lines: [String], tag: String) {
        let path = "/tmp/tk_observ.log"
        let text = lines.joined(separator: "\n") + "\n"
        if FileManager.default.fileExists(atPath: path) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(text.utf8))
                try? handle.close()
            }
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Convenience: one-line log; also goes to os.log via logger.info.
    nonisolated static func observ(_ msg: String) {
        Self.writeObservability(lines: [msg], tag: "log")
        Logger(subsystem: "com.opencodeproviders", category: "AppDelegate").info("\(msg, privacy: .public)")
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
            observePrimaryStatusItemForImageOverwrites()
            dumpStatusBarLandscape("after queue drain")
        }
        syncMenuToAllStatusWindows()

        // Workaround for the `MenuBarExtraAccess` race: bridge closure may
        // never fire if SwiftUI evaluated body before NSApp.windows contained
        // the NSStatusBarWindow. Poll until the bridge fires OR we attach
        // ourselves by finding the window directly.
        scheduleBridgeAttachRetry()

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

        // B39: also re-sync when a window moves to a different screen or the
        // machine wakes from sleep, both of which can introduce/remove
        // secondary NSSceneStatusItems.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reSyncMenu),
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(reSyncMenu),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // F2b: kick off the 30s RefreshActor tick + the UI snapshot loop that
        // pushes the latest month aggregates into the menu. Done after the
        // controller + status item are wired so the first snapshot can render
        // into the existing menu immediately.
        startRefreshActor()
    }

    /// F2b: construct and start the RefreshActor, share it with the controller,
    /// and run a periodic task that refreshes the controller's monthly-totals
    /// cache + rebuilds the menu.
    @MainActor
    private func startRefreshActor() {
        let store = TokenUsageStore()
        let actor = RefreshActor(store: store)
        refreshActor = actor
        // Hand the actor to the controller so `monthlyCostRMB(for:)` and the
        // "本月 API 折算" menu section read the same instance we are ticking.
        statusBarController?.refreshActor = actor
        // F1 / F4: hand the same `TokenUsageStore` to the controller so its
        // "本月 Token" header and "全局统计" submenu read from the store the
        // actor is ticking.
        statusBarController?.tokenUsageStore = store

        if actor.initError == nil {
            Task { await actor.start() }
        } else {
            logger.error("🔄 [F2b] RefreshActor store failed to initialize: \(String(describing: actor.initError), privacy: .public); tick will not start")
        }

        // Periodic snapshot loop: pulls the latest month aggregates into the
        // controller's cache (populated by `refreshMonthlyTotalsCache`) so the
        // menu can render them synchronously.
        monthlyTotalsRefreshTask?.cancel()
        monthlyTotalsRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.statusBarController?.refreshMonthlyTotalsCache()
                await self?.statusBarController?.refreshTokenStatsCache()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        // Prime the cache immediately so a store init error is reflected in the
        // menu without waiting for the first 5 s loop iteration.
        Task { await statusBarController?.refreshMonthlyTotalsCache() }
        Task { await statusBarController?.refreshTokenStatsCache() }
        logger.info("🔄 [F2b] RefreshActor started; monthly totals refresh loop scheduled")
    }

    @MainActor
    @objc private func reSyncMenu() {
        // Throttle: do not log or re-run if we ran in the last 60 seconds.
        let now = Date()
        if let last = _lastResyncAt, now.timeIntervalSince(last) < 60 {
            logger.info("🌉 [Bridge] reSyncMenu: throttled (\(Int(now.timeIntervalSince(last)))s since last)")
            return
        }
        _lastResyncAt = now
        logger.info("🌉 [Bridge] reSyncMenu fired from NSApplication.didChangeScreenParametersNotification")
        dumpStatusBarLandscape("reSyncMenu entry")
        syncMenuToAllStatusWindows()
        // Re-attach KVO in case the primary item was swapped
        observePrimaryStatusItemForImageOverwrites()
        dumpStatusBarLandscape("reSyncMenu exit")
    }

    /// B39 timing: schedule progressive resyncs at 1s, 3s and 10s after launch
    /// in case SwiftUI lazily creates secondary NSSceneStatusItems after our
    /// initial pass.
    @MainActor
    func scheduleResyncAfterLaunch() {
        resyncAfterLaunchCallCount += 1
        let delays: [TimeInterval] = [1.0, 3.0, 10.0]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                // Only do work if the menu has actually been built (avoids
                // calling syncMenu while the controller is still warming up).
                guard self.statusBarController?.menu != nil else { return }
                logger.info("🌉 [Bridge] scheduleResyncAfterLaunch: firing progressive retry at +\(delay)s")
                self.syncMenuToAllStatusWindows()
            }
        }
    }

    /// Workaround for `MenuBarExtraAccess` bridge race. The bridge closure
    /// `statusItem: { ... }` only ever fires when observerSetup() is invoked
    /// with a non-empty `MenuBarExtraUtils.statusItems` list. If body was
    /// evaluated before that list had anything in it, observerSetup returns
    /// silently and the closure never runs.
    ///
    /// We poll for up to ~15.8s (cumulative) at increasing intervals. At
    /// each tick we check whether the bridge already fired; if so, stop. If
    /// not, we scan `NSApp.windows` for an `NSStatusBarWindow` and pull the
    /// `statusItem` ivar out via `Mirror` (KVC `value(forKey: "statusItem")`
    /// crashes on macOS 26.5) and feed it to `attachStatusItem(_:)`.
    ///
    /// Idempotent: if the bridge eventually fires too, attachStatusItem is
    /// called again with the same item and the controller just re-resolves.
    @MainActor
    private func scheduleBridgeAttachRetry() {
        Task { @MainActor [weak self] in
            logger.info("🌉 [Bridge] scheduleBridgeAttachRetry: starting poll loop")
            let intervals: [Double] = [0.3, 0.5, 1.0, 2.0, 3.0, 4.0, 5.0]
            for delay in intervals {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(delay))
                if self.bridgeHasFired {
                    logger.info("🌉 [Bridge] retry: bridge fired before \(delay)s, exiting")
                    return
                }
                let barWindows = NSApp.windows.filter { $0.className.contains("NSStatusBarWindow") }
                logger.info("🌉 [Bridge] retry +\(delay)s: NSApp.windows has \(barWindows.count) NSStatusBarWindow(s) to consider")
                for window in barWindows {
                    let viaMirror = Mirror(reflecting: window).descendant("statusItem") as? NSStatusItem
                    let viaKVC = window.value(forKey: "statusItem") as? NSStatusItem
                    if let item = viaMirror ?? viaKVC {
                        logger.info("🌉 [Bridge] retry +\(delay)s: bridge didn't fire, attaching manually (mirror=\(viaMirror != nil) kvc=\(viaKVC != nil))")
                        self.attachStatusItem(item)
                        return
                    }
                }
            }
            logger.warning("🌉 [Bridge] retry gave up after \(intervals.reduce(0, +))s; bridge never fired and we couldn't find NSStatusBarWindow")
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
