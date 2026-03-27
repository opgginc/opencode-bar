import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "ProviderManager")

/// Result of fetchAll() including both successful results and errors
struct FetchAllResult {
    let results: [ProviderIdentifier: ProviderResult]
    let errors: [ProviderIdentifier: String]
    
    var hasErrors: Bool {
        !errors.isEmpty
    }
}

/// Singleton coordinator for managing multiple AI provider usage tracking
/// Handles parallel fetching, aggregation, and error recovery
actor ProviderManager {
    // MARK: - Singleton

    static let shared = ProviderManager()

    // MARK: - Properties

    /// All registered providers
    private var providers: [ProviderProtocol] = []

    private nonisolated static func makeDefaultProviders() -> [ProviderProtocol] {
        [
            CopilotProvider(),
            ClaudeProvider(),
            CodexProvider(),
            GeminiCLIProvider(),
            MiniMaxProvider(),
            ZaiCodingPlanProvider(),
            NanoGptProvider(),
            OpenRouterProvider(),
            AntigravityProvider(),
            OpenCodeZenProvider(),
            KimiProvider(),
            ChutesProvider(),
            SyntheticProvider(),
            TavilySearchProvider(),
            BraveSearchProvider()
        ]
    }

    // Per-provider timeout is now defined in ProviderProtocol.fetchTimeout

    /// Last successful fetch results (used as fallback on errors)
    /// Access via updateCache/getCache methods for thread safety
    private var cachedResults: [ProviderIdentifier: ProviderResult] = [:]
    private var lastNetworkFetchAt: [ProviderIdentifier: Date] = [:]
    private var lastProviderErrors: [ProviderIdentifier: String] = [:]
    private var inFlightFetches: [ProviderIdentifier: InFlightProviderFetch] = [:]

    private struct InFlightProviderFetch {
        let token: UUID
        let task: Task<ProviderResult, Error>
    }

    private struct ThrottledFetchOutcome {
        let result: ProviderResult?
        let errorMessage: String?
    }

    // MARK: - Initialization

    private init() {
        providers = Self.makeDefaultProviders()
        let providerCount = providers.count
        logger.info("ProviderManager initialized with \(providerCount) providers")
    }

    init(providers: [ProviderProtocol]) {
        self.providers = providers
        let providerCount = providers.count
        logger.info("ProviderManager initialized with custom provider set (\(providerCount) providers)")
    }

    private nonisolated func debugLog(_ message: String) {
        #if DEBUG
        let msg = "[\(Date())] ProviderManager: \(message)\n"
        if let data = msg.data(using: .utf8) {
            let path = "/tmp/provider_debug.log"
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
        #endif
    }

    // MARK: - Public API

    /// Fetches usage data from all registered providers in parallel
    /// - Returns: FetchAllResult containing both successful results and error messages
    /// - Note: Returns partial results if some providers fail (graceful degradation)
    func fetchAll() async -> FetchAllResult {
        logger.info("🔵 [ProviderManager] fetchAll() started - \(self.providers.count) providers")
        self.debugLog("🔵 fetchAll() started - \(self.providers.count) providers")

        var results: [ProviderIdentifier: ProviderResult] = [:]
        var errors: [ProviderIdentifier: String] = [:]

        // Use TaskGroup for parallel fetching with timeout
        // Return type: (identifier, result, errorMessage)
        await withTaskGroup(of: (ProviderIdentifier, ProviderResult?, String?).self) { group in
            for provider in self.providers {
                logger.debug("🟡 [ProviderManager] Adding fetch task for \(provider.identifier.displayName)")
                self.debugLog("🟡 Adding fetch task for \(provider.identifier.displayName)")
                
                group.addTask { [weak self] in
                    guard let self = self else {
                        logger.warning("🔴 [ProviderManager] Self deallocated for \(provider.identifier.displayName)")
                        return (provider.identifier, nil, "Self deallocated")
                    }
                    return await self.fetchProvider(provider)
                }
            }

            // Collect results from all tasks
            logger.debug("🟡 [ProviderManager] Collecting results from task group")
            self.debugLog("🟡 Collecting results from task group")
            
            for await (identifier, result, errorMessage) in group {
                if let result = result {
                    results[identifier] = result
                    logger.debug("🟢 [ProviderManager] Collected result for \(identifier.displayName)")
                    self.debugLog("🟢 Collected result for \(identifier.displayName)")
                } else {
                    logger.warning("🔴 [ProviderManager] No result for \(identifier.displayName)")
                    self.debugLog("🔴 No result for \(identifier.displayName)")
                }
                
                // Store error message even if we have cached result (to show user there was an issue)
                if let errorMessage = errorMessage {
                    errors[identifier] = errorMessage
                }
            }
        }

        logger.info("🟢 [ProviderManager] fetchAll() completed: \(results.count)/\(self.providers.count) providers succeeded, \(errors.count) errors")
        self.debugLog("🟢 fetchAll() completed: \(results.count)/\(self.providers.count) providers succeeded, \(errors.count) errors")
        return FetchAllResult(results: results, errors: errors)
    }
    
    /// Legacy method for backward compatibility - returns only results
    func fetchAllResults() async -> [ProviderIdentifier: ProviderResult] {
        let fetchResult = await fetchAll()
        return fetchResult.results
    }

    /// Calculates total overage cost from all pay-as-you-go providers
    /// - Parameter results: Results from fetchAll()
    /// - Returns: Total cost in dollars (0.0 if no overage)
    func calculateTotalOverageCost(from results: [ProviderIdentifier: ProviderResult]) -> Double {
        var totalCost = 0.0
        for (_, result) in results {
            if let cost = result.usage.cost {
                totalCost += cost
            }
        }
        logger.debug("Total overage cost: $\(String(format: "%.2f", totalCost))")
        return totalCost
    }

    /// Identifies providers with low quota (<20% remaining)
    /// - Parameter results: Results from fetchAll()
    /// - Returns: Array of (provider, remaining percentage) tuples for providers below threshold
    func getQuotaAlerts(from results: [ProviderIdentifier: ProviderResult]) -> [(ProviderIdentifier, Double)] {
        let alerts = results.compactMap { identifier, result -> (ProviderIdentifier, Double)? in
            switch result.usage {
            case .quotaBased(let remaining, let entitlement, _):
                guard entitlement > 0 else { return nil }

                let remainingPercentage = (Double(remaining) / Double(entitlement)) * 100.0

                // Alert if remaining < 20%
                if remainingPercentage < 20.0 {
                    logger.warning("⚠️ \(identifier.displayName) quota alert: \(String(format: "%.1f", remainingPercentage))% remaining")
                    return (identifier, remainingPercentage)
                }
                return nil

            case .payAsYouGo:
                // Pay-as-you-go providers don't have quota alerts
                return nil
            }
        }

        logger.debug("Quota alerts: \(alerts.count) provider(s) below 20%")
        return alerts
    }

    /// Gets all registered providers
    /// - Returns: Array of all provider instances
    func getAllProviders() -> [ProviderProtocol] {
        return providers
    }

    /// Gets a specific provider by identifier
    /// - Parameter identifier: The provider identifier to find
    /// - Returns: The provider instance, or nil if not found
    func getProvider(for identifier: ProviderIdentifier) -> ProviderProtocol? {
        return providers.first { $0.identifier == identifier }
    }

    // MARK: - Private Helpers

    /// Fetches usage from a provider with timeout
    /// - Parameter provider: The provider to fetch from
    /// - Returns: ProviderResult data
    /// - Throws: ProviderError or timeout error
    private func fetchProvider(_ provider: ProviderProtocol) async -> (ProviderIdentifier, ProviderResult?, String?) {
        let identifier = provider.identifier

        if let inFlight = inFlightFetches[identifier] {
            logger.info("🟡 [ProviderManager] Joining in-flight fetch for \(provider.identifier.displayName)")
            debugLog("🟡 Joining in-flight fetch for \(provider.identifier.displayName)")
            return await resolveFetch(provider: provider, inFlight: inFlight)
        }

        if let throttled = throttledFetchOutcome(for: provider) {
            if throttled.result != nil {
                logger.info("🟡 [ProviderManager] Skipping \(provider.identifier.displayName) network fetch due to minimum interval")
                debugLog("🟡 Skipping \(provider.identifier.displayName) network fetch due to minimum interval")
            } else if let errorMessage = throttled.errorMessage {
                logger.warning("🟡 [ProviderManager] Returning throttled error for \(provider.identifier.displayName): \(errorMessage)")
                debugLog("🟡 Returning throttled error for \(provider.identifier.displayName): \(errorMessage)")
            }
            return (identifier, throttled.result, throttled.errorMessage)
        }

        logger.debug("🟡 [ProviderManager] Fetching \(provider.identifier.displayName)")
        debugLog("🟡 Fetching \(provider.identifier.displayName)")

        lastNetworkFetchAt[identifier] = Date()
        let token = UUID()
        let task = Task<ProviderResult, Error> {
            try await self.fetchWithTimeout(provider: provider)
        }
        let inFlight = InFlightProviderFetch(token: token, task: task)
        inFlightFetches[identifier] = inFlight

        return await resolveFetch(provider: provider, inFlight: inFlight)
    }

    private func resolveFetch(
        provider: ProviderProtocol,
        inFlight: InFlightProviderFetch
    ) async -> (ProviderIdentifier, ProviderResult?, String?) {
        let identifier = provider.identifier

        do {
            let result = try await inFlight.task.value
            cachedResults[identifier] = result
            lastProviderErrors[identifier] = nil
            clearInFlightFetch(identifier: identifier, token: inFlight.token)

            logger.info("🟢 [ProviderManager] ✓ \(provider.identifier.displayName) fetch succeeded")
            debugLog("🟢 ✓ \(provider.identifier.displayName) fetch succeeded")

            return (identifier, result, nil)
        } catch {
            let errorMessage = error.localizedDescription
            lastProviderErrors[identifier] = errorMessage
            clearInFlightFetch(identifier: identifier, token: inFlight.token)

            logger.error("🔴 [ProviderManager] ✗ \(provider.identifier.displayName) fetch failed: \(errorMessage)")
            debugLog("🔴 ✗ \(provider.identifier.displayName) fetch failed: \(errorMessage)")

            let cached = cachedResults[identifier]
            if cached != nil {
                logger.warning("🟡 [ProviderManager] Using cached value for \(provider.identifier.displayName)")
                debugLog("🟡 Using cached value for \(provider.identifier.displayName)")
            } else {
                logger.warning("🔴 [ProviderManager] No cached value available for \(provider.identifier.displayName)")
                debugLog("🔴 No cached value available for \(provider.identifier.displayName)")
            }

            return (identifier, cached, errorMessage)
        }
    }

    private func clearInFlightFetch(identifier: ProviderIdentifier, token: UUID) {
        guard let current = inFlightFetches[identifier], current.token == token else {
            return
        }
        inFlightFetches[identifier] = nil
    }

    private func throttledFetchOutcome(for provider: ProviderProtocol) -> ThrottledFetchOutcome? {
        let minimumInterval = provider.minimumFetchInterval
        guard minimumInterval > 0,
              let lastFetchAt = lastNetworkFetchAt[provider.identifier] else {
            return nil
        }

        let elapsed = Date().timeIntervalSince(lastFetchAt)
        guard elapsed < minimumInterval else {
            return nil
        }

        let remaining = minimumInterval - elapsed
        let cached = cachedResults[provider.identifier]
        let lastErrorMessage = lastProviderErrors[provider.identifier]

        if let lastErrorMessage, isRateLimitedError(lastErrorMessage) {
            let retryMessage = "Rate limited. Retrying in \(formatCooldownDuration(remaining))."
            return ThrottledFetchOutcome(result: cached, errorMessage: retryMessage)
        }

        if let cached {
            return ThrottledFetchOutcome(result: cached, errorMessage: nil)
        }

        if let lastErrorMessage {
            return ThrottledFetchOutcome(
                result: nil,
                errorMessage: "\(lastErrorMessage) Retrying in \(formatCooldownDuration(remaining))."
            )
        }

        return ThrottledFetchOutcome(
            result: nil,
            errorMessage: "Waiting \(formatCooldownDuration(remaining)) before the next refresh."
        )
    }

    private func isRateLimitedError(_ errorMessage: String) -> Bool {
        let lowercased = errorMessage.lowercased()
        return lowercased.contains("rate limited")
            || lowercased.contains("rate_limit_error")
            || lowercased.contains("http 429")
            || lowercased.contains("too many requests")
    }

    private func formatCooldownDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded(.up)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return "\(minutes)m"
        }
        return "\(seconds)s"
    }

    private func fetchWithTimeout(provider: ProviderProtocol) async throws -> ProviderResult {
        let timeout = provider.fetchTimeout
        return try await withThrowingTaskGroup(of: ProviderResult.self) { group in
            // Add fetch task
            group.addTask {
                try await provider.fetch()
            }

            // Add timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ProviderError.networkError("Fetch timeout after \(timeout)s")
            }

            // Return first result (either success or timeout)
            guard let result = try await group.next() else {
                throw ProviderError.networkError("Task group failed")
            }

            // Cancel remaining task
            group.cancelAll()

            return result
        }
    }
}
