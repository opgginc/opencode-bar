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
        let sessions: Int
        let messages: Int
        let modelCosts: [String: Double]
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

        let monthlyLimit = 1000.0
        let utilization = min((stats.totalCost / monthlyLimit) * 100, 100)
        logger.info("OpenCode Zen: $\(String(format: "%.2f", stats.totalCost)) (\(String(format: "%.1f", utilization))% of $\(monthlyLimit) limit)")

        let details = DetailedUsage(
            modelBreakdown: stats.modelCosts,
            sessions: stats.sessions > 0 ? stats.sessions : nil,
            messages: stats.messages > 0 ? stats.messages : nil,
            avgCostPerDay: stats.avgCostPerDay > 0 ? stats.avgCostPerDay : nil,
            monthlyCost: stats.totalCost,
            authSource: "opencode CLI via \(binarySourceDescription)"
        )

        return ProviderResult(
            usage: .payAsYouGo(utilization: utilization, cost: stats.totalCost, resetsAt: nil),
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
            process.arguments = ["stats", "--days", "\(days)", "--models", "10"]

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

        let sessionsPattern = #"│Sessions\s+([0-9,]+)"#
        guard let sessionsMatch = output.range(of: sessionsPattern, options: .regularExpression) else {
            throw ProviderError.decodingError("Cannot parse sessions")
        }
        let sessionsStr = String(output[sessionsMatch])
            .replacingOccurrences(of: #"│Sessions\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: ",", with: "")
        let sessions = Int(sessionsStr) ?? 0

        let messagesPattern = #"│Messages\s+([0-9,]+)"#
        guard let messagesMatch = output.range(of: messagesPattern, options: .regularExpression) else {
            throw ProviderError.decodingError("Cannot parse messages")
        }
        let messagesStr = String(output[messagesMatch])
            .replacingOccurrences(of: #"│Messages\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: ",", with: "")
        let messages = Int(messagesStr) ?? 0

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
