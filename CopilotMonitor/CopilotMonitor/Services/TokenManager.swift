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
    let kimiForCoding: APIKey?
    let zaiCodingPlan: APIKey?

    enum CodingKeys: String, CodingKey {
        case anthropic, openai, openrouter, opencode
        case githubCopilot = "github-copilot"
        case kimiForCoding = "kimi-for-coding"
        case zaiCodingPlan = "zai-coding-plan"
    }

    init(
        anthropic: OAuth?,
        openai: OAuth?,
        githubCopilot: OAuth?,
        openrouter: APIKey?,
        opencode: APIKey?,
        kimiForCoding: APIKey?,
        zaiCodingPlan: APIKey?
    ) {
        self.anthropic = anthropic
        self.openai = openai
        self.githubCopilot = githubCopilot
        self.openrouter = openrouter
        self.opencode = opencode
        self.kimiForCoding = kimiForCoding
        self.zaiCodingPlan = zaiCodingPlan
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        anthropic = try container.decodeIfPresent(OAuth.self, forKey: .anthropic)
        openai = try container.decodeIfPresent(OAuth.self, forKey: .openai)
        githubCopilot = try container.decodeIfPresent(OAuth.self, forKey: .githubCopilot)
        openrouter = try container.decodeIfPresent(APIKey.self, forKey: .openrouter)
        opencode = try container.decodeIfPresent(APIKey.self, forKey: .opencode)
        kimiForCoding = try container.decodeIfPresent(APIKey.self, forKey: .kimiForCoding)
        zaiCodingPlan = try container.decodeIfPresent(APIKey.self, forKey: .zaiCodingPlan)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(anthropic, forKey: .anthropic)
        try container.encodeIfPresent(openai, forKey: .openai)
        try container.encodeIfPresent(githubCopilot, forKey: .githubCopilot)
        try container.encodeIfPresent(openrouter, forKey: .openrouter)
        try container.encodeIfPresent(opencode, forKey: .opencode)
        try container.encodeIfPresent(kimiForCoding, forKey: .kimiForCoding)
        try container.encodeIfPresent(zaiCodingPlan, forKey: .zaiCodingPlan)
    }
}

/// Codex CLI native auth structure for ~/.codex/auth.json
/// Different format from OpenCode auth - used as fallback when OpenCode has no OpenAI token
struct CodexAuth: Codable {
    struct Tokens: Codable {
        let accessToken: String?
        let accountId: String?
        let idToken: String?
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountId = "account_id"
            case idToken = "id_token"
            case refreshToken = "refresh_token"
        }
    }

    let openaiAPIKey: String?
    let tokens: Tokens?
    let lastRefresh: String?

    enum CodingKeys: String, CodingKey {
        case openaiAPIKey = "OPENAI_API_KEY"
        case tokens
        case lastRefresh = "last_refresh"
    }
}

/// Antigravity Accounts structure for ~/.config/opencode/antigravity-accounts.json
struct AntigravityAccounts: Codable {
    struct Account: Codable {
        let email: String
        let refreshToken: String
        let projectId: String
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

final class TokenManager: @unchecked Sendable {
    static let shared = TokenManager()
    
    /// Serial queue for thread-safe file access
    private let queue = DispatchQueue(label: "com.opencodeproviders.TokenManager")
    
    /// Cached auth data with timestamp
    private var cachedAuth: OpenCodeAuth?
    private var cacheTimestamp: Date?
    private let cacheValiditySeconds: TimeInterval = 30 // Cache for 30 seconds
    
    /// Cached antigravity accounts
    private var cachedAntigravityAccounts: AntigravityAccounts?
    private var antigravityCacheTimestamp: Date?

    private init() {
        logger.info("TokenManager initialized")
    }

    // MARK: - OpenCode Auth File Reading

