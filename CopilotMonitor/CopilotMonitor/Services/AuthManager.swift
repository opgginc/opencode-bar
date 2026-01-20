import Foundation
import WebKit
import os.log

private let logger = Logger(subsystem: "com.copilotmonitor", category: "AuthManager")

@MainActor
final class AuthManager: NSObject {
    static let shared = AuthManager()
    
    private var _webView: WKWebView?
    var webView: WKWebView {
        logger.info("webView getter 호출됨")
        logger.info("_webView 상태: \(self._webView == nil ? "nil" : "존재")")
        if let view = _webView {
            logger.info("기존 webView 반환")
            return view
        }
        logger.info("setupWebView 호출 예정")
        setupWebView()
        logger.info("setupWebView 완료, _webView: \(self._webView == nil ? "nil" : "존재")")
        return _webView!
    }
    
    private var isCheckingLogin = false
    
    private let allowedDomains = [
        "github.com",
        "githubassets.com",
        "githubusercontent.com"
    ]
    
    private override init() {
        logger.info("init 시작")
        super.init()
        logger.info("init 완료")
    }
    
    private func setupWebView() {
        logger.info("setupWebView 시작")
        guard _webView == nil else {
            logger.info("setupWebView: 이미 webView 존재, 스킵")
            return
        }
        
        logger.info("WKWebViewConfiguration 생성")
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        
        logger.info("WKWebView 생성 중...")
        _webView = WKWebView(frame: .zero, configuration: config)
        logger.info("WKWebView 생성됨: \(String(describing: self._webView))")
        _webView?.navigationDelegate = self
        logger.info("navigationDelegate 설정 완료")
    }
    
    func loadBillingPage() {
        logger.info("loadBillingPage 호출됨, isCheckingLogin: \(self.isCheckingLogin)")
        guard !isCheckingLogin else {
            logger.info("loadBillingPage: 이미 체크 중, 스킵")
            return
        }
        isCheckingLogin = true
        
        // Copilot 사용량 상세 페이지로 직접 이동 (세션 갱신 및 컨텍스트 확보)
        let url = URL(string: "https://github.com/settings/billing/premium_requests_usage")!
        logger.info("loadBillingPage: URL 로드 시작 - \(url.absoluteString)")
        logger.info("loadBillingPage: webView 접근 직전")
        let wv = webView
        logger.info("loadBillingPage: webView 접근 완료")
        wv.load(URLRequest(url: url))
        logger.info("loadBillingPage: 로드 요청 완료")
    }
    
    func loadLoginPage() {
        logger.info("loadLoginPage 호출됨")
        let url = URL(string: "https://github.com/login")!
        logger.info("loadLoginPage: webView 접근 직전")
        let wv = webView
        logger.info("loadLoginPage: webView 접근 완료")
        wv.load(URLRequest(url: url))
        logger.info("loadLoginPage: 로드 요청 완료")
    }

    func resetSession() async {
        logger.info("resetSession 시작")
        let dataStore = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: types, modifiedSince: Date.distantPast) {
                continuation.resume()
            }
        }
        logger.info("resetSession 완료")
    }
}

extension AuthManager: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let loggerLocal = Logger(subsystem: "com.copilotmonitor", category: "AuthManager")
        loggerLocal.info("decidePolicyFor: \(url?.absoluteString ?? "nil")")
        guard let host = url?.host else {
            loggerLocal.info("decidePolicyFor: host 없음, cancel")
            decisionHandler(.cancel)
            return
        }
        
        let isAllowed = [
            "github.com",
            "githubassets.com",
            "githubusercontent.com"
        ].contains { host.hasSuffix($0) }
        loggerLocal.info("decidePolicyFor: host=\(host), allowed=\(isAllowed)")
        decisionHandler(isAllowed ? .allow : .cancel)
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        logger.info("didFinish: navigation=\(String(describing: navigation), privacy: .public)")
        let urlString = webView.url?.absoluteString ?? "nil"
        logger.info("didFinish: webView.url=\(urlString, privacy: .public)")
        isCheckingLogin = false
        
        guard let url = webView.url else {
            logger.info("didFinish: url이 nil")
            return
        }
        
        logger.info("didFinish: path=\(url.path, privacy: .public)")
        if url.path.contains("/login") || url.path.contains("/session") {
            logger.info("didFinish: 로그인 페이지 감지, sessionExpired 노티 발송")
            NotificationCenter.default.post(name: Notification.Name("sessionExpired"), object: nil)
            return
        }
        
        if url.path.contains("/settings/billing") {
            logger.info("didFinish: billing 페이지 감지, billingPageLoaded 노티 발송")
            NotificationCenter.default.post(name: Notification.Name("billingPageLoaded"), object: nil)
            return
        }
        
        // 대시보드(홈) 접근 시 Billing 페이지로 이동하여 customerId 확보
        if url.path == "/" {
            logger.info("didFinish: 대시보드 감지, Billing 페이지로 이동 (customerId 확보용)")
            loadBillingPage()
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        logger.error("didFail: error=\(error.localizedDescription)")
        isCheckingLogin = false
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        logger.error("didFailProvisionalNavigation: error=\(error.localizedDescription)")
        isCheckingLogin = false
    }
}
