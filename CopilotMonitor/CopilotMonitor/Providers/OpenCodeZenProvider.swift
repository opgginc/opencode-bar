import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "OpenCodeZenProvider")

private func debugLog(_ message: String) {
    let msg = "[\(Date())] OpenCodeZen: \(message)\n"
    if let data = msg.data(using: .utf8) {
        let path = "/tmp/opencode_debug.log"
        if FileManager.default.fileExists(atPath: path) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// Notification sent when OpenCode Zen history is updated during progressive loading
extension Notification.Name {
    static let openCodeZenHistoryUpdated = Notification.Name("openCodeZenHistoryUpdated")
}

/// Provider for OpenCode Zen usage tracking via CLI stats
/// Uses pay-as-you-go billing model with cost-based tracking
/// Implements progressive loading: fetches days 1-30 sequentially with real-time UI updates
final class OpenCodeZenProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .openCodeZen
    let type: ProviderType = .payAsYouGo
    let fetchTimeout: TimeInterval = 60.0

    // MARK: - Singleton for state management

    /// Shared instance for accessing loading state
    static let shared = OpenCodeZenProvider()

    /// Current loading state for UI display
    struct LoadingState {
        var isLoading: Bool = false
        var currentDay: Int = 0
        var totalDays: Int = 30
        var dailyHistory: [DailyUsage] = []
        var lastError: String?
    }

    /// Thread-safe access to loading state
    private static var _loadingState = LoadingState()
    private static let stateLock = NSLock()

    static var loadingState: LoadingState {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _loadingState
        }
        set {
            stateLock.lock()
            _loadingState = newValue
            stateLock.unlock()
        }
    }

    // MARK: - Configuration

    /// Path to opencode CLI binary (lazily resolved)
    private lazy var opencodePath: URL? = {
        findOpenCodeBinary()
    }()
    
    /// Cached description of where the binary was found
    private var binarySourceDescription: String = "unknown"
    
    /// Finds opencode binary using multiple strategies:
    /// 1. Try "opencode" command directly via PATH (user's current environment)
    /// 2. Try "opencode" via login shell PATH (captures shell profile additions)
    /// 3. Fallback to common hardcoded paths
    private func findOpenCodeBinary() -> URL? {
        logger.info("OpenCodeZen: Searching for opencode binary...")
        debugLog("Starting opencode binary search")
        
        // Strategy 1: Try "which opencode" in current environment
        if let path = findBinaryViaWhich() {
            logger.info("OpenCodeZen: Found via 'which': \(path.path)")
            debugLog("Found via 'which': \(path.path)")
            binarySourceDescription = "PATH (\(path.path))"
            return path
        }
        
        // Strategy 2: Try via login shell to get user's full PATH
        if let path = findBinaryViaLoginShell() {
            logger.info("OpenCodeZen: Found via login shell: \(path.path)")
            debugLog("Found via login shell: \(path.path)")
            binarySourceDescription = "login shell PATH (\(path.path))"
            return path
        }
        
        // Strategy 3: Hardcoded fallback paths
        let fallbackPaths = [
            "/opt/homebrew/bin/opencode",           // Apple Silicon Homebrew
            "/usr/local/bin/opencode",              // Intel Homebrew
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opencode/bin/opencode").path,  // OpenCode default
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/opencode").path,     // pip/pipx
            "/usr/bin/opencode"                     // System-wide
        ]
        
        for path in fallbackPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                logger.info("OpenCodeZen: Found via fallback path: \(path)")
                debugLog("Found via fallback: \(path)")
                binarySourceDescription = "fallback (\(path))"
                return url
            }
        }
        
        logger.error("OpenCodeZen: Binary not found in any location")
        debugLog("Binary not found anywhere")
        return nil
    }
    
    /// Finds opencode binary using `which` command in current environment
    private func findBinaryViaWhich() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["opencode"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else { return nil }
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { return nil }
            
            let url = URL(fileURLWithPath: output)
            guard FileManager.default.fileExists(atPath: output) else { return nil }
            
            return url
        } catch {
            debugLog("'which opencode' failed: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Finds opencode binary using login shell to capture user's full PATH
    /// This is important because GUI apps don't inherit terminal PATH modifications
    private func findBinaryViaLoginShell() -> URL? {
        // Determine user's default shell
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Use -l for login shell (loads profile), -c to execute command
        process.arguments = ["-lc", "which opencode 2>/dev/null"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else { return nil }
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { return nil }
            
            let url = URL(fileURLWithPath: output)
            guard FileManager.default.fileExists(atPath: output) else { return nil }
            
            return url
        } catch {
            debugLog("Login shell 'which opencode' failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Data Structures

    /// Parsed statistics from opencode stats command
    private struct OpenCodeStats {
        let totalCost: Double
        let avgCostPerDay: Double
        let sessions: Int
        let messages: Int
        let modelCosts: [String: Double]
    }

    /// Cache structure for daily history
    private struct DailyHistoryCache: Codable {
        let date: Date
        let cost: Double
        let cumulativeCost: Double  // Cumulative cost up to this day
        let fetchedAt: Date
    }

    private let cacheKey = "opencodezen.dailyhistory.cache.v2"

    // MARK: - ProviderProtocol

    func fetch() async throws -> ProviderResult {
        guard let binaryPath = opencodePath else {
            logger.error("OpenCode CLI not found in PATH or standard locations")
            throw ProviderError.providerError("OpenCode CLI not found. Install via: brew install opencode, or ensure 'opencode' is in PATH")
        }
        
        guard FileManager.default.fileExists(atPath: binaryPath.path) else {
            logger.error("OpenCode CLI binary not accessible at \(binaryPath.path)")
            throw ProviderError.providerError("OpenCode CLI not accessible at \(binaryPath.path)")
        }

        let cachedHistory = loadDailyHistoryFromCache()
        
        var stats: OpenCodeStats? = nil
        var statsFetchError: Error? = nil
        
        do {
            let output = try await runOpenCodeStats(days: 7)
            stats = try parseStats(output)
            debugLog("Stats fetch succeeded: totalCost=$\(stats?.totalCost ?? 0)")
        } catch {
            statsFetchError = error
            logger.warning("Failed to fetch current stats: \(error.localizedDescription)")
            debugLog("Stats fetch failed: \(error.localizedDescription), will use cache fallback")
        }

        if !OpenCodeZenProvider.loadingState.isLoading {
            Task.detached { [weak self] in
                await self?.fetchDailyHistoryProgressively()
            }
        } else {
            debugLog("Progressive loading already in progress, skipping")
        }
        
        let totalCost: Double
        let modelCosts: [String: Double]
        let sessions: Int
        let messages: Int
        let avgCostPerDay: Double
        
        if let stats = stats {
            totalCost = stats.totalCost
            modelCosts = stats.modelCosts
            sessions = stats.sessions
            messages = stats.messages
            avgCostPerDay = stats.avgCostPerDay
        } else {
            totalCost = calculateTotalCostFromCache(cachedHistory, days: 7)
            modelCosts = [:]
            sessions = 0
            messages = 0
            avgCostPerDay = cachedHistory.isEmpty ? 0 : totalCost / Double(min(7, cachedHistory.count))
            debugLog("Using cache fallback: totalCost=$\(totalCost) from \(cachedHistory.count) cached days")
        }

        let monthlyLimit = 1000.0
        let utilization = min((totalCost / monthlyLimit) * 100, 100)

        logger.info("OpenCode Zen: $\(String(format: "%.2f", totalCost)) (\(String(format: "%.1f", utilization))% of $\(monthlyLimit) limit)")

        var authSource = "opencode CLI via \(binarySourceDescription)"
        if statsFetchError != nil {
            authSource += " [stats: cached]"
        }
        
        let details = DetailedUsage(
            modelBreakdown: modelCosts,
            sessions: sessions > 0 ? sessions : nil,
            messages: messages > 0 ? messages : nil,
            avgCostPerDay: avgCostPerDay > 0 ? avgCostPerDay : nil,
            dailyHistory: cachedHistory,
            monthlyCost: totalCost,
            authSource: authSource
        )

        return ProviderResult(
            usage: .payAsYouGo(utilization: utilization, cost: totalCost, resetsAt: nil),
            details: details
        )
    }
    
    private func calculateTotalCostFromCache(_ history: [DailyUsage], days: Int) -> Double {
        let recentDays = history.sorted { $0.date > $1.date }.prefix(days)
        return recentDays.reduce(0) { $0 + $1.billedAmount }
    }

    // MARK: - Progressive Daily History Loading

    /// Fetches daily history progressively (day 1 → day 2 → ... → day 30)
    /// Updates UI in real-time via NotificationCenter
    private func fetchDailyHistoryProgressively() async {
        // Set loading state BEFORE cleanup to prevent race condition
        // Multiple threads may pass the isLoading check simultaneously,
        // so we mark as loading first to block subsequent fetch attempts
        OpenCodeZenProvider.loadingState = LoadingState(
            isLoading: true,
            currentDay: 0,
            totalDays: 30,
            dailyHistory: [],
            lastError: nil
        )

        killExistingOpenCodeProcesses()

        // Use UTC calendar to match cache dates which are stored in UTC
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(abbreviation: "UTC") ?? TimeZone.current
        let today = calendar.startOfDay(for: Date())

        // Load existing cache
        var cache = loadHistoryCache()
        var cumulativeCosts: [Int: Double] = [:]  // day -> cumulative cost
        var dailyHistory: [DailyUsage] = []

        // Check which days need fetching (cache older than 1 hour needs refresh)
        let cacheValidThreshold = Date().addingTimeInterval(-3600)  // 1 hour

        logger.info("OpenCodeZen: Starting progressive fetch for 30 days")
        debugLog("Starting progressive fetch for 30 days")
        debugLog("Cache loaded: \(cache.count) items, threshold: \(cacheValidThreshold)")

        // Fetch days 1-30 sequentially
        for day in 1...30 {
            OpenCodeZenProvider.loadingState.currentDay = day

            guard let targetDate = calendar.date(byAdding: .day, value: -(day - 1), to: today) else {
                continue
            }
            let dateStart = calendar.startOfDay(for: targetDate)

            // Check cache for this specific day
            if let cached = cache.first(where: {
                calendar.isDate(calendar.startOfDay(for: $0.date), inSameDayAs: dateStart) &&
                $0.fetchedAt > cacheValidThreshold
            }) {
                // Use cached value
                cumulativeCosts[day] = cached.cumulativeCost
                let dailyCost = day == 1 ? cached.cumulativeCost : max(0, cached.cumulativeCost - (cumulativeCosts[day - 1] ?? 0))

                dailyHistory.append(DailyUsage(
                    date: targetDate,
                    includedRequests: 0,
                    billedRequests: 0,
                    grossAmount: dailyCost,
                    billedAmount: dailyCost
                ))

                debugLog("Day \(day): $\(String(format: "%.2f", dailyCost)) (cached)")
                logger.debug("Day \(day): $\(String(format: "%.2f", dailyCost)) (cached)")
            } else {
                do {
                    let output = try await runOpenCodeStatsWithRetry(days: day)
                    if let cumulativeCost = parseTotalCost(output) {
                        cumulativeCosts[day] = cumulativeCost

                        let previousCumulative = cumulativeCosts[day - 1] ?? 0
                        let dailyCost = max(0, cumulativeCost - previousCumulative)

                        cache.removeAll { calendar.isDate(calendar.startOfDay(for: $0.date), inSameDayAs: dateStart) }
                        cache.append(DailyHistoryCache(
                            date: dateStart,
                            cost: dailyCost,
                            cumulativeCost: cumulativeCost,
                            fetchedAt: Date()
                        ))

                        dailyHistory.append(DailyUsage(
                            date: targetDate,
                            includedRequests: 0,
                            billedRequests: 0,
                            grossAmount: dailyCost,
                            billedAmount: dailyCost
                        ))

                        logger.info("Day \(day): $\(String(format: "%.2f", dailyCost)) (cumulative: $\(String(format: "%.2f", cumulativeCost)))")
                        debugLog("Day \(day): $\(String(format: "%.2f", dailyCost)) fetched")
                    } else {
                        logger.warning("Day \(day): failed to parse cost from output")
                        debugLog("Day \(day): parse failed, skipping (no $0 placeholder)")
                        OpenCodeZenProvider.loadingState.lastError = "Day \(day): parse error"
                    }
                } catch {
                    logger.warning("Day \(day): fetch failed after retries - \(error.localizedDescription)")
                    debugLog("Day \(day): failed after retries - \(error.localizedDescription)")
                    OpenCodeZenProvider.loadingState.lastError = "Day \(day): \(error.localizedDescription)"
                }
            }

            // Update loading state with current history
            OpenCodeZenProvider.loadingState.dailyHistory = dailyHistory

            // Notify UI to update
            await MainActor.run {
                NotificationCenter.default.post(name: .openCodeZenHistoryUpdated, object: nil)
            }

            // Small delay to prevent CLI overload
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        }

        // Save cache
        saveHistoryCache(cache)

        // Mark loading complete
        OpenCodeZenProvider.loadingState.isLoading = false

        // Final UI update
        await MainActor.run {
            NotificationCenter.default.post(name: .openCodeZenHistoryUpdated, object: nil)
        }

        logger.info("OpenCodeZen: Progressive fetch completed, \(dailyHistory.count) days loaded")
    }

    /// Loads daily history from cache for immediate display
    private func loadDailyHistoryFromCache() -> [DailyUsage] {
        let cache = loadHistoryCache()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var dailyHistory: [DailyUsage] = []

        for item in cache.sorted(by: { $0.date > $1.date }).prefix(30) {
            dailyHistory.append(DailyUsage(
                date: item.date,
                includedRequests: 0,
                billedRequests: 0,
                grossAmount: item.cost,
                billedAmount: item.cost
            ))
        }

        return dailyHistory
    }

    private func parseTotalCost(_ output: String) -> Double? {
        let totalCostPattern = #"│Total Cost\s+\$([0-9.]+)"#
        guard let match = output.range(of: totalCostPattern, options: .regularExpression) else {
            return nil
        }
        let costStr = String(output[match])
            .replacingOccurrences(of: #"│Total Cost\s+\$"#, with: "", options: .regularExpression)
        return Double(costStr)
    }

    private func loadHistoryCache() -> [DailyHistoryCache] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return [] }
        return (try? JSONDecoder().decode([DailyHistoryCache].self, from: data)) ?? []
    }

    private func saveHistoryCache(_ cache: [DailyHistoryCache]) {
        // Keep only last 35 days of cache
        let calendar = Calendar.current
        let cutoffDate = calendar.date(byAdding: .day, value: -35, to: Date()) ?? Date()
        let filteredCache = cache.filter { $0.date > cutoffDate }

        if let data = try? JSONEncoder().encode(filteredCache) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    // MARK: - Private Helpers

    private func killExistingOpenCodeProcesses() {
        let killProcess = Process()
        killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killProcess.arguments = ["-f", "opencode stats"]
        try? killProcess.run()
        killProcess.waitUntilExit()
        debugLog("Killed existing opencode stats processes")
    }

    private func runOpenCodeStatsWithRetry(days: Int, maxRetries: Int = 3) async throws -> String {
        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                let output = try await runOpenCodeStats(days: days)
                return output
            } catch {
                lastError = error
                debugLog("Day \(days) attempt \(attempt)/\(maxRetries) failed: \(error.localizedDescription)")

                if attempt < maxRetries {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }

        throw lastError ?? ProviderError.networkError("Failed after \(maxRetries) retries")
    }

    private func runOpenCodeStats(days: Int) async throws -> String {
        guard let binaryPath = opencodePath else {
            throw ProviderError.providerError("OpenCode CLI not found")
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = binaryPath
            process.arguments = ["stats", "--days", "\(days)", "--models", "10"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            // Use nonisolated(unsafe) to allow mutation in concurrent handlers
            // This is safe because the handlers are serialized by the Process lifecycle
            nonisolated(unsafe) var outputData = Data()

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    outputData.append(data)
                }
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil

                let remainingData = pipe.fileHandleForReading.readDataToEndOfFile()
                if !remainingData.isEmpty {
                    outputData.append(remainingData)
                }

                if proc.terminationStatus != 0 {
                    continuation.resume(throwing: ProviderError.providerError("OpenCode CLI failed with exit code \(proc.terminationStatus)"))
                    return
                }

                guard let output = String(data: outputData, encoding: .utf8) else {
                    continuation.resume(throwing: ProviderError.decodingError("Failed to decode CLI output"))
                    return
                }

                continuation.resume(returning: output)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ProviderError.networkError("Failed to execute CLI: \(error.localizedDescription)"))
            }
        }
    }

    /// Parses opencode stats output using regex patterns
    private func parseStats(_ output: String) throws -> OpenCodeStats {
        // Parse Total Cost
        let totalCostPattern = #"│Total Cost\s+\$([0-9.]+)"#
        guard let totalCostMatch = output.range(of: totalCostPattern, options: .regularExpression) else {
            logger.error("Cannot parse total cost from output")
            throw ProviderError.decodingError("Cannot parse total cost")
        }
        let totalCostStr = String(output[totalCostMatch])
            .replacingOccurrences(of: #"│Total Cost\s+\$"#, with: "", options: .regularExpression)
        guard let totalCost = Double(totalCostStr) else {
            throw ProviderError.decodingError("Invalid total cost value")
        }

        // Parse Avg Cost/Day
        let avgCostPattern = #"│Avg Cost/Day\s+\$([0-9.]+)"#
        guard let avgCostMatch = output.range(of: avgCostPattern, options: .regularExpression) else {
            throw ProviderError.decodingError("Cannot parse avg cost")
        }
        let avgCostStr = String(output[avgCostMatch])
            .replacingOccurrences(of: #"│Avg Cost/Day\s+\$"#, with: "", options: .regularExpression)
        guard let avgCost = Double(avgCostStr) else {
            throw ProviderError.decodingError("Invalid avg cost value")
        }

        // Parse Sessions
        let sessionsPattern = #"│Sessions\s+([0-9,]+)"#
        guard let sessionsMatch = output.range(of: sessionsPattern, options: .regularExpression) else {
            throw ProviderError.decodingError("Cannot parse sessions")
        }
        let sessionsStr = String(output[sessionsMatch])
            .replacingOccurrences(of: #"│Sessions\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: ",", with: "")
        let sessions = Int(sessionsStr) ?? 0

        // Parse Messages
        let messagesPattern = #"│Messages\s+([0-9,]+)"#
        guard let messagesMatch = output.range(of: messagesPattern, options: .regularExpression) else {
            throw ProviderError.decodingError("Cannot parse messages")
        }
        let messagesStr = String(output[messagesMatch])
            .replacingOccurrences(of: #"│Messages\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: ",", with: "")
        let messages = Int(messagesStr) ?? 0

        // Parse Model costs
        var modelCosts: [String: Double] = [:]
        let modelPattern = #"│ (\S+)\s+.*│\s+Cost\s+\$([0-9.]+)"#
        do {
            let modelRegex = try NSRegularExpression(pattern: modelPattern)
            let matches = modelRegex.matches(in: output, range: NSRange(output.startIndex..., in: output))

            for match in matches {
                if let modelRange = Range(match.range(at: 1), in: output),
                   let costRange = Range(match.range(at: 2), in: output),
                   let cost = Double(output[costRange]) {
                    let modelName = String(output[modelRange])
                    modelCosts[modelName] = cost
                }
            }
        } catch {
            logger.warning("Failed to parse model costs: \(error.localizedDescription)")
        }

        return OpenCodeStats(
            totalCost: totalCost,
            avgCostPerDay: avgCost,
            sessions: sessions,
            messages: messages,
            modelCosts: modelCosts
        )
    }
}