    /// Possible auth.json locations in priority order:
    /// 1. $XDG_DATA_HOME/opencode/auth.json (if XDG_DATA_HOME is set)
    /// 2. ~/.local/share/opencode/auth.json (XDG default, used by OpenCode)
    /// 3. ~/Library/Application Support/opencode/auth.json (macOS convention fallback)
    func getAuthFilePaths() -> [URL] {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        var paths: [URL] = []

        // 1. XDG_DATA_HOME (highest priority if set)
        if let xdgDataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdgDataHome.isEmpty {
            let xdgPath = URL(fileURLWithPath: xdgDataHome)
                .appendingPathComponent("opencode")
                .appendingPathComponent("auth.json")
            paths.append(xdgPath)
        }

        // 2. ~/.local/share/opencode/auth.json (XDG default - OpenCode's primary location)
        let xdgDefaultPath = homeDir
            .appendingPathComponent(".local")
            .appendingPathComponent("share")
            .appendingPathComponent("opencode")
            .appendingPathComponent("auth.json")
        paths.append(xdgDefaultPath)

        // 3. ~/Library/Application Support/opencode/auth.json (macOS convention fallback)
        let macOSPath = homeDir
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("opencode")
            .appendingPathComponent("auth.json")
        paths.append(macOSPath)

        return paths
    }

    /// Returns the path where auth.json was found, or nil if not found
    /// Useful for displaying in UI to help users troubleshoot
    private(set) var lastFoundAuthPath: URL?

    /// Thread-safe read of OpenCode auth tokens with caching
    func readOpenCodeAuth() -> OpenCodeAuth? {
        return queue.sync {
            // Return cached data if still valid
            if let cached = cachedAuth,
               let timestamp = cacheTimestamp,
               Date().timeIntervalSince(timestamp) < cacheValiditySeconds {
                return cached
            }
            
            let fileManager = FileManager.default
            let paths = getAuthFilePaths()
            
            for authPath in paths {
                guard fileManager.fileExists(atPath: authPath.path) else {
                    continue
                }
                
                do {
                    let data = try Data(contentsOf: authPath)
                    let auth = try JSONDecoder().decode(OpenCodeAuth.self, from: data)
                    lastFoundAuthPath = authPath
                    cachedAuth = auth
                    cacheTimestamp = Date()
                    logger.info("Successfully loaded OpenCode auth from: \(authPath.path)")
                    return auth
                } catch {
                    logger.warning("Failed to parse auth at \(authPath.path): \(error.localizedDescription)")
                    continue
                }
            }
            
            lastFoundAuthPath = nil
            cachedAuth = nil
            cacheTimestamp = nil
            logger.error("No valid auth.json found in any location")
            return nil
        }
    }

    // MARK: - Codex Native Auth File Reading

    private var cachedCodexAuth: CodexAuth?
    private var codexCacheTimestamp: Date?

    func readCodexAuth() -> CodexAuth? {
        return queue.sync {
            if let cached = cachedCodexAuth,
               let timestamp = codexCacheTimestamp,
               Date().timeIntervalSince(timestamp) < cacheValiditySeconds {
                return cached
            }

            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            let codexAuthPath = homeDir
                .appendingPathComponent(".codex")
                .appendingPathComponent("auth.json")

            guard FileManager.default.fileExists(atPath: codexAuthPath.path) else {
                return nil
            }

            do {
                let data = try Data(contentsOf: codexAuthPath)
                let auth = try JSONDecoder().decode(CodexAuth.self, from: data)
                cachedCodexAuth = auth
                codexCacheTimestamp = Date()
                logger.info("Successfully loaded Codex native auth from: \(codexAuthPath.path)")
                return auth
            } catch {
                logger.warning("Failed to parse Codex auth at \(codexAuthPath.path): \(error.localizedDescription)")
                return nil
            }
        }
    }

    // MARK: - Antigravity Accounts File Reading

    /// Thread-safe read of Antigravity accounts with caching
    func readAntigravityAccounts() -> AntigravityAccounts? {
        return queue.sync {
            if let cached = cachedAntigravityAccounts,
               let timestamp = antigravityCacheTimestamp,
               Date().timeIntervalSince(timestamp) < cacheValiditySeconds {
                return cached
            }
            
            let fileManager = FileManager.default
            let homeDir = fileManager.homeDirectoryForCurrentUser
            let accountsPath = homeDir
                .appendingPathComponent(".config")
                .appendingPathComponent("opencode")
                .appendingPathComponent("antigravity-accounts.json")
            
            guard fileManager.fileExists(atPath: accountsPath.path) else {
                return nil
            }
            
            do {
                let data = try Data(contentsOf: accountsPath)
                let accounts = try JSONDecoder().decode(AntigravityAccounts.self, from: data)
                cachedAntigravityAccounts = accounts
                antigravityCacheTimestamp = Date()
                logger.info("Successfully loaded Antigravity accounts")
                return accounts
            } catch {
                logger.error("Failed to read Antigravity accounts: \(error.localizedDescription)")
                return nil
            }
        }
    }

