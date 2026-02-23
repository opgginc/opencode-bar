import Foundation
import os.log

private let braveSearchLogger = Logger(subsystem: "com.opencodeproviders", category: "BraveSearchProvider")

private struct BraveLocalState {
    var lastAPISyncAt: Date?
    var lastUsed: Int?
    var lastRemaining: Int?
    var lastLimit: Int?
    var lastResetSeconds: Int?
    var eventEstimatedUsed: Int
    var eventCursor: String?
    var eventMonth: String
    var eventLastScanAt: Date?
}

private struct BraveRateLimitSnapshot {
    let limit: Int?
    let remaining: Int?
    let resetSeconds: Int?
}

private struct BraveToolRecord {
    let path: String
    let monthKey: String?
    let isBraveSearchEvent: Bool
}

private struct BravePathScanResult {
    let paths: [String]
    let didHitProcessingLimit: Bool
}

private enum BraveModeLocal: Int {
    case eventOnly = 0
    case apiEverySixHours = 1
    case hybrid = 2

    var allowsAPISync: Bool {
        switch self {
        case .eventOnly:
            return false
        case .apiEverySixHours, .hybrid:
            return true
        }
    }

    var allowsEventCounting: Bool {
        switch self {
        case .eventOnly, .hybrid:
            return true
        case .apiEverySixHours:
            return false
        }
    }

    var title: String {
        switch self {
        case .eventOnly: return "Event-based only"
        case .apiEverySixHours: return "API sync every 6h"
        case .hybrid: return "Hybrid (event + 6h API)"
        }
    }
}

private enum BravePrefKey {
    static let refreshMode = "searchEngines.brave.refreshMode"
    static let lastApiSyncAt = "searchEngines.brave.lastApiSyncAt"
    static let lastUsed = "searchEngines.brave.lastUsed"
    static let lastRemaining = "searchEngines.brave.lastRemaining"
    static let lastLimit = "searchEngines.brave.lastLimit"
    static let lastResetSeconds = "searchEngines.brave.lastResetSeconds"
    static let eventEstimatedUsed = "searchEngines.brave.eventEstimatedUsed"
    static let eventCursor = "searchEngines.brave.eventCursor"
    static let eventMonth = "searchEngines.brave.eventMonth"
    static let eventLastScanAt = "searchEngines.brave.eventLastScanAt"
}

private func normalizedBraveQuotaUsagePercent(used: Int, limit: Int) -> Double? {
    guard limit > 0 else { return nil }
    let percent = (Double(used) / Double(limit)) * 100.0
    return min(max(percent, 0), 100)
}

