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
        .claude, .codex, .commandCode, .cursor, .geminiCLI, .openRouter,
        .antigravity, .openCode, .openCodeZen, .openCodeGo, .grok, .kimiCN, .kimi, .minimaxCodingPlanCN, .minimaxCodingPlan, .zaiCodingPlan,
        .nanoGpt,
        .chutes, .copilot,
        .synthetic, .volcanoArk,
        .mimo, .hunyuan, .zhipuGLM,
        .tavilySearch, .braveSearch
    ]
    
    // MARK: - Initialization
    
    init() {
        // Initialize all providers
        // Shared providers (no UI dependencies)
        let claudeProvider = ClaudeProvider()
        let codexProvider = CodexProvider()
        let commandCodeProvider = CommandCodeProvider()
        let cursorProvider = CursorProvider()
        let geminiCLIProvider = GeminiCLIProvider()
        let openRouterProvider = OpenRouterProvider()
        let antigravityProvider = AntigravityProvider()
        let openCodeProvider = OpenCodeProvider()
        let openCodeZenProvider = OpenCodeZenProvider()
        let openCodeGoProvider = OpenCodeGoProvider()
        let grokProvider = GrokProvider()
        let kimiCNProvider = KimiCNProvider()
        let kimiGlobalProvider = KimiGlobalProvider()
        let minimaxCNProvider = MiniMaxCNProvider()
        let minimaxGlobalProvider = MiniMaxGlobalProvider()
        let zaiCodingPlanProvider = ZaiCodingPlanProvider()
        let nanoGptProvider = NanoGptProvider()
        let chutesProvider = ChutesProvider()
        let syntheticProvider = SyntheticProvider()

        // Volcano Ark (CN quota-based provider)
        let volcanoArkProvider = VolcanoArkProvider()

        // Catalog-only CN providers (no public usage API yet)
        let mimoProvider = MimoProvider()
        let hunyuanProvider = HunyuanProvider()
        let zhipuGLMProvider = ZhipuGLMProvider()

        // Search engine providers
        let tavilySearchProvider = TavilySearchProvider()
        let braveSearchProvider = BraveSearchProvider()

        // 1 CLI-specific provider (uses browser cookies instead of WebView)
        let copilotCLIProvider = CopilotCLIProvider()

        self.providers = [
            claudeProvider,
            codexProvider,
            commandCodeProvider,
            cursorProvider,
            geminiCLIProvider,
            openRouterProvider,
            antigravityProvider,
            openCodeProvider,
            openCodeZenProvider,
            openCodeGoProvider,
            grokProvider,
            kimiCNProvider,
            kimiGlobalProvider,
            minimaxCNProvider,
            minimaxGlobalProvider,
            zaiCodingPlanProvider,
            nanoGptProvider,
            chutesProvider,
            copilotCLIProvider,
            syntheticProvider,
            volcanoArkProvider,
            mimoProvider,
            hunyuanProvider,
            zhipuGLMProvider,
            tavilySearchProvider,
            braveSearchProvider
        ]

        let providerCount = providers.count
        logger.info("CLIProviderManager initialized with \(providerCount) providers")
    }
    
    // MARK: - Public API
    
    /// Fetches usage data from all providers in parallel
    /// - Returns: Dictionary mapping provider identifiers to their results
    /// - Note: Returns partial results if some providers fail (graceful degradation)
    func fetchAll() async -> [ProviderIdentifier: ProviderResult] {
        let providerCount = providers.count
        logger.info("🔵 [CLIProviderManager] fetchAll() started - \(providerCount) providers")
        
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
        
        logger.info("🟢 [CLIProviderManager] fetchAll() completed: \(results.count)/\(providerCount) providers succeeded")
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
