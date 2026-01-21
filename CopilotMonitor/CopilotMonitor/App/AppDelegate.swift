import AppKit
import SwiftUI
import Sparkle

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var loginWindow: NSWindow?
    var statusBarController: StatusBarController!
    private var sessionExpiredObserver: NSObjectProtocol?
    private var billingLoadedObserver: NSObjectProtocol?
    
    // Sparkle Updater Controller - 자동 업데이트 관리
    // XIB 없이 코드로 초기화해야 함 (Menu Bar 앱이므로)
    private(set) var updaterController: SPUStandardUpdaterController!
    
    @objc func checkForUpdates() {
        // Menu Bar apps (LSUIElement) need to be activated for Sparkle update UI to show
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(self)
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        
        statusBarController = StatusBarController()
        setupNotificationObservers()
        
        closeAllWindows()
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
        window.title = "GitHub 로그인"
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
        if let observer = sessionExpiredObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = billingLoadedObserver { NotificationCenter.default.removeObserver(observer) }
    }
}
