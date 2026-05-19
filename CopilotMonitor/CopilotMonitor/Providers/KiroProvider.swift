import Foundation
import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "KiroProvider")

struct KiroUsageSnapshot: Equatable {
    let usedCredits: Double
    let totalCredits: Double
    let planName: String?
    let resetDate: Date?
    let overageStatus: String?

    var remainingCredits: Double {
        max(totalCredits - usedCredits, 0)
    }

    var usagePercent: Double {
        guard totalCredits > 0 else { return 0 }
        return min(max((usedCredits / totalCredits) * 100.0, 0), 999)
    }
}

final class KiroProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .kiro
    let type: ProviderType = .quotaBased
    let fetchTimeout: TimeInterval = 25
    let minimumFetchInterval: TimeInterval = 60

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func fetch() async throws -> ProviderResult {
        debugLog("fetch started")

        guard let binaryPath = findKiroCLIBinary() else {
            debugLog("kiro-cli binary not found")
            throw ProviderError.authenticationFailed("Kiro CLI not found. Install and sign in to Kiro CLI first.")
        }

        let output = try await runKiroUsage(binaryPath: binaryPath)
        let snapshot = try Self.parseUsageOutput(output)
        let result = Self.makeResult(from: snapshot, binaryPath: binaryPath)

        logger.info(
            "Kiro usage fetched: used=\(String(format: "%.2f", snapshot.usedCredits), privacy: .public), total=\(String(format: "%.2f", snapshot.totalCredits), privacy: .public), plan=\(snapshot.planName ?? "unknown", privacy: .public)"
        )
        debugLog("fetch completed through kiro-cli /usage")
        return result
    }

    private func findKiroCLIBinary() -> URL? {
        if let path = findBinaryViaWhich() {
            debugLog("kiro-cli found via PATH at \(path.path)")
            return path
        }

        if let path = findBinaryViaLoginShell() {
            debugLog("kiro-cli found via login shell at \(path.path)")
            return path
        }

        let home = fileManager.homeDirectoryForCurrentUser.path
        let fallbackPaths = [
            "\(home)/.local/bin/kiro-cli",
            "/opt/homebrew/bin/kiro-cli",
            "/usr/local/bin/kiro-cli",
            "/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli"
        ]

        for path in fallbackPaths where fileManager.isExecutableFile(atPath: path) {
            debugLog("kiro-cli found via fallback at \(path)")
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    private func findBinaryViaWhich() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["kiro-cli"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty,
                  fileManager.isExecutableFile(atPath: output) else {
                return nil
            }
            return URL(fileURLWithPath: output)
        } catch {
            debugLog("which kiro-cli failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func findBinaryViaLoginShell() -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "which kiro-cli 2>/dev/null"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty,
                  fileManager.isExecutableFile(atPath: output) else {
                return nil
            }
            return URL(fileURLWithPath: output)
        } catch {
            debugLog("login shell kiro-cli lookup failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func runKiroUsage(binaryPath: URL) async throws -> String {
        let timeout = fetchTimeout
        return try await withThrowingTaskGroup(of: String.self) { group in
            let process = Process()
            process.executableURL = binaryPath
            process.arguments = ["chat", "--classic"]

            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let outputPipe = Pipe()
                    let inputPipe = Pipe()
                    process.standardOutput = outputPipe
                    process.standardError = outputPipe
                    process.standardInput = inputPipe

                    nonisolated(unsafe) var outputData = Data()

                    outputPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        if !data.isEmpty {
                            outputData.append(data)
                        }
                    }

                    process.terminationHandler = { _ in
                        outputPipe.fileHandleForReading.readabilityHandler = nil

                        let remainingData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                        if !remainingData.isEmpty {
                            outputData.append(remainingData)
                        }

                        guard let output = String(data: outputData, encoding: .utf8) else {
                            continuation.resume(throwing: ProviderError.decodingError("Cannot decode kiro-cli output"))
                            return
                        }

                        if process.terminationStatus == 0 {
                            continuation.resume(returning: output)
                        } else {
                            continuation.resume(throwing: ProviderError.providerError("kiro-cli exited with status \(process.terminationStatus)"))
                        }
                    }

                    do {
                        try process.run()
                        if let input = "/usage\n/quit\n".data(using: .utf8) {
                            inputPipe.fileHandleForWriting.write(input)
                        }
                        try? inputPipe.fileHandleForWriting.close()
                    } catch {
                        outputPipe.fileHandleForReading.readabilityHandler = nil
                        continuation.resume(throwing: error)
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ProviderError.networkError("kiro-cli /usage timed out after \(Int(timeout))s")
            }

            guard let result = try await group.next() else {
                throw ProviderError.providerError("kiro-cli /usage task failed")
            }

            group.cancelAll()
            if process.isRunning {
                process.terminate()
            }
            return result
        }
    }

    static func parseUsageOutput(_ output: String) throws -> KiroUsageSnapshot {
        let text = stripANSI(from: output)
        let normalized = text.replacingOccurrences(of: "\u{00A0}", with: " ")

        guard let creditsMatch = firstMatch(
            in: normalized,
            pattern: #"Credits\s*\(\s*([0-9][0-9,]*(?:\.[0-9]+)?)\s+of\s+([0-9][0-9,]*(?:\.[0-9]+)?)\s+covered\s+in\s+plan\s*\)"#
        ),
              creditsMatch.count >= 3,
              let usedCredits = parseNumber(creditsMatch[1]),
              let totalCredits = parseNumber(creditsMatch[2]),
              totalCredits > 0 else {
            throw ProviderError.decodingError("Kiro usage output did not include monthly credit usage")
        }

        let resetDate = firstMatch(in: normalized, pattern: #"resets\s+on\s+(\d{4}-\d{2}-\d{2})"#).flatMap { match in
            match.count > 1 ? parseDate(match[1]) : nil
        }
        let planName = parsePlanName(from: normalized)
        let overageStatus = firstMatch(in: normalized, pattern: #"Overages:\s*([A-Za-z]+)"#).flatMap { match in
            match.count > 1 ? match[1] : nil
        }

        return KiroUsageSnapshot(
            usedCredits: usedCredits,
            totalCredits: totalCredits,
            planName: planName,
            resetDate: resetDate,
            overageStatus: overageStatus
        )
    }

    static func makeResult(from snapshot: KiroUsageSnapshot, binaryPath: URL) -> ProviderResult {
        let scale = 100.0
        let entitlement = max(Int((snapshot.totalCredits * scale).rounded()), 1)
        let remaining = max(Int((snapshot.remainingCredits * scale).rounded()), 0)
        let details = DetailedUsage(
            primaryReset: snapshot.resetDate,
            planType: snapshot.planName,
            monthlyCost: snapshot.usedCredits,
            creditsRemaining: snapshot.remainingCredits,
            creditsTotal: snapshot.totalCredits,
            authSource: "kiro-cli at \(binaryPath.path)"
        )

        return ProviderResult(
            usage: .quotaBased(
                remaining: remaining,
                entitlement: entitlement,
                overagePermitted: snapshot.overageStatus?.localizedCaseInsensitiveContains("enabled") == true
            ),
            details: details
        )
    }

    private static func stripANSI(from text: String) -> String {
        let escape = "\u{001B}"
        let patterns = [
            "\(escape)\\[[0-?]*[ -/]*[@-~]",
            "\(escape)\\][^\u{0007}]*(?:\u{0007}|\(escape)\\\\)"
        ]
        return patterns.reduce(text) { current, pattern in
            current.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
    }

    private static func parsePlanName(from text: String) -> String? {
        let patterns = [
            #"Estimated\s+Usage\s*\|\s*resets\s+on\s+\d{4}-\d{2}-\d{2}\s*\|\s*([A-Za-z0-9 +_-]+)(?:\s*\([^\n\r)]*\))?"#,
            #"Plan:\s*([A-Za-z0-9 +_-]+)(?:\s*\([^\n\r)]*\))?"#
        ]

        for pattern in patterns {
            guard let match = firstMatch(in: text, pattern: pattern), match.count > 1 else { continue }
            let plan = match[1]
                .replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !plan.isEmpty {
                return plan
            }
        }
        return nil
    }

    private static func firstMatch(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }

        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard let swiftRange = Range(range, in: text) else { return "" }
            return String(text[swiftRange])
        }
    }

    private static func parseNumber(_ value: String) -> Double? {
        Double(value.replacingOccurrences(of: ",", with: ""))
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        if let utc = TimeZone(identifier: "UTC") {
            formatter.timeZone = utc
        }
        return formatter.date(from: value)
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        let msg = "[\(Date())] KiroProvider: \(message)\n"
        if let data = msg.data(using: .utf8) {
            let path = "/tmp/provider_debug.log"
            if fileManager.fileExists(atPath: path), let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
        #endif
    }
}
