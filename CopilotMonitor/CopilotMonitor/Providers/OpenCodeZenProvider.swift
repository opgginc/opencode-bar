import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "OpenCodeZenProvider")

/// Provider for OpenCode Zen usage tracking via CLI stats.
/// Tracks current summary only and does not build historical time-series.
final class OpenCodeZenProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .openCodeZen
    let type: ProviderType = .payAsYouGo
    let fetchTimeout: TimeInterval = 60.0

    /// Path to opencode CLI binary (lazily resolved)
    private lazy var opencodePath: URL? = {
        injectedBinaryPath ?? findOpenCodeBinary()
    }()

    /// Cached description of where the binary was found
    private var binarySourceDescription: String = "unknown"

    /// Optional path injected by tests to bypass filesystem discovery.
    internal var injectedBinaryPath: URL?

    init() {
        self.injectedBinaryPath = nil
    }

    init(injectedBinaryPath: URL?) {
        self.injectedBinaryPath = injectedBinaryPath
    }

    /// Finds opencode binary using multiple strategies:
    /// 1. Try "opencode" command directly via PATH (user's current environment)
    /// 2. Try "opencode" via login shell PATH (captures shell profile additions)
    /// 3. Fallback to common hardcoded paths
    private func findOpenCodeBinary() -> URL? {
        logger.info("OpenCodeZen: Searching for opencode binary...")
        Self.debugLog("Starting opencode binary search")

        // Strategy 1: Try "which opencode" in current environment
        if let path = findBinaryViaWhich() {
            logger.info("OpenCodeZen: Found via 'which': \(path.path)")
            Self.debugLog("Found via 'which': \(path.path)")
            binarySourceDescription = "PATH (\(path.path))"
            return path
        }
        Self.debugLog("'which opencode' in current env returned nothing")

        // Strategy 2: Try via login shell to get user's full PATH
        if let path = findBinaryViaLoginShell() {
            logger.info("OpenCodeZen: Found via login shell: \(path.path)")
            Self.debugLog("Found via login shell: \(path.path)")
            binarySourceDescription = "login shell PATH (\(path.path))"
            return path
        }
        Self.debugLog("login shell 'which opencode' returned nothing")

        // Strategy 3: Hardcoded fallback paths
        let fallbackPaths = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global/bin/opencode").path, // npm global
            "/opt/homebrew/bin/opencode", // Apple Silicon Homebrew
            "/usr/local/bin/opencode", // Intel Homebrew
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opencode/bin/opencode").path, // OpenCode default
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/opencode").path, // pip/pipx
            "/usr/bin/opencode" // System-wide
        ]

        for path in fallbackPaths where FileManager.default.fileExists(atPath: path) {
            logger.info("OpenCodeZen: Found via fallback path: \(path)")
            Self.debugLog("Found via fallback: \(path)")
            binarySourceDescription = "fallback (\(path))"
            return URL(fileURLWithPath: path)
        }

        logger.error("OpenCodeZen: Binary not found in any location")
        Self.debugLog("Binary not found anywhere")
        return nil
    }

    /// Runs a process synchronously, redirecting stdout to a temporary file to
    /// avoid pipe deadlock when output exceeds the pipe buffer. The temp file is
    /// removed in all exit paths.
    /// - Returns: The process's stdout as a string, or nil if the process fails
    ///   or produces no readable output.
    @discardableResult
    internal static func runSynchronousCommand(process: Process) -> String? {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode_zen_stdout_\(UUID().uuidString).txt")

        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }

        let created = FileManager.default.createFile(atPath: tempFile.path, contents: nil, attributes: nil)
        guard created, let stdoutHandle = try? FileHandle(forWritingTo: tempFile) else {
            Self.debugLog("Failed to create stdout temp file at \(tempFile.path)")
            return nil
        }

        process.standardOutput = stdoutHandle

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            stdoutHandle.closeFile()
            Self.debugLog("Process failed to run: \(error.localizedDescription)")
            return nil
        }

        stdoutHandle.closeFile()

        guard process.terminationStatus == 0 else { return nil }

        guard let output = try? String(contentsOf: tempFile, encoding: .utf8) else { return nil }
        return output
    }

    /// Convenience wrapper that builds a Process and runs it synchronously.
    @discardableResult
    internal static func runSynchronousCommand(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) -> String? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment = environment {
            process.environment = environment
        }
        process.standardError = FileHandle.nullDevice
        return runSynchronousCommand(process: process)
    }

    /// Finds a binary by name using `which` either directly or via the login shell.
    /// Extracted and made internal so tests can verify behavior with arbitrary
    /// command names and controlled PATHs without relying on `opencode` being installed.
    internal static func findBinary(
        named name: String,
        usingWhich: Bool,
        environment: [String: String]? = nil
    ) -> URL? {
        let process = Process()
        if usingWhich {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = [name]
        } else {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            guard shell.hasPrefix("/") else {
                Self.debugLog("SHELL env is not an absolute path: \(shell)")
                return nil
            }
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-lc", "which \(name) 2>/dev/null"]
        }
        if let environment = environment {
            process.environment = environment
        }
        process.standardError = FileHandle.nullDevice

        guard let output = runSynchronousCommand(process: process)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else { return nil }

        guard FileManager.default.fileExists(atPath: output) else { return nil }
        return URL(fileURLWithPath: output)
    }

    /// Finds opencode binary using `which` command in current environment.
    internal func findBinaryViaWhich() -> URL? {
        Self.findBinary(named: "opencode", usingWhich: true)
    }

    /// Finds opencode binary using login shell to capture user's full PATH.
    /// This is important because GUI apps do not inherit terminal PATH modifications.
    internal func findBinaryViaLoginShell() -> URL? {
        Self.findBinary(named: "opencode", usingWhich: false)
    }

    /// Parsed statistics from `opencode stats`.
    private struct OpenCodeStats {
        let totalCost: Double
        let avgCostPerDay: Double
        let modelCosts: [String: Double]
        let modelMessages: [String: Int]
    }

    private struct ModelUsageStats {
        var cost: Double?
        var messages: Int?
    }

    struct DisplayStatsAdjustment {
        let totalCost: Double
        let avgCostPerDay: Double
        let modelCosts: [String: Double]
        let messages: Int
        let excludedCost: Double
    }

    func fetch() async throws -> ProviderResult {
        guard let binaryPath = opencodePath else {
            logger.error("OpenCode CLI not found in PATH or standard locations")
            throw ProviderError.authenticationFailed("OpenCode CLI not found. Install and sign in to OpenCode CLI first.")
        }

        guard FileManager.default.fileExists(atPath: binaryPath.path) else {
            logger.error("OpenCode CLI binary not accessible at \(binaryPath.path)")
            throw ProviderError.authenticationFailed("OpenCode CLI not accessible at \(binaryPath.path). Install and sign in to OpenCode CLI first.")
        }

        Self.debugLog("Fetching current stats only (history tracking disabled)")
        let output = try await runOpenCodeStats(days: 7)
        let stats = try parseStats(output)
        let displayStats = Self.adjustStatsForDisplay(
            totalCost: stats.totalCost,
            avgCostPerDay: stats.avgCostPerDay,
            modelCosts: stats.modelCosts,
            modelMessages: stats.modelMessages
        )

        let monthlyLimit = 1000.0
        let utilization = min((displayStats.totalCost / monthlyLimit) * 100, 100)
        logger.info("OpenCode Zen: $\(String(format: "%.2f", displayStats.totalCost)) (\(String(format: "%.1f", utilization))% of $\(monthlyLimit) limit)")
        if displayStats.excludedCost > 0 {
            let excludedSummary = String(format: "%.2f", displayStats.excludedCost)
            logger.info("OpenCode Zen: Excluded $\(excludedSummary) of non-Zen OpenCode stats usage from pay-as-you-go totals")
            Self.debugLog("Excluded $\(excludedSummary) of non-Zen OpenCode stats usage from OpenCode Zen totals")
        }

        let details = DetailedUsage(
            modelBreakdown: displayStats.modelCosts,
            sessions: nil,
            messages: displayStats.messages > 0 ? displayStats.messages : nil,
            avgCostPerDay: displayStats.avgCostPerDay > 0 ? displayStats.avgCostPerDay : nil,
            monthlyCost: displayStats.totalCost,
            authSource: "opencode CLI via \(binarySourceDescription)"
        )

        return ProviderResult(
            usage: .payAsYouGo(utilization: utilization, cost: displayStats.totalCost, resetsAt: nil),
            details: details
        )
    }

    private func runOpenCodeStats(days: Int) async throws -> String {
        guard let binaryPath = opencodePath else {
            throw ProviderError.authenticationFailed("OpenCode CLI not found. Install and sign in to OpenCode CLI first.")
        }

        // `opencode stats` occasionally hangs and leaves a background process alive
        // forever. Reap any that have outlived a sane lifetime before spawning a new
        // one so these zombies do not pile up across refresh cycles.
        killStaleOpenCodeStatsProcesses()

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = binaryPath
            // Use the unlimited --models form so filtering can inspect every
            // reported provider/model row instead of truncating the stats table.
            process.arguments = ["stats", "--days", "\(days)", "--models"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            // This buffer is only mutated by Process handlers for this process lifecycle.
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

                do {
                    let output = try Self.handleStatsOutput(outputData: outputData, exitStatus: proc.terminationStatus)
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ProviderError.networkError("Failed to execute CLI: \(error.localizedDescription)"))
            }
        }
    }

    private static func debugLog(_ message: String) {
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

    static func handleStatsOutput(outputData: Data, exitStatus: Int32) throws -> String {
        if exitStatus != 0 {
            let errorOutput = String(data: outputData, encoding: .utf8) ?? ""
            Self.debugLog("CLI exited \(exitStatus). Output:\n\(errorOutput)")
            if isOpenCodeAuthError(errorOutput) {
                throw ProviderError.authenticationFailed("OpenCode CLI is not authenticated. Run `opencode login` first.")
            }
            // Conservative fallback: any CLI failure that points at login/sign-in
            // should be treated as an unconfigured state rather than a runtime error.
            let lowercased = errorOutput.lowercased()
            let mentionsLogin = lowercased.contains("opencode login")
                || lowercased.contains("login required")
                || lowercased.contains("log in required")
                || lowercased.contains("sign in required")
                || lowercased.contains("signin required")
            let mentionsAuth = lowercased.contains("auth")
                || lowercased.contains("token")
                || lowercased.contains("credential")
                || lowercased.contains("session")
                || lowercased.contains("unauthorized")
            if mentionsLogin || (mentionsAuth && lowercased.contains("login")) {
                throw ProviderError.authenticationFailed("OpenCode CLI is not authenticated. Run `opencode login` first.")
            }
            throw ProviderError.providerError("OpenCode CLI failed with exit code \(exitStatus)")
        }

        guard let output = String(data: outputData, encoding: .utf8) else {
            throw ProviderError.decodingError("Failed to decode CLI output")
        }

        return output
    }

    private static func isOpenCodeAuthError(_ output: String) -> Bool {
        let lowercased = output.lowercased()
        let authPatterns = [
            // Explicit auth states
            "not authenticated",
            "not logged in",
            "not signed in",
            "no active session",
            // Requests to sign in / log in
            "please sign in",
            "please login",
            "please log in",
            "sign in required",
            "signin required",
            "login required",
            "log in required",
            "auth required",
            "authentication required",
            // Token/session problems
            "unauthorized",
            "invalid token",
            "token not found",
            "no valid token",
            "token expired",
            "session expired",
            "no token",
            "credentials not found",
            "no credentials",
            // CLI-specific hints (with various quote styles)
            "run 'opencode login'",
            "run `opencode login`",
            "run \"opencode login\"",
            "opencode login",
            "sign in to opencode",
            "login to opencode",
            "must be logged in",
            "must login",
            "must log in"
        ]
        return authPatterns.contains { lowercased.contains($0) }
    }

    /// Kills stale `opencode stats` processes that have run for over an hour.
    ///
    /// A healthy stats invocation finishes in seconds. When the CLI hangs it keeps a
    /// process alive in the background indefinitely, and these accumulate across our
    /// periodic refreshes. We reap anything past the threshold before starting a fresh
    /// run so the hung processes do not leak resources.
    ///
    /// - Note: Uses a temporary file for stdout instead of a Pipe to avoid deadlock
    ///   when the process list is larger than the pipe buffer.
    internal func killStaleOpenCodeStatsProcesses() {
        // 1 hour. Legitimate runs finish in seconds, so anything older is hung.
        let staleThresholdSeconds = 3600

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("token_king_ps_list_\(UUID().uuidString).txt")

        // Always delete the temp file on the way out, regardless of success or failure.
        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }

        let listing = Process()
        listing.executableURL = URL(fileURLWithPath: "/bin/ps")
        // etimes = elapsed running time in seconds; command = full argv string.
        listing.arguments = ["-axo", "pid=,etimes=,command="]

        // FileHandle(forWritingTo:) requires the file to already exist; create it first
        // so the process has a valid stdout destination.
        let created = FileManager.default.createFile(atPath: tempFile.path, contents: nil, attributes: nil)
        guard created, let stdoutHandle = try? FileHandle(forWritingTo: tempFile) else {
            Self.debugLog("Stale cleanup: failed to create stdout temp file")
            return
        }
        listing.standardOutput = stdoutHandle
        listing.standardError = FileHandle.nullDevice

        do {
            try listing.run()
            listing.waitUntilExit()
        } catch {
            Self.debugLog("Stale cleanup: failed to list processes: \(error.localizedDescription)")
            return
        }

        stdoutHandle.closeFile()

        guard let output = try? String(contentsOf: tempFile, encoding: .utf8) else {
            return
        }

        let selfPid = ProcessInfo.processInfo.processIdentifier
        let stalePids = Self.identifyStaleOpenCodeStatsPids(
            in: output,
            staleThresholdSeconds: staleThresholdSeconds,
            selfPid: selfPid
        )

        for stale in stalePids {
            // Hung processes ignore SIGTERM, so SIGKILL guarantees the reap.
            kill(stale.pid, SIGKILL)
            logger.info("OpenCodeZen: Killed stale 'opencode stats' process pid=\(stale.pid) (running \(stale.etimes)s)")
            Self.debugLog("Killed stale 'opencode stats' pid=\(stale.pid) etimes=\(stale.etimes)s")
        }
    }

    /// Parses `ps -axo pid=,etimes=,command=` output and returns the PIDs (with their
    /// elapsed times) of `opencode stats` processes that have run for at least
    /// `staleThresholdSeconds` and are not the current process.
    ///
    /// Extracted and made `internal` so tests can verify it handles large process
    /// lists without blocking or deadlocking.
    internal static func identifyStaleOpenCodeStatsPids(
        in output: String,
        staleThresholdSeconds: Int,
        selfPid: Int32
    ) -> [(pid: Int32, etimes: Int)] {
        var stalePids: [(pid: Int32, etimes: Int)] = []

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Split into: pid, etimes, command (command keeps its own spaces).
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let pid = Int32(parts[0]),
                  let etimes = Int(parts[1]) else { continue }

            let command = String(parts[2])

            guard command.contains("opencode"), command.contains(" stats") else { continue }
            guard etimes >= staleThresholdSeconds else { continue }
            guard pid != selfPid else { continue }

            stalePids.append((pid, etimes))
        }

        return stalePids
    }

    static func adjustStatsForDisplay(
        totalCost: Double,
        avgCostPerDay: Double,
        modelCosts: [String: Double],
        modelMessages: [String: Int] = [:]
    ) -> DisplayStatsAdjustment {
        let zenModelCosts = modelCosts.filter { isOpenCodeZenModel($0.key) }
        let zenCost = zenModelCosts
            .reduce(0.0) { partialResult, item in
                partialResult + max(item.value, 0)
            }
        // Fallback: if no models matched the Zen prefix but the CLI reported a
        // non-zero total, use the raw total so the user sees meaningful data
        // rather than a misleading zero. This can happen when OpenCode changes
        // model prefixes or when the account uses provider-specific aliases.
        let adjustedZenCost = zenCost > 0 ? zenCost : max(0, totalCost)
        let excludedCost = max(0, totalCost - adjustedZenCost)
        let adjustedAvgCostPerDay: Double
        if totalCost > 0, avgCostPerDay > 0 {
            adjustedAvgCostPerDay = max(0, avgCostPerDay * (adjustedZenCost / totalCost))
        } else {
            adjustedAvgCostPerDay = 0
        }

        let zenMessages = modelMessages
            .filter { isOpenCodeZenModel($0.key) }
            .reduce(0) { partialResult, item in
                partialResult + max(item.value, 0)
            }

        return DisplayStatsAdjustment(
            totalCost: adjustedZenCost,
            avgCostPerDay: adjustedAvgCostPerDay,
            modelCosts: zenModelCosts.isEmpty ? modelCosts : zenModelCosts,
            messages: zenMessages,
            excludedCost: excludedCost
        )
    }

    static func isOpenCodeZenModel(_ modelName: String) -> Bool {
        let normalized = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("opencode/") || normalized.hasPrefix("opencode-go/")
    }

    /// Parses opencode stats output using regex patterns.
    private func parseStats(_ output: String) throws -> OpenCodeStats {
        Self.debugLog("Parsing stats output (\(output.count) chars)")

        let totalCostPattern = #"│Total Cost\s+\$([0-9.]+)"#
        guard let totalCostMatch = output.range(of: totalCostPattern, options: .regularExpression) else {
            logger.error("Cannot parse total cost from output")
            Self.debugLog("Failed to match Total Cost. Output preview:\n\(String(output.prefix(800)))")
            throw ProviderError.decodingError("Cannot parse total cost")
        }
        let totalCostStr = String(output[totalCostMatch])
            .replacingOccurrences(of: #"│Total Cost\s+\$"#, with: "", options: .regularExpression)
        guard let totalCost = Double(totalCostStr) else {
            Self.debugLog("Failed to convert total cost '\(totalCostStr)' to Double")
            throw ProviderError.decodingError("Invalid total cost value")
        }

        let avgCostPattern = #"│Avg Cost/Day\s+\$([0-9.]+)"#
        guard let avgCostMatch = output.range(of: avgCostPattern, options: .regularExpression) else {
            Self.debugLog("Failed to match Avg Cost/Day")
            throw ProviderError.decodingError("Cannot parse avg cost")
        }
        let avgCostStr = String(output[avgCostMatch])
            .replacingOccurrences(of: #"│Avg Cost/Day\s+\$"#, with: "", options: .regularExpression)
        guard let avgCost = Double(avgCostStr) else {
            Self.debugLog("Failed to convert avg cost '\(avgCostStr)' to Double")
            throw ProviderError.decodingError("Invalid avg cost value")
        }

        let modelCosts = Self.parseModelCosts(from: output)
        let modelMessages = Self.parseModelMessages(from: output)

        Self.debugLog("Parsed totalCost=\(totalCost), avgCost=\(avgCost), models=\(modelCosts.count), messages=\(modelMessages.count)")

        return OpenCodeStats(
            totalCost: totalCost,
            avgCostPerDay: avgCost,
            modelCosts: modelCosts,
            modelMessages: modelMessages
        )
    }

    static func parseModelCosts(from output: String) -> [String: Double] {
        parseModelUsageStats(from: output).compactMapValues(\.cost)
    }

    static func parseModelMessages(from output: String) -> [String: Int] {
        parseModelUsageStats(from: output).compactMapValues(\.messages)
    }

    private static func parseModelUsageStats(from output: String) -> [String: ModelUsageStats] {
        var modelUsageStats: [String: ModelUsageStats] = [:]
        var currentModel: String?
        var isInModelUsageSection = false

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.replacingOccurrences(
                of: #"\u{001B}\[[0-9;]*[A-Za-z]"#,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)

            guard line.hasPrefix("│") else {
                if line.hasPrefix("├") || line.hasPrefix("└") {
                    currentModel = nil
                }
                continue
            }

            let text = trimmedTableCell(line)
            guard !text.isEmpty else { continue }

            if isStatsSectionHeader(text) {
                isInModelUsageSection = text == "MODEL USAGE"
                currentModel = nil
                continue
            }

            guard isInModelUsageSection else { continue }

            if text.hasPrefix("Cost") {
                guard let currentModel,
                      let cost = dollarValue(in: text) else { continue }
                var stats = modelUsageStats[currentModel] ?? ModelUsageStats()
                stats.cost = cost
                modelUsageStats[currentModel] = stats
                continue
            }

            if text.hasPrefix("Messages") {
                guard let currentModel,
                      let messages = integerValue(in: text) else { continue }
                var stats = modelUsageStats[currentModel] ?? ModelUsageStats()
                stats.messages = messages
                modelUsageStats[currentModel] = stats
                continue
            }

            if isStatsMetricLine(text) {
                continue
            }

            currentModel = text
        }

        return modelUsageStats
    }

    private static func trimmedTableCell(_ line: String) -> String {
        var content = line
        if content.first == "│" {
            content.removeFirst()
        }
        if let trailingBorder = content.lastIndex(of: "│") {
            content = String(content[..<trailingBorder])
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func dollarValue(in text: String) -> Double? {
        guard let dollarIndex = text.lastIndex(of: "$") else { return nil }
        let valueStart = text.index(after: dollarIndex)
        let valueText = text[valueStart...]
            .split(separator: " ")
            .first
            .map(String.init)
        return valueText.flatMap(Double.init)
    }

    private static func integerValue(in text: String) -> Int? {
        guard let valueRange = text.range(of: #"[0-9][0-9,]*"#, options: .regularExpression) else {
            return nil
        }
        let valueText = String(text[valueRange]).replacingOccurrences(of: ",", with: "")
        return Int(valueText)
    }

    private static func isStatsMetricLine(_ text: String) -> Bool {
        let metricPrefixes = [
            "Sessions",
            "Messages",
            "Days",
            "Total Cost",
            "Avg Cost/Day",
            "Avg Tokens/Session",
            "Median Tokens/Session",
            "Input",
            "Output",
            "Input Tokens",
            "Output Tokens",
            "Cache Read",
            "Cache Write"
        ]

        return metricPrefixes.contains { text.hasPrefix($0) }
    }

    private static func isStatsSectionHeader(_ text: String) -> Bool {
        let sectionHeaders = [
            "OVERVIEW",
            "COST & TOKENS",
            "MODEL USAGE",
            "TOOL USAGE"
        ]

        return sectionHeaders.contains(text)
    }
}
