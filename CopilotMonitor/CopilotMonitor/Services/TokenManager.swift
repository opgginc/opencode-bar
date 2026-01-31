import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "TokenManager")

// MARK: - Data Structures for JSON Parsing

/// OpenCode Auth structure for ~/.local/share/opencode/auth.json
struct OpenCodeAuth: Codable {
    struct OAuth: Codable {
        let type: String
        let access: String
        let refresh: String
        let expires: Int64
        let accountId: String?
        
        enum CodingKeys: String, CodingKey {
            case type, access, refresh, expires
            case accountId = "accountId"
        }
    }
    
    struct APIKey: Codable {
        let type: String
        let key: String
    }
    
    let anthropic: OAuth?
    let openai: OAuth?
    let githubCopilot: OAuth?
    let openrouter: APIKey?
    let opencode: APIKey?
    
    enum CodingKeys: String, CodingKey {
        case anthropic, openai, openrouter, opencode
        case githubCopilot = "github-copilot"
    }
}

/// Antigravity Accounts structure for ~/.config/opencode/antigravity-accounts.json
struct AntigravityAccounts: Codable {
    struct Account: Codable {
        let email: String
        let refreshToken: String
        let projectId: String
        let rateLimitResetTimes: [String: Int64]?
    }
    
    let version: Int
    let accounts: [Account]
    let activeIndex: Int
}

/// Gemini OAuth token response structure
struct GeminiTokenResponse: Codable {
    let access_token: String
    let expires_in: Int
    let token_type: String?
}

// MARK: - TokenManager Singleton

final class TokenManager {
    static let shared = TokenManager()
    
    private init() {
        logger.info("TokenManager initialized")
    }
    
    // MARK: - OpenCode Auth File Reading
    
