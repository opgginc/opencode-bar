import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "OpenCodeGoProvider")

struct OpenCodeGoUsageWindow: Equatable {
    let usagePercent: Double
    let resetDate: Date?
}

struct OpenCodeGoUsage: Equatable {
    /// Single source of truth for the usage windows, in display order.
    /// The decode, the accessors, and the missing-window report all derive
    /// from this list. The diagnostic script mirrors it (see its fields map).
    static let orderedKeys = ["rolling", "weekly", "monthly"]

    let windows: [String: OpenCodeGoUsageWindow]

    var rolling: OpenCodeGoUsageWindow? { windows["rolling"] }
    var weekly: OpenCodeGoUsageWindow? { windows["weekly"] }
    var monthly: OpenCodeGoUsageWindow? { windows["monthly"] }

    var usagePercents: [Double] {
        Self.orderedKeys.compactMap { windows[$0]?.usagePercent }
    }

    var missingWindowNames: [String] {
        Self.orderedKeys.filter { windows[$0] == nil }
    }
}

private struct OpenCodeGoUsageAPIResponse: Decodable {
    struct Window: Decodable {
        let status: String?
        let percent: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case status
            case percent
            case resetsAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            percent = try container.decodeFlexibleDoubleIfPresent(forKey: .percent)
            resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt)
        }
    }

    let usage: [String: Window]
}

enum OpenCodeGoAPI {
    // Mirrored in scripts/query-opencode-go.sh (MODELS_URL/USAGE_API_URL).
    // Update both when the endpoint moves.
    static let modelsURL = URL(string: "https://opencode.ai/zen/go/v1/models")!
    static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    static let usageSourceLabel = "OpenCode Go API (zen/go/v1/usage)"
}

final class OpenCodeGoProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .openCodeGo
    let type: ProviderType = .quotaBased
    let fetchTimeout: TimeInterval = 15
    let minimumFetchInterval: TimeInterval = 60

    private let tokenManager: TokenManager
    private let session: URLSession
    private let apiKeyOverride: String?

    init(
        tokenManager: TokenManager = .shared,
        session: URLSession = .shared,
        apiKey: String? = nil
    ) {
        self.tokenManager = tokenManager
        self.session = session
        self.apiKeyOverride = apiKey
    }

    func fetch() async throws -> ProviderResult {
        logger.info("OpenCode Go fetch started")

        guard let apiKey = apiKeyOverride ?? tokenManager.getOpenCodeGoAPIKey() else {
            logger.error("OpenCode Go API key not found")
            throw ProviderError.authenticationFailed("OpenCode Go API key not available")
        }

        let modelCount = try await fetchModelCount(apiKey: apiKey)
        // The API error propagates with its classification intact so the
        // CLI keeps reporting authentication/network exit codes correctly.
        let usage = try await fetchUsageAPI(apiKey: apiKey)

        let missingWindowNames = usage.missingWindowNames
        if !missingWindowNames.isEmpty {
            logger.warning("OpenCode Go usage from \(OpenCodeGoAPI.usageSourceLabel, privacy: .public) missing window(s): \(missingWindowNames.joined(separator: ", "), privacy: .public)")
        }

        let overallUsed = usage.usagePercents.max() ?? 0
        let aggregateUsedPercent = UsagePercentDisplayFormatter.wholePercent(from: overallUsed)
        let remainingPercent = max(0, 100 - aggregateUsedPercent)

        let quotaUsage = ProviderUsage.quotaBased(
            remaining: remainingPercent,
            entitlement: 100,
            overagePermitted: false
        )

        let authPath = tokenManager.lastFoundAuthPath?.path ?? "~/.local/share/opencode/auth.json"
        let details = DetailedUsage(
            fiveHourUsage: usage.rolling?.usagePercent,
            fiveHourReset: usage.rolling?.resetDate,
            sevenDayUsage: usage.weekly?.usagePercent,
            sevenDayReset: usage.weekly?.resetDate,
            planType: "Go",
            openCodeGoMonthlyUsage: usage.monthly?.usagePercent,
            openCodeGoMonthlyReset: usage.monthly?.resetDate,
            openCodeGoModelCount: modelCount,
            authSource: authPath,
            authUsageSummary: OpenCodeGoAPI.usageSourceLabel
        )

        logger.info(
            "OpenCode Go usage fetched: 5h=\(usage.rolling?.usagePercent.description ?? "n/a", privacy: .public)%, weekly=\(usage.weekly?.usagePercent.description ?? "n/a", privacy: .public)%, monthly=\(usage.monthly?.usagePercent.description ?? "n/a", privacy: .public)%"
        )

        return ProviderResult(usage: quotaUsage, details: details)
    }

    static func parseUsageAPIJSON(_ data: Data) throws -> OpenCodeGoUsage {
        let response: OpenCodeGoUsageAPIResponse
        do {
            response = try JSONDecoder().decode(OpenCodeGoUsageAPIResponse.self, from: data)
        } catch {
            throw ProviderError.decodingError("Unexpected OpenCode Go usage response (\(error.localizedDescription))")
        }

        let windows = Dictionary(
            uniqueKeysWithValues: OpenCodeGoUsage.orderedKeys.compactMap { key in
                Self.apiWindow(key: key, response.usage[key]).map { (key, $0) }
            }
        )
        let usage = OpenCodeGoUsage(windows: windows)

        guard !usage.usagePercents.isEmpty else {
            throw ProviderError.decodingError(
                "OpenCode Go usage response contained no usage windows. Please report this issue."
            )
        }

        return usage
    }

    private static func authorizedRequest(url: URL, apiKey: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func fetchUsageAPI(apiKey: String) async throws -> OpenCodeGoUsage {
        let data = try await fetchData(request: Self.authorizedRequest(url: OpenCodeGoAPI.usageURL, apiKey: apiKey))
        return try Self.parseUsageAPIJSON(data)
    }

    private static func apiWindow(key: String, _ window: OpenCodeGoUsageAPIResponse.Window?) -> OpenCodeGoUsageWindow? {
        // Absent windows stay silent here; missingWindowNames reports them.
        guard let window else { return nil }
        if let status = window.status, status.lowercased() != "ok" {
            logger.warning("OpenCode Go usage window has non-ok status: \(key, privacy: .public) status=\(status, privacy: .public)")
            return nil
        }
        guard let percent = window.percent else {
            logger.warning("OpenCode Go usage window has no usable percent: \(key, privacy: .public)")
            return nil
        }
        let resetDate = window.resetsAt.flatMap(APIValueParser.parseDate(from:))
        if window.resetsAt != nil, resetDate == nil {
            logger.warning("OpenCode Go usage window has unparseable reset: \(key, privacy: .public)")
        }
        return OpenCodeGoUsageWindow(
            usagePercent: percent,
            resetDate: resetDate
        )
    }

    private func fetchModelCount(apiKey: String) async throws -> Int {
        let data = try await fetchData(request: Self.authorizedRequest(url: OpenCodeGoAPI.modelsURL, apiKey: apiKey))
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
