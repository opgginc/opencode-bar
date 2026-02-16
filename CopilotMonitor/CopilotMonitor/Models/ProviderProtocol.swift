import Foundation

/// Defines the type of provider based on billing model
enum ProviderType {
    /// Pay-as-you-go model (e.g., OpenRouter, OpenCode)
    case payAsYouGo
    /// Quota-based model with monthly reset (e.g., Copilot, Claude, Codex, Gemini CLI)
    case quotaBased
}

/// Identifies the specific AI provider
enum ProviderIdentifier: String, CaseIterable {
    case copilot
    case claude
    case codex
    case geminiCLI = "gemini_cli"
    case openRouter = "openrouter"
    case openCode = "open_code"
    case antigravity
    case openCodeZen = "opencode_zen"
    case kimi
    case zaiCodingPlan = "zai_coding_plan"
    case nanoGpt = "nano_gpt"
    case synthetic
    case chutes

    var displayName: String {
        switch self {
        case .copilot:
            return "GitHub Copilot"
        case .claude:
            return "Claude"
        case .codex:
            return "ChatGPT"
        case .geminiCLI:
            return "Gemini CLI"
        case .openRouter:
            return "OpenRouter"
        case .openCode:
            return "OpenCode"
        case .antigravity:
            return "Antigravity"
        case .openCodeZen:
            return "OpenCode Zen"
        case .kimi:
            return "Kimi for Coding"
        case .zaiCodingPlan:
            return "Z.AI Coding Plan"
        case .nanoGpt:
            return "Nano-GPT"
        case .synthetic:
            return "Synthetic"
        case .chutes:
            return "Chutes AI"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .copilot:
            return "Copilot"
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .geminiCLI:
            return "Gemini"
        case .openRouter:
            return "Router"
        case .openCode:
            return "OpenCode"
        case .antigravity:
            return "Google"
        case .openCodeZen:
            return "Zen"
        case .kimi:
            return "Kimi"
        case .zaiCodingPlan:
            return "Z.AI"
        case .nanoGpt:
            return "Nano"
        case .synthetic:
            return "Synth"
        case .chutes:
            return "Chutes"
        }
    }

    var iconName: String {
        switch self {
        case .copilot:
            return "github"
        case .claude:
            return "brain.head.profile"
        case .codex:
            return "sparkles"
        case .geminiCLI:
            return "g.circle"
        case .openRouter:
            return "network"
        case .openCode:
            return "terminal"
        case .antigravity:
            return "arrow.up.circle"
        case .openCodeZen:
            return "moon.stars"
        case .kimi:
            return "k.circle"
        case .zaiCodingPlan:
            return "globe"
        case .nanoGpt:
            return "NanoGptIcon"
        case .synthetic:
            return "SyntheticIcon"
        case .chutes:
            return "c.circle"
        }
    }
}

/// Protocol for fetching usage data from AI providers
protocol ProviderProtocol: AnyObject {
    /// The identifier for this provider
    var identifier: ProviderIdentifier { get }

    /// The type of billing model this provider uses
    var type: ProviderType { get }

    /// Timeout for fetch operations (default: 10 seconds)
    var fetchTimeout: TimeInterval { get }

    /// Fetches current usage data from the provider
    /// - Returns: ProviderResult containing usage and optional detailed information
    /// - Throws: ProviderError if fetch fails
    func fetch() async throws -> ProviderResult
}

extension ProviderProtocol {
    var fetchTimeout: TimeInterval { 10.0 }
}

/// Errors that can occur during provider operations
enum ProviderError: LocalizedError {
    /// Authentication token is missing or invalid
    case authenticationFailed(String)
    /// Network request failed
    case networkError(String)
    /// Failed to parse API response
    case decodingError(String)
    /// Provider-specific error
    case providerError(String)
    /// Unsupported operation for this provider
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed(let message):
            return "Authentication failed: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .decodingError(let message):
            return "Failed to decode response: \(message)"
        case .providerError(let message):
            return "Provider error: \(message)"
        case .unsupported(let message):
            return "Unsupported: \(message)"
        }
    }
}
