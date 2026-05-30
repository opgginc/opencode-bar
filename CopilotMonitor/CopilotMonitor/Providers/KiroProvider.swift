import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "KiroProvider")

struct KiroUsageSnapshot: Equatable {
    let usedCredits: Double
    let totalCredits: Double
    let planName: String?
    let resetDate: Date?
    let overageStatus: String?
    let bonusCreditsUsed: Double?
    let bonusCreditsTotal: Double?
    let bonusExpiryDays: Int?

    init(
        usedCredits: Double,
        totalCredits: Double,
        planName: String?,
        resetDate: Date?,
        overageStatus: String?,
        bonusCreditsUsed: Double? = nil,
        bonusCreditsTotal: Double? = nil,
        bonusExpiryDays: Int? = nil
    ) {
        self.usedCredits = usedCredits
        self.totalCredits = totalCredits
        self.planName = planName
        self.resetDate = resetDate
        self.overageStatus = overageStatus
        self.bonusCreditsUsed = bonusCreditsUsed
        self.bonusCreditsTotal = bonusCreditsTotal
        self.bonusExpiryDays = bonusExpiryDays
    }

    var remainingCredits: Double {
        totalCredits - usedCredits
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
    let minimumFetchInterval: TimeInterval = 300

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func fetch() async throws -> ProviderResult {
        debugLog("fetch started")

        guard let binaryPath = await findKiroCLIBinary() else {
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

    private func findKiroCLIBinary() async -> URL? {
        if let path = await findBinaryViaWhich() {
            debugLog("kiro-cli found via PATH at \(path.path)")
            return path
        }

        if let path = await findBinaryViaLoginShell() {
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

    private func findBinaryViaWhich() async -> URL? {
        guard let output = try? await runLookupProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/which"),
            arguments: ["kiro-cli"]
        ) else { return nil }
        return validatedBinaryPath(from: output)
    }

    private func findBinaryViaLoginShell() async -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let output = try? await runLookupProcess(
            executableURL: URL(fileURLWithPath: shell),
            arguments: ["-lc", "command -v kiro-cli 2>/dev/null"]
        ) else { return nil }
        return validatedBinaryPath(from: output)
    }

    private func validatedBinaryPath(from output: String) -> URL? {
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, fileManager.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func runLookupProcess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = 5
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            defer {
                group.cancelAll()
                if process.isRunning {
                    process.terminate()
                }
            }

            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = FileHandle.nullDevice

                    process.terminationHandler = { _ in
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        guard process.terminationStatus == 0,
                              let output = String(data: data, encoding: .utf8) else {
                            continuation.resume(throwing: ProviderError.providerError("Kiro CLI lookup failed"))
                            return
                        }
                        continuation.resume(returning: output)
                    }

                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ProviderError.networkError("Kiro CLI lookup timeout")
            }

            guard let result = try await group.next() else {
                throw ProviderError.providerError("Kiro CLI lookup failed")
            }
            return result
        }
    }

    private func runKiroUsage(binaryPath: URL) async throws -> String {
        let timeout = fetchTimeout
        return try await withThrowingTaskGroup(of: String.self) { group in
            let process = Process()
            process.executableURL = binaryPath
            process.arguments = ["chat", "--no-interactive", "/usage"]

            defer {
                group.cancelAll()
                if process.isRunning {
                    process.terminate()
                }
            }

            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let outputPipe = Pipe()
                    process.standardOutput = outputPipe
                    process.standardError = outputPipe
                    process.standardInput = FileHandle.nullDevice

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

            return result
        }
    }

    static func parseUsageOutput(_ output: String) throws -> KiroUsageSnapshot {
        let text = stripANSI(from: output)
        let normalized = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        let planName = parsePlanName(from: normalized)

        let creditsMatch = firstMatch(
            in: normalized,
            pattern: #"Credits\s*\(\s*([0-9][0-9,]*(?:\.[0-9]+)?)\s+of\s+([0-9][0-9,]*(?:\.[0-9]+)?)(?:\s+covered\s+in\s+plan)?\s*\)"#
        )
        let percent = parseProgressPercent(from: normalized)

        let usedCredits = creditsMatch.flatMap { match in
            match.count > 1 ? parseNumber(match[1]) : nil
        }
        let totalCredits = creditsMatch.flatMap { match in
            match.count > 2 ? parseNumber(match[2]) : nil
        }

        let resolvedTotalCredits = totalCredits ?? planName.flatMap(planCreditTotal)
        let resolvedUsedCredits = usedCredits ?? percent.flatMap { parsedPercent in
            resolvedTotalCredits.map { ($0 * parsedPercent) / 100.0 }
        }

        guard let resolvedUsedCredits,
              let resolvedTotalCredits,
              resolvedTotalCredits > 0 else {
            throw ProviderError.decodingError("Kiro usage output did not include monthly credit usage")
        }

        let resetDate = firstMatch(in: normalized, pattern: #"resets\s+on\s+(\d{4}-\d{2}-\d{2}|\d{2}/\d{2})"#).flatMap { match in
            match.count > 1 ? parseDate(match[1]) : nil
        }
        let overageStatus = firstMatch(in: normalized, pattern: #"Overages:\s*([A-Za-z]+)"#).flatMap { match in
            match.count > 1 ? match[1] : nil
        }
        let bonusCredits = parseBonusCredits(from: normalized)

        return KiroUsageSnapshot(
            usedCredits: resolvedUsedCredits,
            totalCredits: resolvedTotalCredits,
            planName: planName,
            resetDate: resetDate,
            overageStatus: overageStatus,
            bonusCreditsUsed: bonusCredits.used,
            bonusCreditsTotal: bonusCredits.total,
            bonusExpiryDays: bonusCredits.expiryDays
        )
    }

    static func makeResult(from snapshot: KiroUsageSnapshot, binaryPath: URL) -> ProviderResult {
        let scale = 100.0
        let entitlement = max(Int((snapshot.totalCredits * scale).rounded()), 1)
        let remaining = Int((snapshot.remainingCredits * scale).rounded())
        let details = DetailedUsage(
            secondaryUsage: bonusUsagePercent(from: snapshot),
            secondaryReset: bonusExpiryDate(from: snapshot),
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
            #"Estimated\s+Usage\s*\|\s*resets\s+on\s+(?:\d{4}-\d{2}-\d{2}|\d{2}/\d{2})\s*\|\s*([A-Za-z0-9 +_-]+)(?:\s*\([^\n\r)]*\))?"#,
            #"\|\s*(KIRO\s+[A-Za-z0-9 +_-]+)"#,
            #"Plan:\s*([A-Za-z0-9 +_-]+)(?:\s*\([^\n\r)]*\))?"#
        ]

        for pattern in patterns {
            guard let match = firstMatch(in: text, pattern: pattern), match.count > 1 else { continue }
            let plan = match[1]
                .replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !plan.isEmpty {
                return normalizePlanName(plan)
            }
        }
        return nil
    }

    private static func normalizePlanName(_ planName: String) -> String {
        let cleaned = planName
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let uppercased = cleaned.uppercased()

        if uppercased.contains("POWER") {
            return "Power"
        }
        if uppercased.contains("PRO+") || uppercased.contains("PRO PLUS") {
            return "Pro+"
        }
        if uppercased.contains("PRO") {
            return "Pro"
        }
        if uppercased.contains("FREE") {
            return "Free"
        }
        return cleaned
    }

    private static func planCreditTotal(for planName: String) -> Double? {
        switch normalizePlanName(planName).lowercased() {
        case "free":
            return 50
        case "pro":
            return 1_000
        case "pro+":
            return 2_000
        case "power":
            return 10_000
        default:
            return nil
        }
    }

    private static func parseProgressPercent(from text: String) -> Double? {
        firstMatch(in: text, pattern: #"(?:█|▓|▒|━|─|■)+\s*([0-9]+(?:\.[0-9]+)?)%"#).flatMap { match in
            match.count > 1 ? parseNumber(match[1]) : nil
        }
    }

    private static func parseBonusCredits(from text: String) -> (used: Double?, total: Double?, expiryDays: Int?) {
        let bonusMatch = firstMatch(
            in: text,
            pattern: #"Bonus\s+credits:[\s\S]{0,160}?([0-9][0-9,]*(?:\.[0-9]+)?)/([0-9][0-9,]*(?:\.[0-9]+)?)\s+credits\s+used"#
        )
        let expiryMatch = firstMatch(in: text, pattern: #"expires\s+in\s+(\d+)\s+days?"#)

        return (
            used: bonusMatch.flatMap { $0.count > 1 ? parseNumber($0[1]) : nil },
            total: bonusMatch.flatMap { $0.count > 2 ? parseNumber($0[2]) : nil },
            expiryDays: expiryMatch.flatMap { $0.count > 1 ? Int($0[1]) : nil }
        )
    }

    private static func bonusUsagePercent(from snapshot: KiroUsageSnapshot) -> Double? {
        guard let used = snapshot.bonusCreditsUsed,
              let total = snapshot.bonusCreditsTotal,
              total > 0 else {
            return nil
        }
        return min(max((used / total) * 100.0, 0), 999)
    }

    private static func bonusExpiryDate(from snapshot: KiroUsageSnapshot) -> Date? {
        guard let days = snapshot.bonusExpiryDays else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        if let utc = TimeZone(identifier: "UTC") {
            calendar.timeZone = utc
        }
        return calendar.date(byAdding: .day, value: days, to: Date())
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
        if value.contains("/") {
            let parts = value.split(separator: "/")
            guard parts.count == 2,
                  let month = Int(parts[0]),
                  let day = Int(parts[1]) else {
                return nil
            }

            var calendar = Calendar(identifier: .gregorian)
            if let utc = TimeZone(identifier: "UTC") {
                calendar.timeZone = utc
            }

            let now = Date()
            let currentYear = calendar.component(.year, from: now)
            var components = DateComponents()
            components.year = currentYear
            components.month = month
            components.day = day

            if let date = calendar.date(from: components), date >= calendar.startOfDay(for: now) {
                return date
            }

            components.year = currentYear + 1
            return calendar.date(from: components)
        }

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
