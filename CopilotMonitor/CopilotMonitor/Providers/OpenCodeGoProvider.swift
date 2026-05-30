import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "OpenCodeGoProvider")

struct OpenCodeGoUsageWindow: Equatable {
    let usagePercent: Double
    let resetInSeconds: Int
    let resetDate: Date
}

struct OpenCodeGoDashboardUsage: Equatable {
    let rolling: OpenCodeGoUsageWindow?
    let weekly: OpenCodeGoUsageWindow?
    let monthly: OpenCodeGoUsageWindow?

    var usagePercents: [Double] {
        [rolling?.usagePercent, weekly?.usagePercent, monthly?.usagePercent].compactMap { $0 }
    }

    var missingWindowNames: [String] {
        var names: [String] = []
        if rolling == nil { names.append("rollingUsage") }
        if weekly == nil { names.append("weeklyUsage") }
        if monthly == nil { names.append("monthlyUsage") }
        return names
    }
}

private struct OpenCodeGoDashboardCredentials {
    let workspaceID: String
    let authCookie: String
    let source: String
}

final class OpenCodeGoProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .openCodeGo
    let type: ProviderType = .quotaBased
    let fetchTimeout: TimeInterval = 15
    let minimumFetchInterval: TimeInterval = 60

    private let tokenManager: TokenManager
    private let session: URLSession
    private let modelsURL = URL(string: "https://opencode.ai/zen/go/v1/models")!

    init(tokenManager: TokenManager = .shared, session: URLSession = .shared) {
        self.tokenManager = tokenManager
        self.session = session
    }

    func fetch() async throws -> ProviderResult {
        logger.info("OpenCode Go fetch started")

        guard let apiKey = tokenManager.getOpenCodeGoAPIKey() else {
            logger.error("OpenCode Go API key not found")
            throw ProviderError.authenticationFailed("OpenCode Go API key not available")
        }

        let modelCount = try await fetchModelCount(apiKey: apiKey)

        let credentialCandidates = dashboardCredentialCandidates()
        guard !credentialCandidates.isEmpty else {
            logger.warning("OpenCode Go dashboard usage setup is incomplete")
            throw ProviderError.providerError(
                "OpenCode Go dashboard usage setup is incomplete. Log in to opencode.ai in Chrome/Brave/Arc/Edge, visit the Go dashboard once, or set OPENCODE_GO_WORKSPACE_ID and OPENCODE_GO_AUTH_COOKIE."
            )
        }

        let (dashboardUsage, credentialSource) = try await fetchFirstDashboardUsage(from: credentialCandidates)
        guard !dashboardUsage.usagePercents.isEmpty else {
            logger.error("OpenCode Go dashboard response missing usage windows")
            throw ProviderError.decodingError(
                "OpenCode Go dashboard markup may have changed. No usage windows were found. Please report this issue."
            )
        }

        let missingWindowNames = dashboardUsage.missingWindowNames
        if !missingWindowNames.isEmpty {
            logger.warning("OpenCode Go dashboard missing usage window(s): \(missingWindowNames.joined(separator: ", "), privacy: .public)")
        }

        let overallUsed = dashboardUsage.usagePercents.max() ?? 0
        let aggregateUsedPercent = UsagePercentDisplayFormatter.wholePercent(from: overallUsed)
        let remainingPercent = max(0, 100 - aggregateUsedPercent)

        let usage = ProviderUsage.quotaBased(
            remaining: remainingPercent,
            entitlement: 100,
            overagePermitted: false
        )

        let authPath = tokenManager.lastFoundAuthPath?.path ?? "~/.local/share/opencode/auth.json"
        let details = DetailedUsage(
            fiveHourUsage: dashboardUsage.rolling?.usagePercent,
            fiveHourReset: dashboardUsage.rolling?.resetDate,
            sevenDayUsage: dashboardUsage.weekly?.usagePercent,
            sevenDayReset: dashboardUsage.weekly?.resetDate,
            planType: "Go",
            openCodeGoMonthlyUsage: dashboardUsage.monthly?.usagePercent,
            openCodeGoMonthlyReset: dashboardUsage.monthly?.resetDate,
            openCodeGoModelCount: modelCount,
            authSource: authPath,
            authUsageSummary: credentialSource
        )

        logger.info(
            "OpenCode Go usage fetched: 5h=\(dashboardUsage.rolling?.usagePercent.description ?? "n/a", privacy: .public)%, weekly=\(dashboardUsage.weekly?.usagePercent.description ?? "n/a", privacy: .public)%, monthly=\(dashboardUsage.monthly?.usagePercent.description ?? "n/a", privacy: .public)%"
        )

        return ProviderResult(usage: usage, details: details)
    }

    static func parseDashboardUsageHTML(_ html: String, now: Date = Date()) throws -> OpenCodeGoDashboardUsage {
        let text = normalizedDashboardHTML(html)
        let usage = OpenCodeGoDashboardUsage(
            rolling: parseWindow(named: "rollingUsage", in: text, now: now),
            weekly: parseWindow(named: "weeklyUsage", in: text, now: now),
            monthly: parseWindow(named: "monthlyUsage", in: text, now: now)
        )

        guard !usage.usagePercents.isEmpty else {
            throw ProviderError.decodingError(
                "OpenCode Go dashboard markup may have changed. No usage windows were found. Please report this issue."
            )
        }

        return usage
    }

    private func fetchModelCount(apiKey: String) async throws -> Int {
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await fetchData(request: request)
        let object = try JSONSerialization.jsonObject(with: data)

        if let dictionary = object as? [String: Any] {
            if let dataArray = dictionary["data"] as? [Any] {
                return dataArray.count
            }
            if let modelsArray = dictionary["models"] as? [Any] {
                return modelsArray.count
            }
        }

        if let array = object as? [Any] {
            return array.count
        }

        throw ProviderError.decodingError("Unexpected OpenCode Go models response")
    }

    private func fetchDashboardUsage(credentials: OpenCodeGoDashboardCredentials) async throws -> OpenCodeGoDashboardUsage {
        guard let url = URL(string: "https://opencode.ai/workspace/\(credentials.workspaceID)/go") else {
            throw ProviderError.networkError("Invalid OpenCode Go workspace URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader(from: credentials.authCookie), forHTTPHeaderField: "Cookie")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let data = try await fetchData(request: request)
        guard let html = String(data: data, encoding: .utf8) else {
            throw ProviderError.decodingError("OpenCode Go dashboard response is not UTF-8")
        }

        return try Self.parseDashboardUsageHTML(html)
    }

    private func fetchFirstDashboardUsage(
        from candidates: [OpenCodeGoDashboardCredentials]
    ) async throws -> (OpenCodeGoDashboardUsage, String) {
        var lastError: Error?

        for credentials in candidates {
            do {
                let usage = try await fetchDashboardUsage(credentials: credentials)
                logger.info("OpenCode Go dashboard usage fetched from \(credentials.source, privacy: .public)")
                return (usage, credentials.source)
            } catch {
                lastError = error
                logger.warning("OpenCode Go dashboard candidate failed from \(credentials.source, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if let lastError {
            throw lastError
        }

        throw ProviderError.providerError("No OpenCode Go dashboard credential candidates available")
    }

    private func fetchData(request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderError.networkError("Invalid response from OpenCode Go")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let message = errorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    throw ProviderError.authenticationFailed(message)
                }
                throw ProviderError.networkError(message)
            }

            return data
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.networkError(error.localizedDescription)
        }
    }

    private func errorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = object["message"] as? String, !message.isEmpty {
                return message
            }
            if let error = object["error"] as? String, !error.isEmpty {
                return error
            }
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String,
               !message.isEmpty {
                return message
            }
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func dashboardCredentialCandidates() -> [OpenCodeGoDashboardCredentials] {
        var candidates: [OpenCodeGoDashboardCredentials] = []
        var seen: Set<String> = []

        func append(_ credentials: OpenCodeGoDashboardCredentials) {
            let key = "\(credentials.workspaceID)::\(credentials.authCookie)"
            guard !seen.contains(key) else { return }
            seen.insert(key)
            candidates.append(credentials)
        }

        let environment = ProcessInfo.processInfo.environment
        if let workspaceID = nonEmpty(environment["OPENCODE_GO_WORKSPACE_ID"]),
           let authCookie = nonEmpty(environment["OPENCODE_GO_AUTH_COOKIE"]) {
            append(OpenCodeGoDashboardCredentials(
                workspaceID: workspaceID,
                authCookie: authCookie,
                source: "Environment"
            ))
        }

        for url in dashboardConfigURLs(environment: environment) {
            guard let credentials = dashboardCredentials(from: url) else { continue }
            append(credentials)
        }

        browserDashboardCredentialCandidates().forEach { append($0) }

        return candidates
    }

    private func browserDashboardCredentialCandidates() -> [OpenCodeGoDashboardCredentials] {
        do {
            let cookies = try BrowserCookieService.shared.getCookies(hostSuffix: "opencode.ai", names: ["auth"])
            let historyEntries = try BrowserCookieService.shared.getHistoryEntries(
                hostSuffix: "opencode.ai",
                pathPrefix: "/workspace/",
                limit: 200
            )
            let cookiesByProfile = Dictionary(grouping: cookies, by: { $0.profileKey })
            var candidates: [OpenCodeGoDashboardCredentials] = []

            for entry in historyEntries {
                guard let workspaceID = Self.extractWorkspaceID(from: entry.url.absoluteString) else {
                    continue
                }

                let profileCookies = cookiesByProfile[entry.profileKey] ?? []
                let fallbackCookies = cookies.filter { $0.profileKey != entry.profileKey }

                for cookie in profileCookies + fallbackCookies {
                    candidates.append(OpenCodeGoDashboardCredentials(
                        workspaceID: workspaceID,
                        authCookie: cookie.value,
                        source: "Browser Cookies (\(cookie.displaySource))"
                    ))
                }
            }

            logger.info("OpenCode Go browser dashboard credential candidates: \(candidates.count)")
            return candidates
        } catch {
            logger.warning("OpenCode Go browser dashboard credential discovery failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    static func extractWorkspaceIDs(from urls: [String]) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"/workspace/(wrk_[A-Z0-9]+)"#) else {
            return []
        }

        var workspaceIDs: [String] = []
        var seen: Set<String> = []

        for url in urls {
            let range = NSRange(url.startIndex..<url.endIndex, in: url)
            guard let match = regex.firstMatch(in: url, options: [], range: range),
                  let valueRange = Range(match.range(at: 1), in: url) else {
                continue
            }
            let workspaceID = String(url[valueRange])
            guard !seen.contains(workspaceID) else { continue }
            seen.insert(workspaceID)
            workspaceIDs.append(workspaceID)
        }

        return workspaceIDs
    }

    private static func extractWorkspaceID(from url: String) -> String? {
        extractWorkspaceIDs(from: [url]).first
    }

    private func dashboardConfigURLs(environment: [String: String]) -> [URL] {
        var urls: [URL] = []

        if let override = nonEmpty(environment["OPENCODE_GO_CONFIG_FILE"]) {
            urls.append(URL(fileURLWithPath: NSString(string: override).expandingTildeInPath))
        }

        if let xdgConfigHome = nonEmpty(environment["XDG_CONFIG_HOME"]) {
            let base = URL(fileURLWithPath: NSString(string: xdgConfigHome).expandingTildeInPath)
            urls.append(base.appendingPathComponent("opencode-bar/opencode-go.json"))
            urls.append(base.appendingPathComponent("opencode-quota/opencode-go.json"))
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        urls.append(home.appendingPathComponent(".config/opencode-bar/opencode-go.json"))
        urls.append(home.appendingPathComponent(".config/opencode-quota/opencode-go.json"))
        urls.append(home.appendingPathComponent("Library/Application Support/opencode-bar/opencode-go.json"))
        urls.append(home.appendingPathComponent("Library/Application Support/opencode-quota/opencode-go.json"))

        return urls
    }

    private func dashboardCredentials(from url: URL) -> OpenCodeGoDashboardCredentials? {
        guard FileManager.default.isReadableFile(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workspaceID = nonEmptyString(from: object, keys: ["workspaceId", "workspaceID", "workspace_id"]),
              let authCookie = nonEmptyString(from: object, keys: ["authCookie", "auth_cookie", "cookie"]) else {
            return nil
        }

        return OpenCodeGoDashboardCredentials(
            workspaceID: workspaceID,
            authCookie: authCookie,
            source: url.path
        )
    }

    private func nonEmptyString(from object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String,
               let normalized = nonEmpty(value) {
                return normalized
            }
        }
        return nil
    }

    private func cookieHeader(from rawValue: String) -> String {
        if rawValue.contains("auth=") {
            return rawValue
        }
        return "auth=\(rawValue)"
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseWindow(named fieldName: String, in text: String, now: Date) -> OpenCodeGoUsageWindow? {
        guard let body = captureObjectBody(named: fieldName, in: text),
              let usagePercent = captureNumber(named: "usagePercent", in: body),
              let resetInSecondsDouble = captureNumber(named: "resetInSec", in: body) else {
            return nil
        }

        let resetInSeconds = max(0, Int(resetInSecondsDouble.rounded()))
        return OpenCodeGoUsageWindow(
            usagePercent: usagePercent,
            resetInSeconds: resetInSeconds,
            resetDate: now.addingTimeInterval(TimeInterval(resetInSeconds))
        )
    }

    private static func captureObjectBody(named fieldName: String, in text: String) -> String? {
        let pattern = #"["']?\#(NSRegularExpression.escapedPattern(for: fieldName))["']?\s*:\s*(?:\$R\[\d+\]\s*=\s*)?\{(?<body>[^{}]*)\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        let bodyRange = match.range(withName: "body")
        guard let swiftRange = Range(bodyRange, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }

    private static func captureNumber(named fieldName: String, in text: String) -> Double? {
        let pattern = #"["']?\#(NSRegularExpression.escapedPattern(for: fieldName))["']?\s*:\s*"?(-?\d+(?:\.\d+)?)"?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Double(text[valueRange])
    }

    private static func normalizedDashboardHTML(_ html: String) -> String {
        var text = html
        let replacements = [
            ("&quot;", "\""),
            ("&#34;", "\""),
            ("&#x27;", "'"),
            ("&#39;", "'"),
            ("&amp;", "&"),
            (#"\""#, "\""),
            (#"\u0022"#, "\"")
        ]
        for (encoded, decoded) in replacements {
            text = text.replacingOccurrences(of: encoded, with: decoded)
        }
        return text
    }
}