final class BraveSearchProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .braveSearch
    let type: ProviderType = .quotaBased

    private let tokenManager: TokenManager
    private let session: URLSession
    private let fileManager = FileManager.default
    private let stateQueue = DispatchQueue(label: "com.opencodeproviders.BraveSearchProvider")
    private let sixHours: TimeInterval = 6 * 60 * 60
    private let defaultMonthlyLimit = 2000
    private let maxEventFilesPerScan = 1500

    init(tokenManager: TokenManager = .shared, session: URLSession = .shared) {
        self.tokenManager = tokenManager
        self.session = session
    }

    func fetch() async throws -> ProviderResult {
        guard let apiKey = tokenManager.getBraveSearchAPIKey() else {
            throw ProviderError.authenticationFailed("Brave Search API key not available")
        }

        let mode = currentRefreshMode()
        var state = stateQueue.sync { loadState() }
        state = normalizeMonth(for: state)

        if mode.allowsEventCounting {
            state = scanEventDelta(from: state)
        }

        if mode.allowsAPISync && shouldRunAPISync(lastSyncAt: state.lastAPISyncAt) {
            do {
                let snapshot = try await fetchRateLimitSnapshot(apiKey: apiKey)
                state = applyAPISnapshot(snapshot, to: state)
                braveSearchLogger.info("Brave Search API sync succeeded")
            } catch {
                braveSearchLogger.warning("Brave Search API sync failed: \(error.localizedDescription)")
            }
        }

        stateQueue.sync {
            saveState(state)
        }

        let limit = max(state.lastLimit ?? defaultMonthlyLimit, 1)
        let used: Int
        let remaining: Int

        if let apiRemaining = state.lastRemaining, let apiLimit = state.lastLimit, apiLimit > 0 {
            remaining = max(0, apiRemaining)
            used = max(0, apiLimit - remaining)
        } else {
            used = max(0, state.eventEstimatedUsed)
            remaining = max(0, limit - used)
        }

        let usage = ProviderUsage.quotaBased(remaining: remaining, entitlement: limit, overagePermitted: false)
        let mcpUsagePercent = normalizedBraveQuotaUsagePercent(used: used, limit: limit)
        let resetText = formatResetText(seconds: state.lastResetSeconds)
        let authSource = tokenManager.lastFoundOpenCodeConfigPath?.path ?? "~/.config/opencode/opencode.json"
        let sourceSummary = mode == .eventOnly ? "Estimated (event-based)" : "Mode: \(mode.title)"

        let details = DetailedUsage(
            monthlyUsage: Double(used),
            limit: Double(limit),
            limitRemaining: Double(remaining),
            resetPeriod: resetText,
            authSource: authSource,
            authUsageSummary: sourceSummary,
            mcpUsagePercent: mcpUsagePercent
        )

        let percentLogValue = mcpUsagePercent.map { String(format: "%.2f", $0) } ?? "nil"
        braveSearchLogger.info("Brave Search usage computed: mode=\(mode.title), used=\(used), limit=\(limit), usedPercent=\(percentLogValue)")

        return ProviderResult(usage: usage, details: details)
    }

    private func currentRefreshMode() -> BraveModeLocal {
        let raw = UserDefaults.standard.integer(forKey: BravePrefKey.refreshMode)
        return BraveModeLocal(rawValue: raw) ?? .eventOnly
    }

    private func shouldRunAPISync(lastSyncAt: Date?) -> Bool {
        guard let lastSyncAt else { return true }
        return Date().timeIntervalSince(lastSyncAt) >= sixHours
    }

    private func monthKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    private func normalizeMonth(for state: BraveLocalState) -> BraveLocalState {
        var mutable = state
        let currentMonth = monthKey(for: Date())
        if mutable.eventMonth != currentMonth {
            let previousMonth = mutable.eventMonth
            mutable.eventMonth = currentMonth
            mutable.eventEstimatedUsed = 0
            mutable.eventCursor = nil
            mutable.eventLastScanAt = nil
            braveSearchLogger.info("Brave Search month rollover: previousMonth=\(previousMonth), currentMonth=\(currentMonth), cursorCleared=true")
        }
        return mutable
    }

    private func loadState() -> BraveLocalState {
        let defaults = UserDefaults.standard
        let lastSyncEpoch = defaults.double(forKey: BravePrefKey.lastApiSyncAt)
        let lastSyncAt: Date? = lastSyncEpoch > 0 ? Date(timeIntervalSince1970: lastSyncEpoch) : nil

        let lastEventScanEpoch = defaults.double(forKey: BravePrefKey.eventLastScanAt)
        let lastEventScanAt: Date? = lastEventScanEpoch > 0 ? Date(timeIntervalSince1970: lastEventScanEpoch) : nil

        let eventMonth = defaults.string(forKey: BravePrefKey.eventMonth) ?? monthKey(for: Date())

        return BraveLocalState(
            lastAPISyncAt: lastSyncAt,
            lastUsed: defaults.object(forKey: BravePrefKey.lastUsed) as? Int,
            lastRemaining: defaults.object(forKey: BravePrefKey.lastRemaining) as? Int,
            lastLimit: defaults.object(forKey: BravePrefKey.lastLimit) as? Int,
            lastResetSeconds: defaults.object(forKey: BravePrefKey.lastResetSeconds) as? Int,
            eventEstimatedUsed: defaults.integer(forKey: BravePrefKey.eventEstimatedUsed),
            eventCursor: defaults.string(forKey: BravePrefKey.eventCursor),
            eventMonth: eventMonth,
            eventLastScanAt: lastEventScanAt
        )
    }

    private func saveState(_ state: BraveLocalState) {
        let defaults = UserDefaults.standard
        if let lastAPISyncAt = state.lastAPISyncAt {
            defaults.set(lastAPISyncAt.timeIntervalSince1970, forKey: BravePrefKey.lastApiSyncAt)
        }
        if let lastUsed = state.lastUsed {
            defaults.set(lastUsed, forKey: BravePrefKey.lastUsed)
        }
        if let lastRemaining = state.lastRemaining {
            defaults.set(lastRemaining, forKey: BravePrefKey.lastRemaining)
        }
        if let lastLimit = state.lastLimit {
            defaults.set(lastLimit, forKey: BravePrefKey.lastLimit)
        }
        if let lastResetSeconds = state.lastResetSeconds {
            defaults.set(lastResetSeconds, forKey: BravePrefKey.lastResetSeconds)
        }
        if let eventLastScanAt = state.eventLastScanAt {
            defaults.set(eventLastScanAt.timeIntervalSince1970, forKey: BravePrefKey.eventLastScanAt)
        }
        defaults.set(state.eventEstimatedUsed, forKey: BravePrefKey.eventEstimatedUsed)
        if let cursor = state.eventCursor {
            defaults.set(cursor, forKey: BravePrefKey.eventCursor)
        } else {
            defaults.removeObject(forKey: BravePrefKey.eventCursor)
        }
        defaults.set(state.eventMonth, forKey: BravePrefKey.eventMonth)
    }

    private func scanEventDelta(from state: BraveLocalState) -> BraveLocalState {
        var mutable = state
        let processingLimit = maxEventFilesPerScan
        let scanStartedAt = Date()
        let scanResult = collectNewPartJSONPaths(after: mutable.eventCursor, modifiedAfter: mutable.eventLastScanAt)
        let jsonPaths = scanResult.paths
        guard !jsonPaths.isEmpty else {
            mutable.eventLastScanAt = scanStartedAt
            return mutable
        }

        var newestCursor = mutable.eventCursor
        var incrementCount = 0

        for path in jsonPaths {
            guard let record = readBraveToolRecord(at: path) else {
                newestCursor = path
                continue
            }

            newestCursor = record.path
            if record.isBraveSearchEvent, record.monthKey == mutable.eventMonth {
                incrementCount += 1
            }
        }

        mutable.eventCursor = newestCursor
        if !scanResult.didHitProcessingLimit {
            mutable.eventLastScanAt = scanStartedAt
        }
        if incrementCount > 0 {
            mutable.eventEstimatedUsed += incrementCount
            braveSearchLogger.info("Brave Search event counter +\(incrementCount), total=\(mutable.eventEstimatedUsed)")
        }

        if scanResult.didHitProcessingLimit {
            braveSearchLogger.warning("Brave Search event scan reached file processing limit (\(processingLimit)); remaining files will be processed on the next refresh")
        }

        return mutable
    }

    private func collectNewPartJSONPaths(after cursor: String?, modifiedAfter: Date?) -> BravePathScanResult {
        var paths: [String] = []
        for root in storagePartDirectories() {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension.lowercased() == "json" else { continue }

                let filePath = fileURL.path
                if let cursor, filePath <= cursor {
                    continue
                }

                if let modifiedAfter,
                   let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                   let modifiedAt = resourceValues.contentModificationDate,
                   modifiedAt <= modifiedAfter {
                    continue
                }

                paths.append(filePath)
            }
        }

        paths.sort()
        if paths.count > maxEventFilesPerScan {
            let limitedPaths = Array(paths.prefix(maxEventFilesPerScan))
            return BravePathScanResult(paths: limitedPaths, didHitProcessingLimit: true)
        }
        return BravePathScanResult(paths: paths, didHitProcessingLimit: false)
    }

    private func storagePartDirectories() -> [URL] {
        let homeDir = fileManager.homeDirectoryForCurrentUser
        var roots: [URL] = []

        if let xdgDataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdgDataHome.isEmpty {
            roots.append(
                URL(fileURLWithPath: xdgDataHome)
                    .appendingPathComponent("opencode")
                    .appendingPathComponent("storage")
                    .appendingPathComponent("part")
            )
        }

        roots.append(
            homeDir
                .appendingPathComponent(".local")
                .appendingPathComponent("share")
                .appendingPathComponent("opencode")
                .appendingPathComponent("storage")
                .appendingPathComponent("part")
        )

        roots.append(
            homeDir
                .appendingPathComponent("Library")
                .appendingPathComponent("Application Support")
                .appendingPathComponent("opencode")
                .appendingPathComponent("storage")
                .appendingPathComponent("part")
        )

        var deduped: [URL] = []
        var visited = Set<String>()
        for root in roots {
            let normalized = root.standardizedFileURL.path
            if visited.insert(normalized).inserted {
                deduped.append(root)
            }
        }
        return deduped
    }

    private func readBraveToolRecord(at path: String) -> BraveToolRecord? {
        guard let data = fileManager.contents(atPath: path) else { return nil }
        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            braveSearchLogger.warning("Failed to decode Brave tool record at path=\(path): \(error.localizedDescription)")
            return nil
        }

        guard let json = jsonObject as? [String: Any] else {
            braveSearchLogger.warning("Failed to decode Brave tool record at path=\(path): unexpected JSON root type")
            return nil
        }

        let type = json["type"] as? String
        guard type == "tool" else {
            return BraveToolRecord(path: path, monthKey: nil, isBraveSearchEvent: false)
        }

        let toolName = json["tool"] as? String ?? ""
        let state = json["state"] as? [String: Any]
        let status = state?["status"] as? String ?? ""
        let isBrave = status == "completed" && toolName.hasPrefix("brave-search_")

        let time = state?["time"] as? [String: Any]
        var month: String?
        if let start = time?["start"] as? Double {
            month = monthKey(for: Date(timeIntervalSince1970: start / 1000.0))
        } else if let startInt = time?["start"] as? Int64 {
            month = monthKey(for: Date(timeIntervalSince1970: TimeInterval(startInt) / 1000.0))
        } else if let startInt = time?["start"] as? Int {
            month = monthKey(for: Date(timeIntervalSince1970: TimeInterval(startInt) / 1000.0))
        }

        return BraveToolRecord(path: path, monthKey: month, isBraveSearchEvent: isBrave)
    }

    private func applyAPISnapshot(_ snapshot: BraveRateLimitSnapshot, to state: BraveLocalState) -> BraveLocalState {
        var mutable = state
        mutable.lastAPISyncAt = Date()

        if let limit = snapshot.limit {
            mutable.lastLimit = limit
        }
        if let remaining = snapshot.remaining {
            mutable.lastRemaining = remaining
        }
        if let resetSeconds = snapshot.resetSeconds {
            mutable.lastResetSeconds = resetSeconds
        }

        if let limit = mutable.lastLimit, let remaining = mutable.lastRemaining {
            let used = max(0, limit - remaining)
            mutable.lastUsed = used
            mutable.eventEstimatedUsed = used
            mutable.eventMonth = monthKey(for: Date())
        }

        return mutable
    }

    private func fetchRateLimitSnapshot(apiKey: String) async throws -> BraveRateLimitSnapshot {
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: "opencode"),
            URLQueryItem(name: "count", value: "1")
        ]

        guard let url = components?.url else {
            throw ProviderError.networkError("Invalid Brave Search endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid Brave Search response type")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw ProviderError.authenticationFailed("Invalid Brave Search API key")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }

        let limits = parseCSVInts(httpResponse.value(forHTTPHeaderField: "X-RateLimit-Limit"))
        let remainings = parseCSVInts(httpResponse.value(forHTTPHeaderField: "X-RateLimit-Remaining"))
        let resets = parseCSVInts(httpResponse.value(forHTTPHeaderField: "X-RateLimit-Reset"))
        let policyWindows = parsePolicyWindows(httpResponse.value(forHTTPHeaderField: "X-RateLimit-Policy"))

        let index = preferredWindowIndex(policyWindows: policyWindows, limits: limits, remainings: remainings)

        return BraveRateLimitSnapshot(
            limit: value(at: index, in: limits),
            remaining: value(at: index, in: remainings),
            resetSeconds: value(at: index, in: resets)
        )
    }

    private func preferredWindowIndex(policyWindows: [Int], limits: [Int], remainings: [Int]) -> Int {
        if !policyWindows.isEmpty,
           let maxWindow = policyWindows.max(),
           let idx = policyWindows.firstIndex(of: maxWindow) {
            return idx
        }

        let fallbackCount = max(limits.count, remainings.count)
        return max(0, fallbackCount - 1)
    }

    private func value(at index: Int, in array: [Int]) -> Int? {
        guard index >= 0, index < array.count else { return nil }
        return array[index]
    }

    private func parseCSVInts(_ value: String?) -> [Int] {
        guard let value else { return [] }
        return value
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func parsePolicyWindows(_ value: String?) -> [Int] {
        guard let value else { return [] }
        return value
            .split(separator: ",")
            .compactMap { segment in
                let parts = segment.split(separator: ";")
                for part in parts {
                    let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("w=") {
                        return Int(trimmed.dropFirst(2))
                    }
                }
                return nil
            }
    }

    private func formatResetText(seconds: Int?) -> String? {
        guard let seconds else { return nil }
        let resetDate: Date
        if seconds >= 1_000_000_000 {
            resetDate = Date(timeIntervalSince1970: TimeInterval(seconds))
        } else {
            resetDate = Date().addingTimeInterval(TimeInterval(seconds))
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm z"
        formatter.timeZone = TimeZone.current
        return "Resets: \(formatter.string(from: resetDate))"
    }
}
