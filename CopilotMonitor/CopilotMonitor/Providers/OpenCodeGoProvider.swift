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
    private let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    private let usageSourceLabel = "OpenCode Go API (zen/go/v1/usage)"

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

        // The /workspace/<id>/go dashboard is now a JS SPA shell with no
        // server-rendered usage data, so usage comes from the key-based
        // usage API instead. No workspace ID, cookies, or extra setup needed.
        // API errors propagate with their classification intact.
        let dashboardUsage = try await fetchUsage(apiKey: apiKey)
        return try Self.makeResult(
            dashboardUsage: dashboardUsage,
            credentialSource: usageSourceLabel,
            modelCount: modelCount,
            tokenManager: tokenManager
        )
    }
    private static func makeResult(
        dashboardUsage: OpenCodeGoDashboardUsage,
        credentialSource: String,
        modelCount: Int,
        tokenManager: TokenManager
    ) throws -> ProviderResult {
        guard !dashboardUsage.usagePercents.isEmpty else {
            logger.error("OpenCode Go usage response missing usage windows")
            throw ProviderError.decodingError(
                "OpenCode Go usage response has no usage windows. Please report this issue."
            )
        }

        let missingWindowNames = dashboardUsage.missingWindowNames
        if !missingWindowNames.isEmpty {
            logger.warning("OpenCode Go usage missing window(s): \(missingWindowNames.joined(separator: ", "), privacy: .public)")
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

    // MARK: - Key-based usage API (current)

    /// Fetches `GET /zen/go/v1/usage` with the API-key from auth.json.
    /// Returns rolling (5h) / weekly / monthly windows with percent used
    /// and reset dates. Discovered via the console bundle (see also #154).
    private func fetchUsage(apiKey: String) async throws -> OpenCodeGoDashboardUsage {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await fetchData(request: request)
        return try Self.parseGoUsageAPI(data)
    }

    /// Parses `{"usage": {"rolling": {"percent": N, "resetsAt": ISO}, ...}}`.
    /// `percent` is already a percentage; `status` is informational.
    static func parseGoUsageAPI(_ data: Data, now: Date = Date()) throws -> OpenCodeGoDashboardUsage {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ProviderError.decodingError("Invalid OpenCode Go usage JSON: \(error.localizedDescription)")
        }
        guard let root = object as? [String: Any],
              let usage = root["usage"] as? [String: Any] else {
            throw ProviderError.decodingError("Unexpected OpenCode Go usage shape")
        }

        let parsed = OpenCodeGoDashboardUsage(
            rolling: parseUsageWindow(usage["rolling"], now: now),
            weekly: parseUsageWindow(usage["weekly"], now: now),
            monthly: parseUsageWindow(usage["monthly"], now: now)
        )

        guard !parsed.usagePercents.isEmpty else {
            throw ProviderError.decodingError("OpenCode Go usage has no usable windows")
        }
        return parsed
    }

    private static func parseUsageWindow(_ value: Any?, now: Date) -> OpenCodeGoUsageWindow? {
        guard let window = value as? [String: Any],
              let percent = doubleValue(window["percent"]) else {
            return nil
        }
        let resetDate = isoDate(window["resetsAt"] as? String) ?? now
        let resetInSeconds = max(0, Int(resetDate.timeIntervalSince(now).rounded()))
        return OpenCodeGoUsageWindow(usagePercent: percent, resetInSeconds: resetInSeconds, resetDate: resetDate)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func isoDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
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
