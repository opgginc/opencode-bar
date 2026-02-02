import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "CLIProviderManager")

/// Manages all CLI-compatible providers and coordinates parallel fetching
/// Handles timeouts and graceful degradation for individual provider failures
actor CLIProviderManager {
    // MARK: - Properties
    
    private let providers: [any ProviderProtocol]
    
    private let fetchTimeout: TimeInterval = 10.0
    
    static let registeredProviders: [ProviderIdentifier] = [
        .claude, .codex, .geminiCLI, .openRouter, 
        .antigravity, .openCodeZen, .kimi, .copilot
    ]
    
    // MARK: - Initialization
    
    init() {
        // Initialize all 8 providers
        // 7 shared providers (no UI dependencies)
        let claudeProvider = ClaudeProvider()
        let codexProvider = CodexProvider()
        let geminiCLIProvider = GeminiCLIProvider()
        let openRouterProvider = OpenRouterProvider()
        let antigravityProvider = AntigravityProvider()
        let openCodeZenProvider = OpenCodeZenProvider()
        let kimiProvider = KimiProvider()
        
        // 1 CLI-specific provider (uses browser cookies instead of WebView)
        let copilotCLIProvider = CopilotCLIProvider()
        
        self.providers = [
            claudeProvider,
            codexProvider,
            geminiCLIProvider,
            openRouterProvider,
            antigravityProvider,
            openCodeZenProvider,
            kimiProvider,
            copilotCLIProvider
        ]
        
        logger.info("CLIProviderManager initialized with \(self.providers.count) providers")
    }
    
    // MARK: - Public API
    
    /// Fetches usage data from all providers in parallel
    /// - Returns: Dictionary mapping provider identifiers to their results
    /// - Note: Returns partial results if some providers fail (graceful degradation)
    func fetchAll() async -> [ProviderIdentifier: ProviderResult] {
        logger.info("🔵 [CLIProviderManager] fetchAll() started - \(self.providers.count) providers")
        
        var results: [ProviderIdentifier: ProviderResult] = [:]
        
        // Use TaskGroup for parallel fetching with timeout
        await withTaskGroup(of: (ProviderIdentifier, ProviderResult?).self) { group in
            for provider in self.providers {
                logger.debug("🟡 [CLIProviderManager] Adding fetch task for \(provider.identifier.displayName)")
                
                group.addTask { [weak self] in
                    guard let self = self else {
                        logger.warning("🔴 [CLIProviderManager] Self deallocated for \(provider.identifier.displayName)")
                        return (provider.identifier, nil)
                    }
                    
                    // Fetch with timeout
                    do {
                        logger.debug("🟡 [CLIProviderManager] Fetching \(provider.identifier.displayName)")
                        let result = try await self.fetchWithTimeout(provider: provider)
                        
                        logger.info("🟢 [CLIProviderManager] ✓ \(provider.identifier.displayName) fetch succeeded")
                        return (provider.identifier, result)
                    } catch {
                        logger.error("🔴 [CLIProviderManager] ✗ \(provider.identifier.displayName) fetch failed: \(error.localizedDescription)")
                        
                        // Return nil for failed providers (graceful degradation)
                        return (provider.identifier, nil)
                    }
                }
            }
            
            // Collect results from all tasks
            logger.debug("🟡 [CLIProviderManager] Collecting results from task group")
            
            for await (identifier, result) in group {
                if let result = result {
                    results[identifier] = result
                    logger.debug("🟢 [CLIProviderManager] Collected result for \(identifier.displayName)")
                } else {
                    logger.warning("🔴 [CLIProviderManager] No result for \(identifier.displayName)")
                }
            }
        }
        
        logger.info("🟢 [CLIProviderManager] fetchAll() completed: \(results.count)/\(self.providers.count) providers succeeded")
        return results
    }
    
    // MARK: - Private Helpers
    
    /// Fetches provider data with timeout protection
    /// - Parameter provider: Provider to fetch from
    /// - Returns: ProviderResult on success
    /// - Throws: ProviderError on timeout or fetch failure
    private func fetchWithTimeout(provider: ProviderProtocol) async throws -> ProviderResult {
        return try await withThrowingTaskGroup(of: ProviderResult.self) { group in
            // Add fetch task
            group.addTask {
                try await provider.fetch()
            }
            
            // Add timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.fetchTimeout * 1_000_000_000))
                throw ProviderError.networkError("Fetch timeout after \(self.fetchTimeout)s")
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