    /// Reads OpenCode auth tokens from ~/.local/share/opencode/auth.json
    /// - Returns: OpenCodeAuth structure if file exists and is valid, nil otherwise
    func readOpenCodeAuth() -> OpenCodeAuth? {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let authPath = homeDir
            .appendingPathComponent(".local")
            .appendingPathComponent("share")
            .appendingPathComponent("opencode")
            .appendingPathComponent("auth.json")
        
        guard fileManager.fileExists(atPath: authPath.path) else {
            logger.debug("OpenCode auth file not found at: \(authPath.path)")
            return nil
        }
        
        do {
            let data = try Data(contentsOf: authPath)
            let auth = try JSONDecoder().decode(OpenCodeAuth.self, from: data)
            logger.info("Successfully loaded OpenCode auth")
            return auth
        } catch {
            logger.error("Failed to read OpenCode auth: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Antigravity Accounts File Reading
    
    /// Reads Antigravity accounts from ~/.config/opencode/antigravity-accounts.json
    /// - Returns: AntigravityAccounts structure if file exists and is valid, nil otherwise
    func readAntigravityAccounts() -> AntigravityAccounts? {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let accountsPath = homeDir
            .appendingPathComponent(".config")
            .appendingPathComponent("opencode")
            .appendingPathComponent("antigravity-accounts.json")
        
        guard fileManager.fileExists(atPath: accountsPath.path) else {
            logger.debug("Antigravity accounts file not found at: \(accountsPath.path)")
            return nil
        }
        
        do {
            let data = try Data(contentsOf: accountsPath)
            let accounts = try JSONDecoder().decode(AntigravityAccounts.self, from: data)
            logger.info("Successfully loaded Antigravity accounts")
            return accounts
        } catch {
            logger.error("Failed to read Antigravity accounts: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Token Accessors
    
    /// Gets Anthropic (Claude) access token from OpenCode auth
    /// - Returns: Access token string if available, nil otherwise
    func getAnthropicAccessToken() -> String? {
        guard let auth = readOpenCodeAuth() else { return nil }
        return auth.anthropic?.access
    }
    
    /// Gets OpenAI access token from OpenCode auth
    /// - Returns: Access token string if available, nil otherwise
    func getOpenAIAccessToken() -> String? {
        guard let auth = readOpenCodeAuth() else { return nil }
        return auth.openai?.access
    }
    
    /// Gets GitHub Copilot access token from OpenCode auth
    /// - Returns: Access token string if available, nil otherwise
    func getGitHubCopilotAccessToken() -> String? {
        guard let auth = readOpenCodeAuth() else { return nil }
        return auth.githubCopilot?.access
    }
    
    /// Gets OpenRouter API key from OpenCode auth
    /// - Returns: API key string if available, nil otherwise
    func getOpenRouterAPIKey() -> String? {
        guard let auth = readOpenCodeAuth() else { return nil }
        return auth.openrouter?.key
    }
    
    /// Gets OpenCode API key from OpenCode auth
    /// - Returns: API key string if available, nil otherwise
    func getOpenCodeAPIKey() -> String? {
        guard let auth = readOpenCodeAuth() else { return nil }
        return auth.opencode?.key
    }
    
    /// Gets Gemini refresh token from Antigravity accounts (active account)
    /// - Returns: Refresh token string if available, nil otherwise
    func getGeminiRefreshToken() -> String? {
        guard let accounts = readAntigravityAccounts() else { return nil }
        guard accounts.activeIndex >= 0 && accounts.activeIndex < accounts.accounts.count else {
            logger.warning("Invalid activeIndex: \(accounts.activeIndex)")
            return nil
        }
        return accounts.accounts[accounts.activeIndex].refreshToken
    }
    
    /// Gets Gemini account email from Antigravity accounts (active account)
    /// - Returns: Email string if available, nil otherwise
    func getGeminiAccountEmail() -> String? {
        guard let accounts = readAntigravityAccounts() else { return nil }
        guard accounts.activeIndex >= 0 && accounts.activeIndex < accounts.accounts.count else {
            logger.warning("Invalid activeIndex: \(accounts.activeIndex)")
            return nil
        }
        return accounts.accounts[accounts.activeIndex].email
    }
    
    /// Gets all Gemini accounts from Antigravity accounts file
    /// - Returns: Array of (index, email, refreshToken) tuples for all accounts
    func getAllGeminiAccounts() -> [(index: Int, email: String, refreshToken: String)] {
        guard let accounts = readAntigravityAccounts() else { return [] }
        return accounts.accounts.enumerated().map { (index, account) in
            (index: index, email: account.email, refreshToken: account.refreshToken)
        }
    }
    
    /// Gets the count of registered Gemini accounts
    func getGeminiAccountCount() -> Int {
        return readAntigravityAccounts()?.accounts.count ?? 0
    }
    
    // MARK: - Gemini OAuth Token Refresh
    
    /// Refreshes Gemini OAuth access token using refresh token
    /// - Parameters:
    ///   - refreshToken: The refresh token from Antigravity accounts
    ///   - clientId: Google OAuth client ID (default: OpenCode's client ID)
    ///   - clientSecret: Google OAuth client secret (default: OpenCode's client secret)
    /// - Returns: New access token if successful, nil otherwise
    func refreshGeminiAccessToken(
        refreshToken: String,
        clientId: String = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com",
        clientSecret: String = "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"
    ) async -> String? {
        let endpoint = "https://oauth2.googleapis.com/token"
        
        guard let url = URL(string: endpoint) else {
            logger.error("Invalid OAuth endpoint URL")
            return nil
        }
        
        // Build request body
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ]
        
        guard let bodyString = components.query else {
            logger.error("Failed to build request body")
            return nil
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyString.data(using: .utf8)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Invalid response type")
                return nil
            }
            
            guard httpResponse.statusCode == 200 else {
                logger.error("OAuth token refresh failed with status: \(httpResponse.statusCode)")
                return nil
            }
            
            let tokenResponse = try JSONDecoder().decode(GeminiTokenResponse.self, from: data)
            logger.info("Successfully refreshed Gemini access token")
            return tokenResponse.access_token
        } catch {
            logger.error("Failed to refresh Gemini token: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Convenience method to refresh Gemini token using stored refresh token
    /// - Returns: New access token if successful, nil otherwise
    func refreshGeminiAccessTokenFromStorage() async -> String? {
        guard let refreshToken = getGeminiRefreshToken() else {
            logger.warning("No Gemini refresh token found in storage")
            return nil
        }
        
        return await refreshGeminiAccessToken(refreshToken: refreshToken)
    }
}
