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

/// Provider for OpenCode Zen usage tracking via CLI stats.
/// Tracks current summary only and does not build historical time-series.
final class OpenCodeZenProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .openCodeZen
    let type: ProviderType = .payAsYouGo
    let fetchTimeout: TimeInterval = 60.0

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
            "/opt/homebrew/bin/opencode", // Apple Silicon Homebrew
            "/usr/local/bin/opencode", // Intel Homebrew
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opencode/bin/opencode").path, // OpenCode default
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/opencode").path, // pip/pipx
            "/usr/bin/opencode" // System-wide
        ]

        for path in fallbackPaths where FileManager.default.fileExists(atPath: path) {
            logger.info("OpenCodeZen: Found via fallback path: \(path)")
            debugLog("Found via fallback: \(path)")
            binarySourceDescription = "fallback (\(path))"
            return URL(fileURLWithPath: path)
        }

        logger.error("OpenCodeZen: Binary not found in any location")
        debugLog("Binary not found anywhere")
        return nil
    }

    /// Finds opencode binary using `which` command in current environment.
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

            guard FileManager.default.fileExists(atPath: output) else { return nil }
            return URL(fileURLWithPath: output)
        } catch {
            debugLog("'which opencode' failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Finds opencode binary using login shell to capture user's full PATH.
    /// This is important because GUI apps do not inherit terminal PATH modifications.
    private func findBinaryViaLoginShell() -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
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

            guard FileManager.default.fileExists(atPath: output) else { return nil }
            return URL(fileURLWithPath: output)
        } catch {
            debugLog("Login shell 'which opencode' failed: \(error.localizedDescription)")
            return nil
        }
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
            throw ProviderError.providerError("OpenCode CLI not found. Install via: brew install opencode, or ensure 'opencode' is in PATH")
        }

        guard FileManager.default.fileExists(atPath: binaryPath.path) else {
            logger.error("OpenCode CLI binary not accessible at \(binaryPath.path)")
            throw ProviderError.providerError("OpenCode CLI not accessible at \(binaryPath.path)")
        }

        debugLog("Fetching current stats only (history tracking disabled)")
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
            debugLog("Excluded $\(excludedSummary) of non-Zen OpenCode stats usage from OpenCode Zen totals")
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
            throw ProviderError.providerError("OpenCode CLI not found")
        }

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
        let excludedCost = max(0, totalCost - zenCost)
        let adjustedAvgCostPerDay: Double
        if totalCost > 0, avgCostPerDay > 0 {
            adjustedAvgCostPerDay = max(0, avgCostPerDay * (zenCost / totalCost))
        } else {
            adjustedAvgCostPerDay = 0
        }

        let zenMessages = modelMessages
            .filter { isOpenCodeZenModel($0.key) }
            .reduce(0) { partialResult, item in
                partialResult + max(item.value, 0)
            }

        return DisplayStatsAdjustment(
            totalCost: zenCost,
            avgCostPerDay: adjustedAvgCostPerDay,
            modelCosts: zenModelCosts,
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

        let avgCostPattern = #"│Avg Cost/Day\s+\$([0-9.]+)"#
        guard let avgCostMatch = output.range(of: avgCostPattern, options: .regularExpression) else {
            throw ProviderError.decodingError("Cannot parse avg cost")
        }
        let avgCostStr = String(output[avgCostMatch])
            .replacingOccurrences(of: #"│Avg Cost/Day\s+\$"#, with: "", options: .regularExpression)
        guard let avgCost = Double(avgCostStr) else {
            throw ProviderError.decodingError("Invalid avg cost value")
        }

        let modelCosts = Self.parseModelCosts(from: output)
        let modelMessages = Self.parseModelMessages(from: output)

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