    // MARK: - Token Accessors

    /// Gets Anthropic (Claude) access token from OpenCode auth
    /// - Returns: Access token string if available, nil otherwise
    func getAnthropicAccessToken() -> String? {
        guard let auth = readOpenCodeAuth() else { return nil }
        return auth.anthropic?.access
    }

    /// Gets OpenAI access token, first from OpenCode auth, then falling back to Codex CLI native auth (~/.codex/auth.json)
    func getOpenAIAccessToken() -> String? {
        // Primary: OpenCode auth
        if let auth = readOpenCodeAuth(), let access = auth.openai?.access {
            return access
        }
        // Fallback: Codex CLI native auth (~/.codex/auth.json)
        if let codexAuth = readCodexAuth(), let access = codexAuth.tokens?.accessToken {
            logger.info("Using Codex native auth (~/.codex/auth.json) as fallback for OpenAI access token")
            return access
        }
        return nil
    }

    /// Gets OpenAI account ID, first from OpenCode auth, then falling back to Codex CLI native auth
    func getOpenAIAccountId() -> String? {
        // Primary: OpenCode auth
        if let auth = readOpenCodeAuth(), let accountId = auth.openai?.accountId {
            return accountId
        }
        // Fallback: Codex CLI native auth (~/.codex/auth.json)
        if let codexAuth = readCodexAuth(), let accountId = codexAuth.tokens?.accountId {
            logger.info("Using Codex native auth (~/.codex/auth.json) as fallback for OpenAI account ID")
            return accountId
        }
        return nil
    }

    /// Gets GitHub Copilot access token from OpenCode auth
    /// - Returns: Access token string if available, nil otherwise
    func getGitHubCopilotAccessToken() -> String? {
        guard let auth = readOpenCodeAuth() else { return nil }
        return auth.githubCopilot?.access
    }

    /// Fetches Copilot plan and quota reset info from GitHub internal API
    /// Uses the OpenCode GitHub Copilot token
    /// - Returns: Tuple of (plan, quotaResetDateUTC) if successful, nil otherwise
    func fetchCopilotPlanInfo() async -> (plan: String, quotaResetDateUTC: Date?)? {
        guard let accessToken = getGitHubCopilotAccessToken() else {
            logger.warning("No GitHub Copilot token available for plan info fetch")
            return nil
        }

        guard let url = URL(string: "https://api.github.com/copilot_internal/user") else {
            logger.error("Invalid Copilot API URL")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("token \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Invalid response type from Copilot API")
                return nil
            }

            guard httpResponse.statusCode == 200 else {
                logger.error("Copilot API returned status: \(httpResponse.statusCode)")
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.error("Failed to parse Copilot API response")
                return nil
            }

            let plan = json["copilot_plan"] as? String ?? "unknown"
            var resetDate: Date?

            // Parse quota_reset_date_utc (format: "2026-03-01T00:00:00.000Z")
            if let resetDateStr = json["quota_reset_date_utc"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                resetDate = formatter.date(from: resetDateStr)

                // Fallback without fractional seconds
                if resetDate == nil {
                    let fallbackFormatter = ISO8601DateFormatter()
                    fallbackFormatter.formatOptions = [.withInternetDateTime]
                    resetDate = fallbackFormatter.date(from: resetDateStr)
                }
            }

            // Fallback to quota_reset_date (format: "2026-03-01")
            if resetDate == nil, let resetDateStr = json["quota_reset_date"] as? String {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"
                dateFormatter.timeZone = TimeZone(identifier: "UTC")
                resetDate = dateFormatter.date(from: resetDateStr)
            }

            if let resetDate = resetDate {
                logger.info("Copilot plan info fetched: \(plan), reset: \(resetDate)")
                return (plan: plan, quotaResetDateUTC: resetDate)
            } else {
                logger.warning("Copilot plan fetched but no reset date: \(plan)")
                return (plan: plan, quotaResetDateUTC: nil)
            }
        } catch {
            logger.error("Failed to fetch Copilot plan info: \(error.localizedDescription)")
            return nil
        }
    }

