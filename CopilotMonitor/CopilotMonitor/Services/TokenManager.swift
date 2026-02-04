import Foundation
import Security
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

/// Auth source types for OpenAI (Codex) account discovery
enum OpenAIAuthSource {
    case opencodeAuth
    case codexAuth
}

/// Unified OpenAI account model used by the provider layer
struct OpenAIAuthAccount {
    let accessToken: String
    let accountId: String?
    let authSource: String
    let source: OpenAIAuthSource
}

/// Auth source types for Claude account discovery
enum ClaudeAuthSource {
    case opencodeAuth
    case claudeCodeConfig
    case claudeCodeKeychain
    case claudeLegacyCredentials
}

/// Unified Claude account model used by the provider layer
struct ClaudeAuthAccount {
    let accessToken: String
    let accountId: String?
    let email: String?
    let authSource: String
    let source: ClaudeAuthSource
}

/// Auth source types for GitHub Copilot token discovery
enum CopilotAuthSource {
    case opencodeAuth
    case vscodeHosts
    case vscodeApps
}

/// Unified GitHub Copilot token model used by the provider layer
struct CopilotAuthAccount {
    let accessToken: String
    let accountId: String?
    let login: String?
    let authSource: String
    let source: CopilotAuthSource
}

struct CopilotPlanInfo {
    let plan: String?
    let quotaResetDateUTC: Date?
    let quotaLimit: Int?
    let quotaRemaining: Int?
    let userId: String?
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

/// Auth source types for Gemini CLI fallback handling
enum GeminiAuthSource {
    case antigravity
    case opencodeAuth
}

/// Unified Gemini account model used by the provider layer
struct GeminiAuthAccount {
    let index: Int
    let email: String?
    let refreshToken: String
    let projectId: String
    let authSource: String
    let clientId: String
    let clientSecret: String
    let source: GeminiAuthSource
}

/// Minimal OpenCode auth payload for Gemini OAuth stored under "google"
struct OpenCodeGeminiAuthContainer: Decodable {
    let google: GeminiOAuthAuth?
}

/// Gemini OAuth payload as stored in OpenCode auth.json
struct GeminiOAuthAuth: Decodable {
    let type: String?
    let refresh: String?
    let access: String?
    let expires: Int64?

    enum CodingKeys: String, CodingKey {
        case type, refresh, access, expires
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try? container.decode(String.self, forKey: .type)
        refresh = try? container.decode(String.self, forKey: .refresh)
        access = try? container.decode(String.self, forKey: .access)

        if let expiresValue = try? container.decode(Int64.self, forKey: .expires) {
            expires = expiresValue
        } else if let expiresValue = try? container.decode(Double.self, forKey: .expires) {
            expires = Int64(expiresValue)
        } else if let expiresValue = try? container.decode(String.self, forKey: .expires),
                  let numericValue = Int64(expiresValue) {
            expires = numericValue
        } else {
            expires = nil
        }
    }
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
    
    /// Cached Gemini OAuth auth payload (OpenCode auth.json)
    private var cachedGeminiOAuthAuth: GeminiOAuthAuth?
    private var geminiOAuthCacheTimestamp: Date?
    
    /// Path where Gemini OAuth auth was found (OpenCode auth.json)
    private(set) var lastFoundGeminiOAuthPath: URL?

    /// Cached Claude accounts (OpenCode + Claude Code)
    private var cachedClaudeAccounts: [ClaudeAuthAccount]?
    private var claudeAccountsCacheTimestamp: Date?

    /// Cached GitHub Copilot token accounts (OpenCode + VS Code)
    private var cachedCopilotAccounts: [CopilotAuthAccount]?
    private var copilotAccountsCacheTimestamp: Date?

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

    // MARK: - Shared JSON Helpers

    private func normalizedKey(_ key: String) -> String {
        return key.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private func readJSONDictionary(at url: URL) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let json = try JSONSerialization.jsonObject(with: data, options: [])
            return json as? [String: Any]
        } catch {
            logger.warning("Failed to parse JSON at \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    private func findStringValue(in object: Any?, matching keys: Set<String>) -> String? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                let normalized = normalizedKey(key)
                if keys.contains(normalized), let stringValue = value as? String, !stringValue.isEmpty {
                    return stringValue
                }
                if let nested = findStringValue(in: value, matching: keys) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for item in array {
                if let nested = findStringValue(in: item, matching: keys) {
                    return nested
                }
            }
        }
        return nil
    }

