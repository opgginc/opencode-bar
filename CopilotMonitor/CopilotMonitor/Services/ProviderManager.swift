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
            ZaiCodingPlanProvider(),
            OpenRouterProvider(),
            AntigravityProvider(),
            OpenCodeZenProvider(),
            KimiProvider(),
            ChutesProvider()
        ]
    }

    // Per-provider timeout is now defined in ProviderProtocol.fetchTimeout

    /// Last successful fetch results (used as fallback on errors)
    /// Access via updateCache/getCache methods for thread safety
    private var cachedResults: [ProviderIdentifier: ProviderResult] = [:]

    // MARK: - Initialization

    private init() {
        providers = Self.makeDefaultProviders()
        logger.info("ProviderManager initialized with \(self.providers.count) providers")
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

                    // Fetch with timeout
                    do {
                        logger.debug("🟡 [ProviderManager] Fetching \(provider.identifier.displayName)")
                        let result = try await self.fetchWithTimeout(provider: provider)

                        // Cache successful result (async-safe using Task)
                        await self.updateCache(identifier: provider.identifier, result: result)

                        logger.info("🟢 [ProviderManager] ✓ \(provider.identifier.displayName) fetch succeeded")
                        self.debugLog("🟢 ✓ \(provider.identifier.displayName) fetch succeeded")

                        return (provider.identifier, result, nil)
                    } catch {
                        let errorMessage = error.localizedDescription
                        logger.error("🔴 [ProviderManager] ✗ \(provider.identifier.displayName) fetch failed: \(errorMessage)")
                        self.debugLog("🔴 ✗ \(provider.identifier.displayName) fetch failed: \(errorMessage)")

                        // Try to use cached value as fallback
                        let cached = await self.getCache(identifier: provider.identifier)

                        if cached != nil {
                            logger.warning("🟡 [ProviderManager] Using cached value for \(provider.identifier.displayName)")
                            self.debugLog("🟡 Using cached value for \(provider.identifier.displayName)")
                        } else {
                            logger.warning("🔴 [ProviderManager] No cached value available for \(provider.identifier.displayName)")
                            self.debugLog("🔴 No cached value available for \(provider.identifier.displayName)")
                        }

                        // Return both cached result (if any) and error message
                        return (provider.identifier, cached, errorMessage)
                    }
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

    /// Thread-safe cache update
    /// - Parameters:
    ///   - identifier: Provider identifier
    ///   - result: Result data to cache
    private func updateCache(identifier: ProviderIdentifier, result: ProviderResult) async {
        cachedResults[identifier] = result
    }

    /// Thread-safe cache retrieval (async-safe using Task isolation)
    /// - Parameter identifier: Provider identifier
    /// - Returns: Cached result data or nil
    private func getCache(identifier: ProviderIdentifier) async -> ProviderResult? {
        return cachedResults[identifier]
    }
}