    /// Gets OpenRouter API key from OpenCode auth
    /// - Returns: API key string if available, nil otherwise
    func getOpenRouterAPIKey() -> String? {
        guard let auth = readOpenCodeAuth() else { return nil }
        return auth.openrouter?.key
    }

    func getOpenCodeAPIKey() -> String? {
        guard let auth = readOpenCodeAuth() else { return nil }
        return auth.opencode?.key
    }

    func getKimiAPIKey() -> String? {
        guard let auth = readOpenCodeAuth() else { return nil }
        return auth.kimiForCoding?.key
    }

    func getZaiCodingPlanAPIKey() -> String? {
        guard let auth = readOpenCodeAuth() else { return nil }
        return auth.zaiCodingPlan?.key
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
    /// - Returns: Array of (index, email, refreshToken, projectId) tuples for all accounts
    func getAllGeminiAccounts() -> [(index: Int, email: String, refreshToken: String, projectId: String)] {
        guard let accounts = readAntigravityAccounts() else { return [] }
        return accounts.accounts.enumerated().map { index, account in
            (index: index, email: account.email, refreshToken: account.refreshToken, projectId: account.projectId)
        }
    }

    /// Gets the count of registered Gemini accounts
    func getGeminiAccountCount() -> Int {
        return readAntigravityAccounts()?.accounts.count ?? 0
    }

    // MARK: - Gemini OAuth Token Refresh

    /// Public Google OAuth client credentials for CLI/installed apps
    /// These are NOT secrets - they are public client IDs/secrets for installed applications
    /// See: https://developers.google.com/identity/protocols/oauth2/native-app
    private static let geminiClientId = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private static let geminiClientSecret = "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"

    /// Refreshes Gemini OAuth access token using refresh token
    /// - Parameters:
    ///   - refreshToken: The refresh token from Antigravity accounts
    ///   - clientId: Google OAuth client ID (default: public CLI client ID)
    ///   - clientSecret: Google OAuth client secret (default: public CLI client secret)
    /// - Returns: New access token if successful, nil otherwise
    func refreshGeminiAccessToken(
        refreshToken: String,
        clientId: String = TokenManager.geminiClientId,
        clientSecret: String = TokenManager.geminiClientSecret
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

    // MARK: - Debug Environment Info

    /// Returns debug environment info as a string for error dialogs
    func getDebugEnvironmentInfo() -> String {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser

        var debugLines: [String] = []
        debugLines.append("Environment Info:")
        debugLines.append(String(repeating: "─", count: 40))

        // 0. XDG_DATA_HOME environment variable
        let hasXdgDataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]?.isEmpty == false
        if let xdgDataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdgDataHome.isEmpty {
            debugLines.append("[XDG_DATA_HOME] SET: \(xdgDataHome)")
        } else {
            debugLines.append("[XDG_DATA_HOME] NOT SET (using default ~/.local/share)")
        }

        // 1. Check all possible auth.json paths (fallback order)
        debugLines.append("")
        debugLines.append("Auth File Search:")
        let authPaths = getAuthFilePaths()
        var foundAuthPath: URL?

        for (index, authPath) in authPaths.enumerated() {
            let priority = index + 1
            let pathLabel: String
            if hasXdgDataHome {
                switch index {
                case 0:
                    pathLabel = "$XDG_DATA_HOME/opencode"
                case 1:
                    pathLabel = "~/.local/share/opencode"
                default:
                    pathLabel = "~/Library/Application Support/opencode"
                }
            } else {
                switch index {
                case 0:
                    pathLabel = "~/.local/share/opencode"
                default:
                    pathLabel = "~/Library/Application Support/opencode"
                }
            }

            if fileManager.fileExists(atPath: authPath.path) {
                if let content = try? String(contentsOf: authPath, encoding: .utf8) {
                    let lineCount = content.components(separatedBy: .newlines).count
                    let byteCount = content.utf8.count
                    let marker = foundAuthPath == nil ? "ACTIVE" : "SHADOWED"
                    debugLines.append("  [\(priority)] [\(marker)] \(pathLabel)/auth.json")
                    debugLines.append("      Path: \(authPath.path)")
                    debugLines.append("      Lines: \(lineCount), Bytes: \(byteCount)")
                    if foundAuthPath == nil {
                        foundAuthPath = authPath
                    }
                } else {
                    debugLines.append("  [\(priority)] [UNREADABLE] \(pathLabel)/auth.json")
                    debugLines.append("      Path: \(authPath.path)")
                }
            } else {
                debugLines.append("  [\(priority)] [NOT FOUND] \(pathLabel)/auth.json")
                debugLines.append("      Path: \(authPath.path)")
            }
        }

        if let activePath = foundAuthPath {
            debugLines.append("  [Result] Using: \(activePath.path)")
        } else {
            debugLines.append("  [Result] NO VALID auth.json FOUND")
        }

        // 2. Check ~/.config/opencode directory (antigravity-accounts.json)
        debugLines.append("")
        debugLines.append("Config Directory (~/.config/opencode):")
        let configDir = homeDir
            .appendingPathComponent(".config")
            .appendingPathComponent("opencode")

        if fileManager.fileExists(atPath: configDir.path) {
            if let contents = try? fileManager.contentsOfDirectory(atPath: configDir.path) {
                debugLines.append("  [EXISTS] \(contents.count) item(s)")
                for item in contents.sorted() {
                    var isDir: ObjCBool = false
                    let itemPath = configDir.appendingPathComponent(item).path
                    fileManager.fileExists(atPath: itemPath, isDirectory: &isDir)
                    let typeIndicator = isDir.boolValue ? "[DIR]" : "[FILE]"
                    debugLines.append("    \(typeIndicator) \(item)")
                }
            } else {
                debugLines.append("  [UNREADABLE] Unable to list contents (permission denied or error)")
            }
        } else {
            debugLines.append("  [NOT FOUND]")
        }

        // 3. Token availability summary (without revealing actual tokens)
        debugLines.append("")
        debugLines.append("Token Status:")
        if let auth = readOpenCodeAuth() {
            debugLines.append("  [Anthropic] \(auth.anthropic != nil ? "CONFIGURED" : "NOT CONFIGURED")")
            debugLines.append("  [OpenAI] \(auth.openai != nil ? "CONFIGURED" : "NOT CONFIGURED")")
            debugLines.append("  [GitHub Copilot] \(auth.githubCopilot != nil ? "CONFIGURED" : "NOT CONFIGURED")")
            debugLines.append("  [OpenRouter] \(auth.openrouter != nil ? "CONFIGURED" : "NOT CONFIGURED")")
            debugLines.append("  [OpenCode] \(auth.opencode != nil ? "CONFIGURED" : "NOT CONFIGURED")")
            debugLines.append("  [Kimi] \(auth.kimiForCoding != nil ? "CONFIGURED" : "NOT CONFIGURED")")
            debugLines.append("  [Z.AI Coding Plan] \(auth.zaiCodingPlan != nil ? "CONFIGURED" : "NOT CONFIGURED")")
        } else {
            debugLines.append("  [auth.json] PARSE FAILED or NOT FOUND")
        }

        // 4. Antigravity accounts
        if let accounts = readAntigravityAccounts() {
            let invalidMarker = accounts.activeIndex < 0 || accounts.activeIndex >= accounts.accounts.count ? " (INVALID)" : ""
            debugLines.append("  [Antigravity] \(accounts.accounts.count) account(s), active index: \(accounts.activeIndex)\(invalidMarker)")
        } else {
            debugLines.append("  [Antigravity] NOT CONFIGURED")
        }

        // 5. Codex native auth (~/.codex/auth.json) - fallback for OpenAI token
        debugLines.append("")
        debugLines.append("Codex Native Auth (~/.codex/auth.json):")
        let codexAuthPath = homeDir.appendingPathComponent(".codex").appendingPathComponent("auth.json")
        if fileManager.fileExists(atPath: codexAuthPath.path) {
            if let codexAuth = readCodexAuth() {
                let hasToken = codexAuth.tokens?.accessToken != nil
                let hasAccountId = codexAuth.tokens?.accountId != nil
                let hasAPIKey = codexAuth.openaiAPIKey != nil
                debugLines.append("  [EXISTS] token: \(hasToken ? "YES" : "NO"), accountId: \(hasAccountId ? "YES" : "NO"), apiKey: \(hasAPIKey ? "YES" : "NO")")
            } else {
                debugLines.append("  [PARSE FAILED]")
            }
        } else {
            debugLines.append("  [NOT FOUND]")
        }

        debugLines.append(String(repeating: "─", count: 40))

        return debugLines.joined(separator: "\n")
    }

    func logDebugEnvironmentInfo() {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser

        var debugLines: [String] = []
        debugLines.append("========== Environment Debug Info ==========")

        // 0. XDG_DATA_HOME environment variable
        let hasXdgDataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]?.isEmpty == false
        if let xdgDataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdgDataHome.isEmpty {
            debugLines.append("[XDG_DATA_HOME] SET: \(xdgDataHome)")
        } else {
            debugLines.append("[XDG_DATA_HOME] NOT SET (using default ~/.local/share)")
        }

        // 1. Check all possible auth.json paths (fallback order)
        debugLines.append("---------- Auth File Search ----------")
        let authPaths = getAuthFilePaths()
        var foundAuthPath: URL?

        for (index, authPath) in authPaths.enumerated() {
            let priority = index + 1
            let pathLabel: String
            if hasXdgDataHome {
                switch index {
                case 0:
                    pathLabel = "$XDG_DATA_HOME/opencode"
                case 1:
                    pathLabel = "~/.local/share/opencode"
                default:
                    pathLabel = "~/Library/Application Support/opencode"
                }
            } else {
                switch index {
                case 0:
                    pathLabel = "~/.local/share/opencode"
                default:
                    pathLabel = "~/Library/Application Support/opencode"
                }
            }

            if fileManager.fileExists(atPath: authPath.path) {
                if let content = try? String(contentsOf: authPath, encoding: .utf8) {
                    let lineCount = content.components(separatedBy: .newlines).count
                    let byteCount = content.utf8.count
                    let marker = foundAuthPath == nil ? "ACTIVE" : "SHADOWED"
                    debugLines.append("[\(priority)] [\(marker)] \(pathLabel)/auth.json")
                    debugLines.append("    Path: \(authPath.path)")
                    debugLines.append("    Lines: \(lineCount), Bytes: \(byteCount)")
                    if foundAuthPath == nil {
                        foundAuthPath = authPath
                    }
                } else {
                    debugLines.append("[\(priority)] [UNREADABLE] \(pathLabel)/auth.json")
                    debugLines.append("    Path: \(authPath.path)")
                }
            } else {
                debugLines.append("[\(priority)] [NOT FOUND] \(pathLabel)/auth.json")
                debugLines.append("    Path: \(authPath.path)")
            }
        }

        if let activePath = foundAuthPath {
            debugLines.append("[Result] Using auth from: \(activePath.path)")
        } else {
            debugLines.append("[Result] NO VALID auth.json FOUND IN ANY LOCATION")
        }

        // 2. ~/.local/share/opencode directory contents
        debugLines.append("---------- Directory Contents ----------")
        let opencodeDir = homeDir
            .appendingPathComponent(".local")
            .appendingPathComponent("share")
            .appendingPathComponent("opencode")

        if fileManager.fileExists(atPath: opencodeDir.path) {
            if let contents = try? fileManager.contentsOfDirectory(atPath: opencodeDir.path) {
                let fileCount = contents.filter { !$0.hasPrefix(".") }.count
                debugLines.append("[~/.local/share/opencode] EXISTS")
                debugLines.append("  - Items: \(fileCount)")
                for item in contents.sorted() {
                    var isDir: ObjCBool = false
                    let itemPath = opencodeDir.appendingPathComponent(item).path
                    fileManager.fileExists(atPath: itemPath, isDirectory: &isDir)
                    let typeIndicator = isDir.boolValue ? "[DIR]" : "[FILE]"
                    debugLines.append("    \(typeIndicator) \(item)")
                }
            }
        } else {
            debugLines.append("[~/.local/share/opencode] NOT FOUND")
        }

        // 3. ~/Library/Application Support/opencode directory (macOS fallback)
        let macOSDir = homeDir
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("opencode")

        if fileManager.fileExists(atPath: macOSDir.path) {
            if let contents = try? fileManager.contentsOfDirectory(atPath: macOSDir.path) {
                let fileCount = contents.filter { !$0.hasPrefix(".") }.count
                debugLines.append("[~/Library/Application Support/opencode] EXISTS")
                debugLines.append("  - Items: \(fileCount)")
                for item in contents.sorted() {
                    var isDir: ObjCBool = false
                    let itemPath = macOSDir.appendingPathComponent(item).path
                    fileManager.fileExists(atPath: itemPath, isDirectory: &isDir)
                    let typeIndicator = isDir.boolValue ? "[DIR]" : "[FILE]"
                    debugLines.append("    \(typeIndicator) \(item)")
                }
            }
        } else {
            debugLines.append("[~/Library/Application Support/opencode] NOT FOUND")
        }

        // 4. ~/.config/opencode directory (antigravity-accounts.json)
        let configDir = homeDir
            .appendingPathComponent(".config")
            .appendingPathComponent("opencode")

        if fileManager.fileExists(atPath: configDir.path) {
            if let contents = try? fileManager.contentsOfDirectory(atPath: configDir.path) {
                let fileCount = contents.filter { !$0.hasPrefix(".") }.count
                debugLines.append("[~/.config/opencode] EXISTS")
                debugLines.append("  - Items: \(fileCount)")
                for item in contents.sorted() {
                    var isDir: ObjCBool = false
                    let itemPath = configDir.appendingPathComponent(item).path
                    fileManager.fileExists(atPath: itemPath, isDirectory: &isDir)
                    let typeIndicator = isDir.boolValue ? "[DIR]" : "[FILE]"
                    debugLines.append("    \(typeIndicator) \(item)")
                }
            }
        } else {
            debugLines.append("[~/.config/opencode] NOT FOUND")
        }

        // 4. OpenCode CLI existence
        let opencodeCLI = homeDir.appendingPathComponent(".opencode/bin/opencode")
        if fileManager.fileExists(atPath: opencodeCLI.path) {
            debugLines.append("[OpenCode CLI] EXISTS at \(opencodeCLI.path)")
        } else {
            debugLines.append("[OpenCode CLI] NOT FOUND at \(opencodeCLI.path)")
        }

        // 5. Token existence and lengths (masked for security)
        debugLines.append("---------- Token Status ----------")

        if let auth = readOpenCodeAuth() {
            // Anthropic (Claude)
            if let anthropic = auth.anthropic {
                debugLines.append("[Anthropic] OAuth Present")
                debugLines.append("  - Access Token: \(anthropic.access.count) chars")
                debugLines.append("  - Refresh Token: \(anthropic.refresh.count) chars")
                debugLines.append("  - Account ID: \(anthropic.accountId ?? "nil")")
                let expiresDate = Date(timeIntervalSince1970: TimeInterval(anthropic.expires))
                let isExpired = expiresDate < Date()
                debugLines.append("  - Expires: \(expiresDate) (\(isExpired ? "EXPIRED" : "valid"))")
            } else {
                debugLines.append("[Anthropic] NOT CONFIGURED")
            }

            // OpenAI
            if let openai = auth.openai {
                debugLines.append("[OpenAI] OAuth Present")
                debugLines.append("  - Access Token: \(openai.access.count) chars")
                debugLines.append("  - Refresh Token: \(openai.refresh.count) chars")
                let expiresDate = Date(timeIntervalSince1970: TimeInterval(openai.expires))
                let isExpired = expiresDate < Date()
                debugLines.append("  - Expires: \(expiresDate) (\(isExpired ? "EXPIRED" : "valid"))")
            } else {
                debugLines.append("[OpenAI] NOT CONFIGURED")
            }

            // GitHub Copilot
            if let copilot = auth.githubCopilot {
                debugLines.append("[GitHub Copilot] OAuth Present")
                debugLines.append("  - Access Token: \(copilot.access.count) chars")
                debugLines.append("  - Refresh Token: \(copilot.refresh.count) chars")
                let expiresDate = Date(timeIntervalSince1970: TimeInterval(copilot.expires))
                let isExpired = expiresDate < Date()
                debugLines.append("  - Expires: \(expiresDate) (\(isExpired ? "EXPIRED" : "valid"))")
            } else {
                debugLines.append("[GitHub Copilot] NOT CONFIGURED")
            }

            // OpenRouter
            if let openrouter = auth.openrouter {
                debugLines.append("[OpenRouter] API Key Present")
                debugLines.append("  - Key Length: \(openrouter.key.count) chars")
                debugLines.append("  - Key Preview: \(maskToken(openrouter.key))")
            } else {
                debugLines.append("[OpenRouter] NOT CONFIGURED")
            }

            // OpenCode
            if let opencode = auth.opencode {
                debugLines.append("[OpenCode] API Key Present")
                debugLines.append("  - Key Length: \(opencode.key.count) chars")
                debugLines.append("  - Key Preview: \(maskToken(opencode.key))")
            } else {
                debugLines.append("[OpenCode] NOT CONFIGURED")
            }

            // Kimi for Coding
            if let kimi = auth.kimiForCoding {
                debugLines.append("[Kimi for Coding] API Key Present")
                debugLines.append("  - Key Length: \(kimi.key.count) chars")
                debugLines.append("  - Key Preview: \(maskToken(kimi.key))")
            } else {
                debugLines.append("[Kimi for Coding] NOT CONFIGURED")
            }

            if let zaiCodingPlan = auth.zaiCodingPlan {
                debugLines.append("[Z.AI Coding Plan] API Key Present")
                debugLines.append("  - Key Length: \(zaiCodingPlan.key.count) chars")
                debugLines.append("  - Key Preview: \(maskToken(zaiCodingPlan.key))")
            } else {
                debugLines.append("[Z.AI Coding Plan] NOT CONFIGURED")
            }
        } else {
            debugLines.append("[auth.json] PARSE FAILED or NOT FOUND")
        }

        // 6. Antigravity accounts
        if let accounts = readAntigravityAccounts() {
            debugLines.append("[Antigravity Accounts] \(accounts.accounts.count) account(s)")
            debugLines.append("  - Active Index: \(accounts.activeIndex)")
            for (index, account) in accounts.accounts.enumerated() {
                let activeMarker = index == accounts.activeIndex ? " (ACTIVE)" : ""
                debugLines.append("  - [\(index)] \(account.email)\(activeMarker)")
                debugLines.append("    - Refresh Token: \(account.refreshToken.count) chars")
                debugLines.append("    - Project ID: \(account.projectId)")
            }
        } else {
            debugLines.append("[Antigravity Accounts] NOT FOUND or PARSE FAILED")
        }

        // 7. Codex native auth (~/.codex/auth.json)
        debugLines.append("---------- Codex Native Auth ----------")
        let codexAuthPath = homeDir.appendingPathComponent(".codex").appendingPathComponent("auth.json")
        if fileManager.fileExists(atPath: codexAuthPath.path) {
            if let codexAuth = readCodexAuth() {
                debugLines.append("[Codex Auth] EXISTS at \(codexAuthPath.path)")
                if let tokens = codexAuth.tokens {
                    debugLines.append("  - Access Token: \(tokens.accessToken != nil ? "\(tokens.accessToken!.count) chars" : "nil")")
                    debugLines.append("  - Account ID: \(tokens.accountId ?? "nil")")
                    debugLines.append("  - Refresh Token: \(tokens.refreshToken != nil ? "\(tokens.refreshToken!.count) chars" : "nil")")
                } else {
                    debugLines.append("  - Tokens: nil")
                }
                debugLines.append("  - OPENAI_API_KEY: \(codexAuth.openaiAPIKey != nil ? "SET" : "nil")")
                debugLines.append("  - Last Refresh: \(codexAuth.lastRefresh ?? "nil")")
            } else {
                debugLines.append("[Codex Auth] PARSE FAILED at \(codexAuthPath.path)")
            }
        } else {
            debugLines.append("[Codex Auth] NOT FOUND at \(codexAuthPath.path)")
        }

        debugLines.append("================================================")

        // Log all debug info
        let fullDebugLog = debugLines.joined(separator: "\n")
        logger.info("\n\(fullDebugLog)")

        // Also write to debug file for easier access
        #if DEBUG
        writeToDebugFile(fullDebugLog)
        #endif
    }

    /// Masks a token for secure logging (shows first 4 and last 4 chars)
    private func maskToken(_ token: String) -> String {
        guard token.count > 8 else { return "***" }
        let prefix = String(token.prefix(4))
        let suffix = String(token.suffix(4))
        return "\(prefix)...\(suffix)"
    }

    /// Writes debug info to file for easier access
    private func writeToDebugFile(_ content: String) {
        let path = "/tmp/provider_debug.log"
        let timestampedContent = "[\(Date())] TokenManager Environment Info:\n\(content)\n\n"
        if let data = timestampedContent.data(using: .utf8) {
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
}