    private func findIntValue(in object: Any?, matching keys: Set<String>) -> Int? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                let normalized = normalizedKey(key)
                if keys.contains(normalized) {
                    if let intValue = value as? Int {
                        return intValue
                    }
                    if let numberValue = value as? NSNumber {
                        return numberValue.intValue
                    }
                    if let stringValue = value as? String, let intValue = Int(stringValue) {
                        return intValue
                    }
                }
                if let nested = findIntValue(in: value, matching: keys) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for item in array {
                if let nested = findIntValue(in: item, matching: keys) {
                    return nested
                }
            }
        }
        return nil
    }

    private func readKeychainJSON(service: String) -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                logger.warning("Keychain lookup failed for service \(service), status: \(status)")
            }
            return nil
        }

        guard let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = json as? [String: Any] else {
            logger.warning("Keychain payload for service \(service) is not valid JSON")
            return nil
        }

        return dict
    }

    // MARK: - Antigravity Accounts File Reading

    private func antigravityAccountsPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("opencode")
            .appendingPathComponent("antigravity-accounts.json")
    }

    /// Thread-safe read of Antigravity accounts with caching
    func readAntigravityAccounts() -> AntigravityAccounts? {
        return queue.sync {
            if let cached = cachedAntigravityAccounts,
               let timestamp = antigravityCacheTimestamp,
               Date().timeIntervalSince(timestamp) < cacheValiditySeconds {
                return cached
            }
            
            let fileManager = FileManager.default
            let accountsPath = antigravityAccountsPath()
            
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

    // MARK: - Claude Code Auth Discovery

    private func claudeCodeAuthPaths() -> [URL] {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return [
            homeDir
                .appendingPathComponent(".config")
                .appendingPathComponent("claude-code")
                .appendingPathComponent("auth.json"),
            homeDir
                .appendingPathComponent(".claude")
                .appendingPathComponent(".credentials.json")
        ]
    }

    private func readClaudeCodeAuthFiles() -> [ClaudeAuthAccount] {
        let accessKeys: Set<String> = ["accesstoken", "oauthtoken", "token"]
        let accountKeys: Set<String> = ["accountid", "userid", "id"]
        let emailKeys: Set<String> = ["email", "useremail", "login", "username"]

        var accounts: [ClaudeAuthAccount] = []
        for path in claudeCodeAuthPaths() {
            guard let dict = readJSONDictionary(at: path) else { continue }
            guard let accessToken = findStringValue(in: dict, matching: accessKeys) else { continue }

            let accountIdString = findStringValue(in: dict, matching: accountKeys)
            let accountIdInt = findIntValue(in: dict, matching: accountKeys)
            let accountId = accountIdString ?? accountIdInt.map { String($0) }
            let email = findStringValue(in: dict, matching: emailKeys)

            let source: ClaudeAuthSource = path.path.contains(".credentials.json") ? .claudeLegacyCredentials : .claudeCodeConfig
            accounts.append(
                ClaudeAuthAccount(
                    accessToken: accessToken,
                    accountId: accountId,
                    email: email,
                    authSource: path.path,
                    source: source
                )
            )
        }
        return accounts
    }

    private func readClaudeCodeKeychainAccounts() -> [ClaudeAuthAccount] {
        let accessKeys: Set<String> = ["accesstoken", "oauthtoken", "token"]
        let accountKeys: Set<String> = ["accountid", "userid", "id"]
        let emailKeys: Set<String> = ["email", "useremail", "login", "username"]

        let services = [
            "Claude Code-credentials",
            "Claude Code"
        ]

        var accounts: [ClaudeAuthAccount] = []
        for service in services {
            guard let dict = readKeychainJSON(service: service) else { continue }
            guard let accessToken = findStringValue(in: dict, matching: accessKeys) else { continue }

            let accountIdString = findStringValue(in: dict, matching: accountKeys)
            let accountIdInt = findIntValue(in: dict, matching: accountKeys)
            let accountId = accountIdString ?? accountIdInt.map { String($0) }
            let email = findStringValue(in: dict, matching: emailKeys)

            accounts.append(
                ClaudeAuthAccount(
                    accessToken: accessToken,
                    accountId: accountId,
                    email: email,
                    authSource: "Keychain (\(service))",
                    source: .claudeCodeKeychain
                )
            )
        }
        return accounts
    }

    /// Gets all Claude accounts (OpenCode auth + Claude Code local auth)
    func getClaudeAccounts() -> [ClaudeAuthAccount] {
        if let cached = queue.sync(execute: {
            if let cached = cachedClaudeAccounts,
               let timestamp = claudeAccountsCacheTimestamp,
               Date().timeIntervalSince(timestamp) < cacheValiditySeconds {
                return cached
            }
            return nil
        }) {
            return cached
        }

        var accounts: [ClaudeAuthAccount] = []

        if let auth = readOpenCodeAuth(),
           let access = auth.anthropic?.access,
           !access.isEmpty {
            let authSource = lastFoundAuthPath?.path ?? "~/.local/share/opencode/auth.json"
            accounts.append(
                ClaudeAuthAccount(
                    accessToken: access,
                    accountId: auth.anthropic?.accountId,
                    email: nil,
                    authSource: authSource,
                    source: .opencodeAuth
                )
            )
        }

        accounts.append(contentsOf: readClaudeCodeKeychainAccounts())
        accounts.append(contentsOf: readClaudeCodeAuthFiles())

        let deduped = dedupeClaudeAccounts(accounts)
        logger.info("Claude accounts discovered: \(deduped.count)")
        queue.sync {
            cachedClaudeAccounts = deduped
            claudeAccountsCacheTimestamp = Date()
        }
        return deduped
    }

    private func dedupeClaudeAccounts(_ accounts: [ClaudeAuthAccount]) -> [ClaudeAuthAccount] {
        func priority(for source: ClaudeAuthSource) -> Int {
            switch source {
            case .opencodeAuth: return 3
            case .claudeCodeKeychain: return 2
            case .claudeCodeConfig: return 1
            case .claudeLegacyCredentials: return 0
            }
        }

        var byToken: [String: ClaudeAuthAccount] = [:]
        for account in accounts {
            if let existing = byToken[account.accessToken] {
                if priority(for: account.source) > priority(for: existing.source) {
                    byToken[account.accessToken] = account
                }
            } else {
                byToken[account.accessToken] = account
            }
        }
        return Array(byToken.values)
    }

    // MARK: - GitHub Copilot Token Discovery

    private func copilotTokenPaths() -> [URL] {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        var paths: [URL] = []

        if let xdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdgConfigHome.isEmpty {
            let xdgBase = URL(fileURLWithPath: xdgConfigHome).appendingPathComponent("github-copilot")
            paths.append(xdgBase.appendingPathComponent("hosts.json"))
            paths.append(xdgBase.appendingPathComponent("apps.json"))
        }

        let linuxBase = homeDir
            .appendingPathComponent(".config")
            .appendingPathComponent("github-copilot")
        paths.append(linuxBase.appendingPathComponent("hosts.json"))
        paths.append(linuxBase.appendingPathComponent("apps.json"))

        let macBase = homeDir
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("github-copilot")
        paths.append(macBase.appendingPathComponent("hosts.json"))
        paths.append(macBase.appendingPathComponent("apps.json"))

        var uniquePaths: [URL] = []
        var seen = Set<String>()
        for path in paths {
            if seen.insert(path.path).inserted {
                uniquePaths.append(path)
            }
        }
        return uniquePaths
    }

    private func copilotAccountFromEntry(_ entry: [String: Any], source: CopilotAuthSource, authSource: String) -> CopilotAuthAccount? {
        let tokenKeys: Set<String> = ["oauthtoken", "accesstoken", "token"]
        let accountKeys: Set<String> = ["accountid", "userid", "id"]
        let loginKeys: Set<String> = ["login", "user", "username", "email"]

        guard let accessToken = findStringValue(in: entry, matching: tokenKeys) else { return nil }

        let accountIdString = findStringValue(in: entry, matching: accountKeys)
        let accountIdInt = findIntValue(in: entry, matching: accountKeys)
        let accountId = accountIdString ?? accountIdInt.map { String($0) }

        let login = findStringValue(in: entry, matching: loginKeys)

        return CopilotAuthAccount(
            accessToken: accessToken,
            accountId: accountId,
            login: login,
            authSource: authSource,
            source: source
        )
    }

    private func parseCopilotAccounts(from dict: [String: Any], source: CopilotAuthSource, authSource: String) -> [CopilotAuthAccount] {
        var accounts: [CopilotAuthAccount] = []

        if let account = copilotAccountFromEntry(dict, source: source, authSource: authSource) {
            accounts.append(account)
        }

        for value in dict.values {
            if let entry = value as? [String: Any],
               let account = copilotAccountFromEntry(entry, source: source, authSource: authSource) {
                accounts.append(account)
            }
        }

        return accounts
    }

    /// Gets all GitHub Copilot token accounts (OpenCode auth + VS Code Copilot tokens)
    func getGitHubCopilotAccounts() -> [CopilotAuthAccount] {
        if let cached = queue.sync(execute: {
            if let cached = cachedCopilotAccounts,
               let timestamp = copilotAccountsCacheTimestamp,
               Date().timeIntervalSince(timestamp) < cacheValiditySeconds {
                return cached
            }
            return nil
        }) {
            return cached
        }

        var accounts: [CopilotAuthAccount] = []

        if let auth = readOpenCodeAuth(),
           let access = auth.githubCopilot?.access,
           !access.isEmpty {
            let authSource = lastFoundAuthPath?.path ?? "~/.local/share/opencode/auth.json"
            accounts.append(
                CopilotAuthAccount(
                    accessToken: access,
                    accountId: auth.githubCopilot?.accountId,
                    login: nil,
                    authSource: authSource,
                    source: .opencodeAuth
                )
            )
        }

        for path in copilotTokenPaths() {
            guard let dict = readJSONDictionary(at: path) else { continue }
            let source: CopilotAuthSource = path.lastPathComponent == "apps.json" ? .vscodeApps : .vscodeHosts
            accounts.append(contentsOf: parseCopilotAccounts(from: dict, source: source, authSource: path.path))
        }

        let deduped = dedupeCopilotAccounts(accounts)
        logger.info("GitHub Copilot token accounts discovered: \(deduped.count)")
        queue.sync {
            cachedCopilotAccounts = deduped
            copilotAccountsCacheTimestamp = Date()
        }
        return deduped
    }

    private func dedupeCopilotAccounts(_ accounts: [CopilotAuthAccount]) -> [CopilotAuthAccount] {
        func priority(for source: CopilotAuthSource) -> Int {
            switch source {
            case .opencodeAuth: return 2
            case .vscodeHosts: return 1
            case .vscodeApps: return 0
            }
        }

        var byToken: [String: CopilotAuthAccount] = [:]
        for account in accounts {
            if let existing = byToken[account.accessToken] {
                if priority(for: account.source) > priority(for: existing.source) {
                    byToken[account.accessToken] = account
                }
            } else {
                byToken[account.accessToken] = account
            }
        }
        return Array(byToken.values)
    }

    // MARK: - OpenAI Account Discovery

    /// Gets all OpenAI accounts (OpenCode auth + Codex native auth)
    func getOpenAIAccounts() -> [OpenAIAuthAccount] {
        var accounts: [OpenAIAuthAccount] = []

        if let auth = readOpenCodeAuth(),
           let access = auth.openai?.access,
           !access.isEmpty {
            let authSource = lastFoundAuthPath?.path ?? "~/.local/share/opencode/auth.json"
            accounts.append(
                OpenAIAuthAccount(
                    accessToken: access,
                    accountId: auth.openai?.accountId,
                    authSource: authSource,
                    source: .opencodeAuth
                )
            )
        }

        if let codexAuth = readCodexAuth(),
           let access = codexAuth.tokens?.accessToken,
           !access.isEmpty {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            let authSource = homeDir
                .appendingPathComponent(".codex")
                .appendingPathComponent("auth.json")
                .path
            accounts.append(
                OpenAIAuthAccount(
                    accessToken: access,
                    accountId: codexAuth.tokens?.accountId,
                    authSource: authSource,
                    source: .codexAuth
                )
            )
        }

        logger.info("OpenAI accounts discovered: \(accounts.count)")
        return accounts
    }

    // MARK: - Gemini OAuth Auth File Reading (OpenCode auth.json)

    private struct GeminiRefreshParts {
        let refreshToken: String
        let projectId: String?
        let managedProjectId: String?
    }

    private func parseGeminiRefreshParts(_ refresh: String) -> GeminiRefreshParts {
        let trimmed = refresh.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = trimmed.split(separator: "|", omittingEmptySubsequences: false)
        let refreshToken = segments.indices.contains(0) ? String(segments[0]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let projectRaw = segments.indices.contains(1) ? String(segments[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let managedRaw = segments.indices.contains(2) ? String(segments[2]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return GeminiRefreshParts(
            refreshToken: refreshToken,
            projectId: projectRaw.isEmpty ? nil : projectRaw,
            managedProjectId: managedRaw.isEmpty ? nil : managedRaw
        )
    }

    /// Thread-safe read of Gemini OAuth auth stored under "google" in OpenCode auth.json
    func readGeminiOAuthAuth() -> GeminiOAuthAuth? {
        return queue.sync {
            if let cached = cachedGeminiOAuthAuth,
               let timestamp = geminiOAuthCacheTimestamp,
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
                    let container = try JSONDecoder().decode(OpenCodeGeminiAuthContainer.self, from: data)
                    guard let geminiAuth = container.google else {
                        continue
                    }
                    guard geminiAuth.type?.lowercased() == "oauth" else {
                        continue
                    }
                    let refresh = geminiAuth.refresh?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !refresh.isEmpty else {
                        logger.warning("Gemini OAuth entry exists but refresh token is empty in \(authPath.path)")
                        continue
                    }

                    lastFoundGeminiOAuthPath = authPath
                    cachedGeminiOAuthAuth = geminiAuth
                    geminiOAuthCacheTimestamp = Date()
                    logger.info("Successfully loaded Gemini OAuth auth from: \(authPath.path)")
                    return geminiAuth
                } catch {
                    logger.warning("Failed to parse Gemini OAuth auth at \(authPath.path): \(error.localizedDescription)")
                    continue
                }
            }

            lastFoundGeminiOAuthPath = nil
            cachedGeminiOAuthAuth = nil
            geminiOAuthCacheTimestamp = nil
            return nil
        }
    }

    // MARK: - Token Accessors

    /// Gets Anthropic (Claude) access token from OpenCode auth
    /// - Returns: Access token string if available, nil otherwise
    func getAnthropicAccessToken() -> String? {
        if let auth = readOpenCodeAuth(), let access = auth.anthropic?.access {
            return access
        }
        return getClaudeAccounts().first?.accessToken
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
        if let auth = readOpenCodeAuth(), let access = auth.githubCopilot?.access {
            return access
        }
        return getGitHubCopilotAccounts().first?.accessToken
    }

    /// Fetches Copilot plan and quota info from GitHub internal API
    /// - Returns: CopilotPlanInfo if successful, nil otherwise
    func fetchCopilotPlanInfo(accessToken: String) async -> CopilotPlanInfo? {
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

            let plan = json["copilot_plan"] as? String ?? json["plan"] as? String
            let userIdString = json["user_id"] as? String
            let userIdInt = json["user_id"] as? Int ?? (json["id"] as? Int)
            let userId = userIdString ?? userIdInt.map { String($0) }

            var resetDate: Date?

            // Parse quota_reset_date_utc (format: "2026-03-01T00:00:00.000Z")
            if let resetDateStr = json["quota_reset_date_utc"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                resetDate = formatter.date(from: resetDateStr)

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

            // Additional fallback: limited_user_reset_date
            if resetDate == nil, let limitedReset = json["limited_user_reset_date"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                resetDate = formatter.date(from: limitedReset)
                if resetDate == nil {
                    let fallbackFormatter = ISO8601DateFormatter()
                    fallbackFormatter.formatOptions = [.withInternetDateTime]
                    resetDate = fallbackFormatter.date(from: limitedReset)
                }
            }

            let limitedUserQuotas = json["limited_user_quotas"] as? [String: Any]
            let monthlyQuotas = json["monthly_quotas"] as? [String: Any]

            func quotaValue(_ dict: [String: Any]?, key: String) -> Int? {
                guard let dict = dict else { return nil }
                if let value = dict[key] as? Int { return value }
                if let value = dict[key] as? NSNumber { return value.intValue }
                if let value = dict[key] as? Double { return Int(value) }
                if let value = dict[key] as? String, let intValue = Int(value) { return intValue }
                return nil
            }

            let monthlyCompletions = quotaValue(monthlyQuotas, key: "completions")
            let monthlyChat = quotaValue(monthlyQuotas, key: "chat")
            let limitedCompletions = quotaValue(limitedUserQuotas, key: "completions")
            let limitedChat = quotaValue(limitedUserQuotas, key: "chat")

            let quotaLimit = monthlyCompletions ?? monthlyChat
                ?? ((monthlyCompletions != nil || monthlyChat != nil) ? (monthlyCompletions ?? 0) + (monthlyChat ?? 0) : nil)
            let quotaRemaining = limitedCompletions ?? limitedChat
                ?? ((limitedCompletions != nil || limitedChat != nil) ? (limitedCompletions ?? 0) + (limitedChat ?? 0) : nil)

            if let resetDate = resetDate {
                logger.info("Copilot plan info fetched: \(plan ?? "unknown"), reset: \(resetDate)")
            } else {
                logger.warning("Copilot plan fetched but no reset date: \(plan ?? "unknown")")
            }

            return CopilotPlanInfo(
                plan: plan,
                quotaResetDateUTC: resetDate,
                quotaLimit: quotaLimit,
                quotaRemaining: quotaRemaining,
                userId: userId
            )
        } catch {
            logger.error("Failed to fetch Copilot plan info: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fetches Copilot plan info using the primary token
    func fetchCopilotPlanInfo() async -> CopilotPlanInfo? {
        guard let accessToken = getGitHubCopilotAccessToken() else {
            logger.warning("No GitHub Copilot token available for plan info fetch")
            return nil
        }
        return await fetchCopilotPlanInfo(accessToken: accessToken)
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

    /// Gets Gemini refresh token from storage (primary: Antigravity accounts, fallback: OpenCode auth.json)
    /// - Returns: Refresh token string if available, nil otherwise
    func getGeminiRefreshToken() -> String? {
        return getAllGeminiAccounts().first?.refreshToken
    }

    /// Gets Gemini account email from storage (primary: Antigravity accounts, fallback: OpenCode auth.json)
    /// - Returns: Email string if available, nil otherwise
    func getGeminiAccountEmail() -> String? {
        return getAllGeminiAccounts().first?.email
    }

    /// Gets all Gemini accounts (primary: Antigravity accounts, fallback: OpenCode auth.json)
    func getAllGeminiAccounts() -> [GeminiAuthAccount] {
        var accounts: [GeminiAuthAccount] = []

        if let geminiAuth = readGeminiOAuthAuth() {
            let refresh = geminiAuth.refresh?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parts = parseGeminiRefreshParts(refresh)
            if !parts.refreshToken.isEmpty {
                let projectId = parts.projectId ?? parts.managedProjectId ?? ""
                if projectId.isEmpty {
                    logger.warning("Gemini OAuth auth found but project ID is missing")
                }
                let authSource = lastFoundGeminiOAuthPath?.path ?? "auth.json"
                accounts.append(
                    GeminiAuthAccount(
                        index: 0,
                        email: nil,
                        refreshToken: parts.refreshToken,
                        projectId: projectId,
                        authSource: authSource,
                        clientId: TokenManager.geminiAuthPluginClientId,
                        clientSecret: TokenManager.geminiAuthPluginClientSecret,
                        source: .opencodeAuth
                    )
                )
            } else {
                logger.warning("Gemini OAuth refresh token missing or empty")
            }
        }

        if let antigravity = readAntigravityAccounts(), !antigravity.accounts.isEmpty {
            let authSource = antigravityAccountsPath().path
            let antigravityAccounts = antigravity.accounts.enumerated().map { index, account in
                GeminiAuthAccount(
                    index: index,
                    email: account.email,
                    refreshToken: account.refreshToken,
                    projectId: account.projectId,
                    authSource: authSource,
                    clientId: TokenManager.geminiClientId,
                    clientSecret: TokenManager.geminiClientSecret,
                    source: .antigravity
                )
            }
            accounts.append(contentsOf: antigravityAccounts)
        }

        if accounts.isEmpty {
            return []
        }

        return accounts.enumerated().map { index, account in
            GeminiAuthAccount(
                index: index,
                email: account.email,
                refreshToken: account.refreshToken,
                projectId: account.projectId,
                authSource: account.authSource,
                clientId: account.clientId,
                clientSecret: account.clientSecret,
                source: account.source
            )
        }
    }

    /// Gets the count of registered Gemini accounts
    func getGeminiAccountCount() -> Int {
        return getAllGeminiAccounts().count
    }

    // MARK: - Gemini OAuth Token Refresh

    /// Public Google OAuth client credentials for CLI/installed apps
    /// These are NOT secrets - they are public client IDs/secrets for installed applications
    /// See: https://developers.google.com/identity/protocols/oauth2/native-app
    private static let geminiClientId = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private static let geminiClientSecret = "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"
    
    /// OAuth client used by opencode-gemini-auth plugin
    private static let geminiAuthPluginClientId = "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"
    private static let geminiAuthPluginClientSecret = "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"

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
        guard let account = getAllGeminiAccounts().first else {
            logger.warning("No Gemini refresh token found in storage")
            return nil
        }

        return await refreshGeminiAccessToken(
            refreshToken: account.refreshToken,
            clientId: account.clientId,
            clientSecret: account.clientSecret
        )
    }

    // MARK: - Debug Environment Info

    private func authDiscoverySummaryLines() -> [String] {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let openCodeAuth = readOpenCodeAuth()
        let openCodePath = lastFoundAuthPath?.path ?? "~/.local/share/opencode/auth.json"

        var lines: [String] = []
        lines.append("Auth Discovery Summary:")
        lines.append(String(repeating: "─", count: 40))

        func shortPath(_ path: String) -> String {
            let homePath = homeDir.path
            if path.hasPrefix(homePath) {
                let suffix = path.dropFirst(homePath.count)
                return "~\(suffix)"
            }
            return path
        }

        func tokenStatus(hasAuth: Bool, token: String?, accountId: String?) -> String {
            guard hasAuth else { return "NOT FOUND" }
            guard let token = token, !token.isEmpty else { return "MISSING TOKEN" }
            let accountIdStatus = (accountId == nil || accountId?.isEmpty == true) ? "NO" : "YES"
            return "FOUND (token, accountId: \(accountIdStatus))"
        }

        func fileStatus(path: URL, tokenKeys: Set<String>) -> String {
            if !fileManager.fileExists(atPath: path.path) {
                return "NOT FOUND"
            }
            guard let dict = readJSONDictionary(at: path) else {
                return "UNREADABLE"
            }
            let hasToken = findStringValue(in: dict, matching: tokenKeys) != nil
            return hasToken ? "FOUND" : "MISSING TOKEN"
        }

        func keychainStatus(service: String, tokenKeys: Set<String>) -> String {
            guard let dict = readKeychainJSON(service: service) else { return "NOT FOUND" }
            let hasToken = findStringValue(in: dict, matching: tokenKeys) != nil
            return hasToken ? "FOUND" : "MISSING TOKEN"
        }

        func copilotFileStatus(path: URL) -> String {
            if !fileManager.fileExists(atPath: path.path) {
                return "NOT FOUND"
            }
            guard let dict = readJSONDictionary(at: path) else {
                return "UNREADABLE"
            }
            let source: CopilotAuthSource = path.lastPathComponent == "apps.json" ? .vscodeApps : .vscodeHosts
            let accounts = parseCopilotAccounts(from: dict, source: source, authSource: path.path)
            if accounts.isEmpty {
                return "FOUND (no token entries)"
            }
            return "FOUND (\(accounts.count) account(s))"
        }

        func browserCookieStatus() -> String {
            do {
                _ = try BrowserCookieService.shared.getGitHubCookies()
                return "AVAILABLE"
            } catch {
                return "NOT AVAILABLE"
            }
        }

        lines.append("[ChatGPT]")
        lines.append("  OpenCode auth.json (\(shortPath(openCodePath))): \(tokenStatus(hasAuth: openCodeAuth != nil, token: openCodeAuth?.openai?.access, accountId: openCodeAuth?.openai?.accountId))")

        let codexAuthPath = homeDir.appendingPathComponent(".codex").appendingPathComponent("auth.json")
        if fileManager.fileExists(atPath: codexAuthPath.path) {
            if let codexAuth = readCodexAuth() {
                let status = tokenStatus(
                    hasAuth: true,
                    token: codexAuth.tokens?.accessToken,
                    accountId: codexAuth.tokens?.accountId
                )
                lines.append("  Codex auth.json (\(shortPath(codexAuthPath.path))): \(status)")
            } else {
                lines.append("  Codex auth.json (\(shortPath(codexAuthPath.path))): PARSE FAILED")
            }
        } else {
            lines.append("  Codex auth.json (\(shortPath(codexAuthPath.path))): NOT FOUND")
        }

        lines.append("")
        lines.append("[Claude]")
        lines.append("  OpenCode auth.json (\(shortPath(openCodePath))): \(tokenStatus(hasAuth: openCodeAuth != nil, token: openCodeAuth?.anthropic?.access, accountId: openCodeAuth?.anthropic?.accountId))")
        let claudeTokenKeys: Set<String> = ["accesstoken", "oauthtoken", "token"]
        let claudeKeychainPrimary = "Claude Code-credentials"
        let claudeKeychainSecondary = "Claude Code"
        lines.append("  Claude Code Keychain (\(claudeKeychainPrimary)): \(keychainStatus(service: claudeKeychainPrimary, tokenKeys: claudeTokenKeys))")
        lines.append("  Claude Code Keychain (\(claudeKeychainSecondary)): \(keychainStatus(service: claudeKeychainSecondary, tokenKeys: claudeTokenKeys))")

        let claudePaths = claudeCodeAuthPaths()
        if let configPath = claudePaths.first {
            lines.append("  Claude Code auth.json (\(shortPath(configPath.path))): \(fileStatus(path: configPath, tokenKeys: claudeTokenKeys))")
        }
        if claudePaths.count > 1 {
            let legacyPath = claudePaths[1]
            lines.append("  Claude Legacy credentials (\(shortPath(legacyPath.path))): \(fileStatus(path: legacyPath, tokenKeys: claudeTokenKeys))")
        }

        lines.append("")
        lines.append("[GitHub Copilot]")
        lines.append("  OpenCode auth.json (\(shortPath(openCodePath))): \(tokenStatus(hasAuth: openCodeAuth != nil, token: openCodeAuth?.githubCopilot?.access, accountId: openCodeAuth?.githubCopilot?.accountId))")
        let copilotBase = homeDir
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("github-copilot")
        let copilotHosts = copilotBase.appendingPathComponent("hosts.json")
        let copilotApps = copilotBase.appendingPathComponent("apps.json")
        lines.append("  VS Code hosts.json (\(shortPath(copilotHosts.path))): \(copilotFileStatus(path: copilotHosts))")
        lines.append("  VS Code apps.json (\(shortPath(copilotApps.path))): \(copilotFileStatus(path: copilotApps))")
        lines.append("  Browser Cookies: \(browserCookieStatus())")

        lines.append("")
        lines.append("[Gemini CLI]")
        let geminiAuth = readGeminiOAuthAuth()
        let geminiAuthPath = lastFoundGeminiOAuthPath?.path ?? "auth.json"
        if let geminiAuth = geminiAuth, let refresh = geminiAuth.refresh, !refresh.isEmpty {
            lines.append("  OpenCode auth.json (google.oauth, \(shortPath(geminiAuthPath))): FOUND")
        } else {
            lines.append("  OpenCode auth.json (google.oauth, \(shortPath(geminiAuthPath))): NOT FOUND")
        }
        if let accounts = readAntigravityAccounts() {
            lines.append("  Antigravity accounts (\(shortPath(antigravityAccountsPath().path))): FOUND (\(accounts.accounts.count) account(s))")
        } else {
            lines.append("  Antigravity accounts (\(shortPath(antigravityAccountsPath().path))): NOT FOUND")
        }

        lines.append(String(repeating: "─", count: 40))
        return lines
    }

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

        debugLines.append("")
        debugLines.append(contentsOf: authDiscoverySummaryLines())

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

        debugLines.append(contentsOf: authDiscoverySummaryLines())

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
