import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "OpenCodeGoProvider")

struct OpenCodeGoUsageWindow: Equatable {
    let usagePercent: Double
    let resetInSeconds: Int
    let resetDate: Date?
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

final class OpenCodeGoProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .openCodeGo
    let type: ProviderType = .quotaBased
    let fetchTimeout: TimeInterval = 15
    let minimumFetchInterval: TimeInterval = 60

    private let tokenManager: TokenManager
    private let session: URLSession
    private let modelsURL = URL(string: "https://opencode.ai/zen/go/v1/models")!
    private let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

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

        // Usage comes from the key-based usage API. No workspace ID,
        // cookies, or extra setup needed.
        // API errors propagate with their classification intact.
        let dashboardUsage = try await fetchUsage(apiKey: apiKey)
        return try Self.makeResult(
            dashboardUsage: dashboardUsage,
            modelCount: modelCount,
            tokenManager: tokenManager
        )
    }
    private static func makeResult(
        dashboardUsage: OpenCodeGoDashboardUsage,
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
            authUsageSummary: "OpenCode Go API"
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
              let percent = APIValueParser.parseDouble(window["percent"]) else {
            return nil
        }
        // A missing/unparseable resetsAt stays nil so the menu shows no
        // reset row rather than a made-up reset time.
        let resetDate = APIValueParser.parseDate(from: window["resetsAt"] as? String)
        let resetInSeconds = resetDate.map { max(0, Int($0.timeIntervalSince(now).rounded())) } ?? 0
        return OpenCodeGoUsageWindow(usagePercent: percent, resetInSeconds: resetInSeconds, resetDate: resetDate)
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

}
