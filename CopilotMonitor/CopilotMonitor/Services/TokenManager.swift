import Foundation
import Security
import SQLite3
import CommonCrypto
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

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            type = (try? container.decode(String.self, forKey: .type)) ?? "oauth"

            let rawAccess = try container.decode(String.self, forKey: .access)
            let trimmedAccess = rawAccess.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedAccess.isEmpty {
                throw DecodingError.dataCorruptedError(
                    forKey: .access,
                    in: container,
                    debugDescription: "OAuth access token is empty"
                )
            }
            access = trimmedAccess

            refresh = (try? container.decode(String.self, forKey: .refresh))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ""

            expires = Self.decodeFlexibleInt64(from: container, forKey: .expires) ?? 0
            accountId = Self.decodeFlexibleString(from: container, forKey: .accountId)
        }

        private static func decodeFlexibleInt64(
            from container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> Int64? {
            if let value = decodeLossyIfPresent(Int64.self, from: container, forKey: key) {
                return value
            }
            if let value = decodeLossyIfPresent(Int.self, from: container, forKey: key) {
                return Int64(value)
            }
            if let value = decodeLossyIfPresent(Double.self, from: container, forKey: key) {
                return Int64(value)
            }
            if let value = decodeLossyIfPresent(String.self, from: container, forKey: key) {
                return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }

        private static func decodeFlexibleString(
            from container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> String? {
            if let value = decodeLossyIfPresent(String.self, from: container, forKey: key) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if let value = decodeLossyIfPresent(Int.self, from: container, forKey: key) {
                return String(value)
            }
            if let value = decodeLossyIfPresent(Int64.self, from: container, forKey: key) {
                return String(value)
            }
            if let value = decodeLossyIfPresent(Double.self, from: container, forKey: key) {
                let asInt = Int64(value)
                return String(asInt)
            }
            return nil
        }

        private static func decodeLossyIfPresent<T: Decodable>(
            _ type: T.Type,
            from container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> T? {
            do {
                return try container.decodeIfPresent(T.self, forKey: key)
            } catch {
                return nil
            }
        }
    }

    struct APIKey: Codable {
        let type: String
        let key: String

        enum CodingKeys: String, CodingKey {
            case type
            case key
            case access
            case token
            case apiKey
            case value
        }

        init(from decoder: Decoder) throws {
            if let singleValue = try? decoder.singleValueContainer(),
               let rawKey = try? singleValue.decode(String.self) {
                let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    throw DecodingError.dataCorruptedError(
                        in: singleValue,
                        debugDescription: "API key value is empty"
                    )
                }
                type = "apiKey"
                key = trimmed
                return
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = (try? container.decode(String.self, forKey: .type)) ?? "apiKey"

            let candidateKeys: [CodingKeys] = [.key, .access, .token, .apiKey, .value]
            var resolvedKey: String?
            for candidate in candidateKeys {
                let value: String?
                do {
                    value = try container.decodeIfPresent(String.self, forKey: candidate)
                } catch {
                    value = nil
                }
                if let value {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        resolvedKey = trimmed
                        break
                    }
                }
            }

            guard let resolvedKey else {
                throw DecodingError.keyNotFound(
                    CodingKeys.key,
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "No API key field found (expected one of: key/access/token/apiKey/value)"
                    )
                )
            }
            key = resolvedKey
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encode(key, forKey: .key)
        }
    }

    let anthropic: OAuth?
    let openai: OAuth?
    let githubCopilot: OAuth?
    let openrouter: APIKey?
    let opencode: APIKey?
    let kimiForCoding: APIKey?
    let zaiCodingPlan: APIKey?
    let nanoGpt: APIKey?
    let synthetic: APIKey?
    let chutes: APIKey?

    enum CodingKeys: String, CodingKey {
        case anthropic, openai, openrouter, opencode, synthetic, chutes
        case githubCopilot = "github-copilot"
        case kimiForCoding = "kimi-for-coding"
        case zaiCodingPlan = "zai-coding-plan"
        case nanoGpt = "nano-gpt"
    }

    init(
        anthropic: OAuth?,
        openai: OAuth?,
        githubCopilot: OAuth?,
        openrouter: APIKey?,
        opencode: APIKey?,
        kimiForCoding: APIKey?,
        zaiCodingPlan: APIKey?,
        nanoGpt: APIKey?,
        synthetic: APIKey?,
        chutes: APIKey? = nil
    ) {
        self.anthropic = anthropic
        self.openai = openai
        self.githubCopilot = githubCopilot
        self.openrouter = openrouter
        self.opencode = opencode
        self.kimiForCoding = kimiForCoding
        self.zaiCodingPlan = zaiCodingPlan
        self.nanoGpt = nanoGpt
        self.synthetic = synthetic
        self.chutes = chutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        anthropic = Self.decodeLossyIfPresent(OAuth.self, from: container, forKey: .anthropic)
        openai = Self.decodeLossyIfPresent(OAuth.self, from: container, forKey: .openai)
        githubCopilot = Self.decodeLossyIfPresent(OAuth.self, from: container, forKey: .githubCopilot)
        openrouter = Self.decodeLossyIfPresent(APIKey.self, from: container, forKey: .openrouter)
        opencode = Self.decodeLossyIfPresent(APIKey.self, from: container, forKey: .opencode)
        kimiForCoding = Self.decodeLossyIfPresent(APIKey.self, from: container, forKey: .kimiForCoding)
        zaiCodingPlan = Self.decodeLossyIfPresent(APIKey.self, from: container, forKey: .zaiCodingPlan)
        nanoGpt = Self.decodeLossyIfPresent(APIKey.self, from: container, forKey: .nanoGpt)
        synthetic = Self.decodeLossyIfPresent(APIKey.self, from: container, forKey: .synthetic)
        chutes = Self.decodeLossyIfPresent(APIKey.self, from: container, forKey: .chutes)

        if anthropic == nil,
           openai == nil,
           githubCopilot == nil,
           openrouter == nil,
           opencode == nil,
           kimiForCoding == nil,
           zaiCodingPlan == nil,
           nanoGpt == nil,
           synthetic == nil,
           chutes == nil {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "No valid auth entries found in auth.json"
                )
            )
        }
    }

    private static func decodeLossyIfPresent<T: Decodable>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> T? {
        do {
            return try container.decodeIfPresent(T.self, forKey: key)
        } catch {
            return nil
        }
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
        try container.encodeIfPresent(nanoGpt, forKey: .nanoGpt)
        try container.encodeIfPresent(synthetic, forKey: .synthetic)
        try container.encodeIfPresent(chutes, forKey: .chutes)
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

/// codex-lb row payload from store.db/accounts table
private struct CodexLBEncryptedAccount {
    let accountId: String?
    let email: String?
    let planType: String?
    let status: String?
    let accessTokenEncrypted: Data
    let refreshTokenEncrypted: Data?
    let idTokenEncrypted: Data?
    let lastRefresh: String?
}

/// Auth source types for OpenAI (Codex) account discovery
enum OpenAIAuthSource {
    case opencodeAuth
    case codexLB
    case codexAuth
}

/// Unified OpenAI account model used by the provider layer
struct OpenAIAuthAccount {
    let accessToken: String
    let accountId: String?
    let email: String?
    let authSource: String
    let sourceLabels: [String]
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
    let sourceLabels: [String]
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

/// Antigravity Accounts structure for NoeFabris/opencode-antigravity-auth (~/.config/opencode/antigravity-accounts.json)
struct AntigravityAccounts: Codable {
    struct Account: Codable {
        let email: String?
        let refreshToken: String?
        let projectId: String?
        let managedProjectId: String?
        let enabled: Bool?
    }

    let version: Int?
    let accounts: [Account]
    let activeIndex: Int?
    let activeIndexByFamily: [String: Int]?
}

/// Auth source types for Gemini CLI token discovery
enum GeminiAuthSource {
    /// NoeFabris/opencode-antigravity-auth (~/.config/opencode/antigravity-accounts.json)
    case antigravity
    /// jenslys/opencode-gemini-auth (OpenCode auth.json google.oauth)
    case opencodeAuth
    /// Gemini CLI OAuth credentials (~/.gemini/oauth_creds.json)
    case oauthCreds
}

/// Unified Gemini account model used by the provider layer
struct GeminiAuthAccount {
    let index: Int
    let accountId: String?
    let email: String?
    let refreshToken: String
    let projectId: String
    let authSource: String
    let sourceLabels: [String]
    let clientId: String
    let clientSecret: String
    let source: GeminiAuthSource
}

/// Minimal OpenCode auth payload for jenslys/opencode-gemini-auth stored under "google"
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

/// Gemini CLI OAuth credentials from ~/.gemini/oauth_creds.json
struct GeminiOAuthCreds: Decodable {
    let expiryDate: Int64?
    let tokenType: String?
    let accessToken: String?
    let refreshToken: String?
    let scope: String?
    let idToken: String?
    let projectId: String?
    let quotaProjectId: String?

    enum CodingKeys: String, CodingKey {
        case expiryDate = "expiry_date"
        case tokenType = "token_type"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case scope
        case idToken = "id_token"
        case projectId = "project_id"
        case quotaProjectId = "quota_project_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(Int64.self, forKey: .expiryDate) {
            expiryDate = value
        } else if let value = try? container.decode(Double.self, forKey: .expiryDate) {
            expiryDate = Int64(value)
        } else if let value = try? container.decode(String.self, forKey: .expiryDate),
                  let numeric = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            expiryDate = numeric
        } else {
            expiryDate = nil
        }

        tokenType = try? container.decode(String.self, forKey: .tokenType)
        accessToken = try? container.decode(String.self, forKey: .accessToken)
        refreshToken = try? container.decode(String.self, forKey: .refreshToken)
        scope = try? container.decode(String.self, forKey: .scope)
        idToken = try? container.decode(String.self, forKey: .idToken)
        projectId = try? container.decode(String.self, forKey: .projectId)
        quotaProjectId = try? container.decode(String.self, forKey: .quotaProjectId)
    }
}

private struct GeminiIDTokenPayload: Decodable {
    let sub: String?
    let email: String?
    let audience: String?

    enum CodingKeys: String, CodingKey {
        case sub
        case email
        case aud
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sub = try? container.decode(String.self, forKey: .sub)
        email = try? container.decode(String.self, forKey: .email)

        if let aud = try? container.decode(String.self, forKey: .aud) {
            audience = aud
        } else if let audArray = try? container.decode([String].self, forKey: .aud) {
            audience = audArray.first
        } else {
            audience = nil
        }
    }
}

private struct OpenAIIDTokenPayload: Decodable {
    let email: String?
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

    /// Cached Gemini OAuth creds payload (~/.gemini/oauth_creds.json)
    private var cachedGeminiOAuthCreds: GeminiOAuthCreds?
    private var geminiOAuthCredsCacheTimestamp: Date?

    /// Path where Gemini oauth_creds.json was found
    private(set) var lastFoundGeminiOAuthCredsPath: URL?

    /// Cached Claude accounts (OpenCode + Claude Code)
    private var cachedClaudeAccounts: [ClaudeAuthAccount]?
    private var claudeAccountsCacheTimestamp: Date?

    /// Cached GitHub Copilot token accounts (OpenCode + VS Code)
    private var cachedCopilotAccounts: [CopilotAuthAccount]?
    private var copilotAccountsCacheTimestamp: Date?

    /// Cached OpenCode config JSON (opencode.json)
    private var cachedOpenCodeConfigJSON: [String: Any]?
    private var openCodeConfigCacheTimestamp: Date?

    /// Path where opencode.json was found
    private(set) var lastFoundOpenCodeConfigPath: URL?

    private init() {
        logger.info("TokenManager initialized")
    }

    // MARK: - OpenCode Auth File Reading

    private func buildOpenCodeFilePaths(
        envVarName: String,
        envRelativePathComponents: [String],
        fallbackRelativePathComponents: [[String]]
    ) -> [URL] {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        var candidates: [URL] = []

        if let envBasePath = ProcessInfo.processInfo.environment[envVarName],
           !envBasePath.isEmpty {
            let envURL = envRelativePathComponents.reduce(URL(fileURLWithPath: envBasePath)) { partial, component in
                partial.appendingPathComponent(component)
            }
            candidates.append(envURL)
        }

        for relativeComponents in fallbackRelativePathComponents {
            let fallbackURL = relativeComponents.reduce(homeDir) { partial, component in
                partial.appendingPathComponent(component)
            }
            candidates.append(fallbackURL)
        }

        var deduped: [URL] = []
        var visited = Set<String>()
        for candidate in candidates {
            let normalizedPath = candidate.standardizedFileURL.path
            if visited.insert(normalizedPath).inserted {
                deduped.append(candidate)
            }
        }
        return deduped
    }

    /// Possible auth.json locations in priority order:
    /// 1. $XDG_DATA_HOME/opencode/auth.json (if XDG_DATA_HOME is set)
    /// 2. ~/.local/share/opencode/auth.json (XDG default, used by OpenCode)
    /// 3. ~/Library/Application Support/opencode/auth.json (macOS convention fallback)
    func getAuthFilePaths() -> [URL] {
        return buildOpenCodeFilePaths(
            envVarName: "XDG_DATA_HOME",
            envRelativePathComponents: ["opencode", "auth.json"],
            fallbackRelativePathComponents: [
                [".local", "share", "opencode", "auth.json"],
                ["Library", "Application Support", "opencode", "auth.json"]
            ]
        )
    }

    /// Possible opencode.json locations in priority order:
    /// 1. $XDG_CONFIG_HOME/opencode/opencode.json (if XDG_CONFIG_HOME is set)
    /// 2. ~/.config/opencode/opencode.json (XDG default on macOS/Linux)
    /// 3. ~/.local/share/opencode/opencode.json (fallback)
    /// 4. ~/Library/Application Support/opencode/opencode.json (macOS fallback)
    func getOpenCodeConfigFilePaths() -> [URL] {
        return buildOpenCodeFilePaths(
            envVarName: "XDG_CONFIG_HOME",
            envRelativePathComponents: ["opencode", "opencode.json"],
            fallbackRelativePathComponents: [
                [".config", "opencode", "opencode.json"],
                [".local", "share", "opencode", "opencode.json"],
                ["Library", "Application Support", "opencode", "opencode.json"]
            ]
        )
    }

    private func readOpenCodeConfigJSON() -> [String: Any]? {
        return queue.sync {
            if let cached = cachedOpenCodeConfigJSON,
               let timestamp = openCodeConfigCacheTimestamp,
               Date().timeIntervalSince(timestamp) < cacheValiditySeconds {
                return cached
            }

            let fileManager = FileManager.default
            let paths = getOpenCodeConfigFilePaths()
            for configPath in paths {
                guard fileManager.fileExists(atPath: configPath.path) else {
                    continue
                }
                guard fileManager.isReadableFile(atPath: configPath.path) else {
                    logger.warning("OpenCode config file not readable at \(configPath.path)")
                    continue
                }

                do {
                    let data = try Data(contentsOf: configPath)
                    let jsonObject = try JSONSerialization.jsonObject(with: data)
                    guard let dict = jsonObject as? [String: Any] else {
                        logger.warning("OpenCode config is not a JSON object at \(configPath.path)")
                        continue
                    }

                    lastFoundOpenCodeConfigPath = configPath
                    cachedOpenCodeConfigJSON = dict
                    openCodeConfigCacheTimestamp = Date()
                    return dict
                } catch {
                    logger.warning("Failed to parse OpenCode config at \(configPath.path): \(error.localizedDescription)")
                }
            }

            lastFoundOpenCodeConfigPath = nil
            cachedOpenCodeConfigJSON = nil
            openCodeConfigCacheTimestamp = nil
            return nil
        }
    }

    private func resolveConfigValue(_ rawValue: String?) -> String? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if value.hasPrefix("Bearer ") {
            value = String(value.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if value.hasPrefix("{env:"), value.hasSuffix("}") {
            let start = value.index(value.startIndex, offsetBy: 5)
            let end = value.index(before: value.endIndex)
            let envName = String(value[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !envName.isEmpty else { return nil }
            let envValue = ProcessInfo.processInfo.environment[envName]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (envValue?.isEmpty == false) ? envValue : nil
        }

        return value.isEmpty ? nil : value
    }

    private func nestedString(
        in dictionary: [String: Any],
        path: [String]
    ) -> String? {
        guard !path.isEmpty else { return nil }
        var current: Any = dictionary
        for key in path {
            guard let nested = current as? [String: Any], let next = nested[key] else {
                return nil
            }
            current = next
        }
        return current as? String
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
                guard fileManager.isReadableFile(atPath: authPath.path) else {
                    logger.warning("Auth file not readable at \(authPath.path)")
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
    private var cachedCodexLBAccounts: [OpenAIAuthAccount]?
    private var codexLBCacheTimestamp: Date?
    private(set) var lastFoundCodexLBStorePath: URL?
    private(set) var lastFoundCodexLBKeyPath: URL?

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

            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: codexAuthPath.path) else {
                return nil
            }
            guard fileManager.isReadableFile(atPath: codexAuthPath.path) else {
                logger.warning("Codex auth file not readable at \(codexAuthPath.path)")
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

    // MARK: - codex-lb SQLite Account Discovery

    private enum CodexLBError: LocalizedError {
        case invalidFernetKey
        case invalidFernetToken
        case invalidFernetSignature
        case sqliteOpenFailed
        case sqlitePrepareFailed(String)
        case sqliteStepFailed(Int32)
        case aesDecryptFailed(Int32)
        case invalidDecryptedToken

        var errorDescription: String? {
            switch self {
            case .invalidFernetKey:
                return "Invalid codex-lb Fernet key"
            case .invalidFernetToken:
                return "Invalid codex-lb Fernet token"
            case .invalidFernetSignature:
                return "Invalid codex-lb Fernet signature"
            case .sqliteOpenFailed:
                return "Failed to open codex-lb SQLite database"
            case .sqlitePrepareFailed(let message):
                return "Failed to prepare codex-lb SQLite query: \(message)"
            case .sqliteStepFailed(let status):
                return "Failed to read codex-lb SQLite rows (status \(status))"
            case .aesDecryptFailed(let status):
                return "codex-lb AES decryption failed (status \(status))"
            case .invalidDecryptedToken:
                return "codex-lb decrypted token is empty or invalid"
            }
        }
    }

    private struct CodexLBStoragePaths {
        let databaseURL: URL
        let keyURL: URL
    }

    private func codexLBStorageCandidates() -> [CodexLBStoragePaths] {
        var basePaths: [URL] = []
        if let customHome = ProcessInfo.processInfo.environment["CODEX_LB_HOME"],
           !customHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            basePaths.append(URL(fileURLWithPath: customHome, isDirectory: true))
        }

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        basePaths.append(homeDir.appendingPathComponent(".codex-lb", isDirectory: true))
        basePaths.append(URL(fileURLWithPath: "/var/lib/codex-lb", isDirectory: true))

        var visited = Set<String>()
        return basePaths.compactMap { baseURL in
            let normalizedBase = baseURL.standardizedFileURL.path
            guard visited.insert(normalizedBase).inserted else {
                return nil
            }
            return CodexLBStoragePaths(
                databaseURL: baseURL.appendingPathComponent("store.db"),
                keyURL: baseURL.appendingPathComponent("encryption.key")
            )
        }
    }

    private func sqliteColumnString(_ statement: OpaquePointer?, index: Int32) -> String? {
        let type = sqlite3_column_type(statement, index)
        switch type {
        case SQLITE_NULL:
            return nil
        case SQLITE_INTEGER:
            return String(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return String(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let textPointer = sqlite3_column_text(statement, index) else { return nil }
            let value = String(cString: textPointer).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        default:
            if let data = sqliteColumnData(statement, index: index),
               let string = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !string.isEmpty {
                return string
            }
            return nil
        }
    }

    private func sqliteColumnData(_ statement: OpaquePointer?, index: Int32) -> Data? {
        let type = sqlite3_column_type(statement, index)
        switch type {
        case SQLITE_NULL:
            return nil
        case SQLITE_BLOB:
            guard let blobPointer = sqlite3_column_blob(statement, index) else { return nil }
            let length = Int(sqlite3_column_bytes(statement, index))
            guard length > 0 else { return nil }
            return Data(bytes: blobPointer, count: length)
        case SQLITE_TEXT:
            guard let textPointer = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: textPointer).data(using: .utf8)
        default:
            return nil
        }
    }

    private func queryCodexLBEncryptedAccounts(databaseURL: URL) throws -> [CodexLBEncryptedAccount] {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "opencode-bar-codex-lb-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let tempDBURL = tempDirectory.appendingPathComponent("store.db")
        try fileManager.copyItem(at: databaseURL, to: tempDBURL)

        let optionalSidecars = [
            (
                source: URL(fileURLWithPath: databaseURL.path + "-wal"),
                destination: tempDirectory.appendingPathComponent("store.db-wal")
            ),
            (
                source: URL(fileURLWithPath: databaseURL.path + "-shm"),
                destination: tempDirectory.appendingPathComponent("store.db-shm")
            )
        ]
        for sidecar in optionalSidecars where fileManager.fileExists(atPath: sidecar.source.path) {
            try? fileManager.copyItem(at: sidecar.source, to: sidecar.destination)
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tempDBURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw CodexLBError.sqliteOpenFailed
        }
        defer { sqlite3_close(db) }

        let queries = [
            """
            SELECT
                id,
                email,
                plan_type,
                status,
                access_token_encrypted,
                refresh_token_encrypted,
                id_token_encrypted,
                last_refresh
            FROM accounts
            """,
            """
            SELECT
                id,
                email,
                NULL AS plan_type,
                NULL AS status,
                access_token_encrypted,
                NULL AS refresh_token_encrypted,
                NULL AS id_token_encrypted,
                NULL AS last_refresh
            FROM accounts
            """
        ]

        var statement: OpaquePointer?
        var prepared = false
        var prepareError = "Unknown SQLite error"
        for query in queries {
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                prepared = true
                break
            }
            if let errorMessage = sqlite3_errmsg(db) {
                prepareError = String(cString: errorMessage)
            }
        }
        guard prepared, let statement else {
            throw CodexLBError.sqlitePrepareFailed(prepareError)
        }
        defer { sqlite3_finalize(statement) }

        var accounts: [CodexLBEncryptedAccount] = []
        while true {
            let stepStatus = sqlite3_step(statement)
            if stepStatus == SQLITE_DONE {
                break
            }
            if stepStatus != SQLITE_ROW {
                throw CodexLBError.sqliteStepFailed(stepStatus)
            }

            guard let accessTokenEncrypted = sqliteColumnData(statement, index: 4), !accessTokenEncrypted.isEmpty else {
                continue
            }

            let account = CodexLBEncryptedAccount(
                accountId: sqliteColumnString(statement, index: 0),
                email: sqliteColumnString(statement, index: 1),
                planType: sqliteColumnString(statement, index: 2),
                status: sqliteColumnString(statement, index: 3),
                accessTokenEncrypted: accessTokenEncrypted,
                refreshTokenEncrypted: sqliteColumnData(statement, index: 5),
                idTokenEncrypted: sqliteColumnData(statement, index: 6),
                lastRefresh: sqliteColumnString(statement, index: 7)
            )
            accounts.append(account)
        }

        return accounts
    }

    private func decodeBase64URL(_ rawValue: String) throws -> Data {
        var sanitized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = sanitized.count % 4
        if remainder != 0 {
            sanitized += String(repeating: "=", count: 4 - remainder)
        }

        guard let decoded = Data(base64Encoded: sanitized) else {
            throw CodexLBError.invalidFernetToken
        }
        return decoded
    }

    private func decodeCodexLBFernetKey(_ keyData: Data) throws -> Data {
        let keyString = String(data: keyData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        guard !keyString.isEmpty else {
            throw CodexLBError.invalidFernetKey
        }
        let decodedKey = try decodeBase64URL(keyString)
        guard decodedKey.count == 32 else {
            throw CodexLBError.invalidFernetKey
        }
        return decodedKey
    }

    private func hmacSHA256(data: Data, key: Data) -> Data {
        var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        digest.withUnsafeMutableBytes { digestBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    CCHmac(
                        CCHmacAlgorithm(kCCHmacAlgSHA256),
                        keyBytes.baseAddress,
                        key.count,
                        dataBytes.baseAddress,
                        data.count,
                        digestBytes.baseAddress
                    )
                }
            }
        }
        return digest
    }

    private func aesCBCDecrypt(ciphertext: Data, key: Data, iv: Data) throws -> Data {
        let outputLength = ciphertext.count + kCCBlockSizeAES128
        var output = Data(count: outputLength)
        var decryptedLength: size_t = 0

        let cryptStatus = output.withUnsafeMutableBytes { outputBytes in
            ciphertext.withUnsafeBytes { cipherBytes in
                iv.withUnsafeBytes { ivBytes in
                    key.withUnsafeBytes { keyBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            cipherBytes.baseAddress,
                            ciphertext.count,
                            outputBytes.baseAddress,
                            outputLength,
                            &decryptedLength
                        )
                    }
                }
            }
        }

        guard cryptStatus == kCCSuccess else {
            throw CodexLBError.aesDecryptFailed(cryptStatus)
        }

        return output.prefix(decryptedLength)
    }

    private func decryptCodexLBFernetToken(_ encryptedToken: Data, key: Data) throws -> String {
        let tokenData: Data
        if encryptedToken.first == 0x80 {
            tokenData = encryptedToken
        } else {
            guard let tokenString = String(data: encryptedToken, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !tokenString.isEmpty else {
                throw CodexLBError.invalidFernetToken
            }
            tokenData = try decodeBase64URL(tokenString)
        }

        guard tokenData.count > 57, tokenData.first == 0x80 else {
            throw CodexLBError.invalidFernetToken
        }

        let signatureStart = tokenData.count - 32
        let signedData = tokenData.prefix(signatureStart)
        let signature = tokenData.suffix(32)

        let signingKey = key.prefix(16)
        let encryptionKey = key.suffix(16)
        let expectedSignature = hmacSHA256(data: Data(signedData), key: Data(signingKey))
        guard expectedSignature == signature else {
            throw CodexLBError.invalidFernetSignature
        }

        // Fernet payload layout: version(1) + timestamp(8) + iv(16) + ciphertext + hmac(32)
        let ivStart = 1 + 8
        let ivEnd = ivStart + 16
        guard signatureStart > ivEnd else {
            throw CodexLBError.invalidFernetToken
        }
        let iv = tokenData.subdata(in: ivStart..<ivEnd)
        let ciphertext = tokenData.subdata(in: ivEnd..<signatureStart)

        let decrypted = try aesCBCDecrypt(ciphertext: ciphertext, key: Data(encryptionKey), iv: iv)
        guard let token = String(data: decrypted, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty else {
            throw CodexLBError.invalidDecryptedToken
        }

        return token
    }

    func readCodexLBOpenAIAccounts() -> [OpenAIAuthAccount] {
        return queue.sync {
            if let cached = cachedCodexLBAccounts,
               let timestamp = codexLBCacheTimestamp,
               Date().timeIntervalSince(timestamp) < cacheValiditySeconds {
                return cached
            }

            let fileManager = FileManager.default
            for candidate in codexLBStorageCandidates() {
                guard fileManager.fileExists(atPath: candidate.databaseURL.path),
                      fileManager.fileExists(atPath: candidate.keyURL.path) else {
                    continue
                }
                guard fileManager.isReadableFile(atPath: candidate.databaseURL.path),
                      fileManager.isReadableFile(atPath: candidate.keyURL.path) else {
                    logger.warning("codex-lb files are not readable (db: \(candidate.databaseURL.path), key: \(candidate.keyURL.path))")
                    continue
                }

                do {
                    let keyData = try Data(contentsOf: candidate.keyURL)
                    let fernetKey = try decodeCodexLBFernetKey(keyData)
                    let encryptedAccounts = try queryCodexLBEncryptedAccounts(databaseURL: candidate.databaseURL)

                    if encryptedAccounts.isEmpty {
                        logger.info("codex-lb account table is empty at \(candidate.databaseURL.path)")
                        continue
                    }

                    var decodedAccounts: [OpenAIAuthAccount] = []
                    for encryptedAccount in encryptedAccounts {
                        do {
                            let accessToken = try decryptCodexLBFernetToken(
                                encryptedAccount.accessTokenEncrypted,
                                key: fernetKey
                            )
                            let normalizedAccountId = encryptedAccount.accountId?
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            let normalizedEmail = encryptedAccount.email?
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            decodedAccounts.append(
                                OpenAIAuthAccount(
                                    accessToken: accessToken,
                                    accountId: normalizedAccountId?.isEmpty == true ? nil : normalizedAccountId,
                                    email: normalizedEmail?.isEmpty == true ? nil : normalizedEmail,
                                    authSource: candidate.databaseURL.path,
                                    sourceLabels: [openAISourceLabel(for: .codexLB)],
                                    source: .codexLB
                                )
                            )
                            // PII fields (email, account ID) kept at debug level to avoid
                            // leaking personal info in production console logs.
                            logger.debug(
                                """
                                codex-lb account loaded: id=\(normalizedAccountId ?? "nil"), \
                                email=\(encryptedAccount.email ?? "unknown"), \
                                plan=\(encryptedAccount.planType ?? "unknown"), \
                                status=\(encryptedAccount.status ?? "unknown"), \
                                lastRefresh=\(encryptedAccount.lastRefresh ?? "unknown"), \
                                hasRefreshToken=\(encryptedAccount.refreshTokenEncrypted != nil ? "YES" : "NO"), \
                                hasIdToken=\(encryptedAccount.idTokenEncrypted != nil ? "YES" : "NO")
                                """
                            )
                        } catch {
                            logger.warning(
                                "Failed to decrypt codex-lb access token for account \(encryptedAccount.accountId ?? "unknown"): \(error.localizedDescription)"
                            )
                        }
                    }

                    let deduped = dedupeOpenAIAccounts(decodedAccounts)
                    if !deduped.isEmpty {
                        cachedCodexLBAccounts = deduped
                        codexLBCacheTimestamp = Date()
                        lastFoundCodexLBStorePath = candidate.databaseURL
                        lastFoundCodexLBKeyPath = candidate.keyURL
                        logger.info("Successfully loaded \(deduped.count) codex-lb OpenAI account(s) from: \(candidate.databaseURL.path)")
                        return deduped
                    }

                    logger.warning("codex-lb account rows found but no decryptable access token at \(candidate.databaseURL.path)")
                } catch {
                    logger.warning("Failed to read codex-lb accounts at \(candidate.databaseURL.path): \(error.localizedDescription)")
                }
            }

            cachedCodexLBAccounts = []
            codexLBCacheTimestamp = Date()
            lastFoundCodexLBStorePath = nil
            lastFoundCodexLBKeyPath = nil
            return []
        }
    }

    private func openAISourceLabel(for source: OpenAIAuthSource) -> String {
        switch source {
        case .opencodeAuth:
            return "OpenCode"
        case .codexLB:
            return "Codex LB"
        case .codexAuth:
            return "Codex"
        }
    }

    private func claudeSourceLabel(for source: ClaudeAuthSource) -> String {
        switch source {
        case .opencodeAuth:
            return "OpenCode"
        case .claudeCodeConfig:
            return "Claude Code"
        case .claudeCodeKeychain:
            return "Claude Code (Keychain)"
        case .claudeLegacyCredentials:
            return "Claude Code (Legacy)"
        }
    }

    private func geminiSourceLabel(for source: GeminiAuthSource) -> String {
        switch source {
        case .opencodeAuth:
            return "OpenCode"
        case .antigravity:
            return "Antigravity"
        case .oauthCreds:
            return "Gemini CLI"
        }
    }

    private func mergeSourceLabels(_ primary: [String], _ fallback: [String]) -> [String] {
        var merged: [String] = []
        for label in primary + fallback {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !merged.contains(trimmed) else { continue }
            merged.append(trimmed)
        }
        return merged
    }

    private func normalizedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func dedupeOpenAIAccounts(_ accounts: [OpenAIAuthAccount]) -> [OpenAIAuthAccount] {
        func priority(for source: OpenAIAuthSource) -> Int {
            switch source {
            case .opencodeAuth: return 2
            case .codexLB: return 1
            case .codexAuth: return 0
            }
        }

        var accountsByKey: [String: OpenAIAuthAccount] = [:]
        var keyOrder: [String] = []

        for account in accounts {
            let normalizedAccountId = normalizedNonEmpty(account.accountId)
            let normalizedEmail = normalizedNonEmpty(account.email)?.lowercased()
            let dedupeKey: String
            if let normalizedAccountId, !normalizedAccountId.isEmpty {
                dedupeKey = "id:\(normalizedAccountId)"
            } else if let normalizedEmail, !normalizedEmail.isEmpty {
                dedupeKey = "email:\(normalizedEmail)"
            } else {
                dedupeKey = "token:\(account.accessToken)"
            }

            if let existing = accountsByKey[dedupeKey] {
                let accountPriority = priority(for: account.source)
                let existingPriority = priority(for: existing.source)
                if accountPriority > existingPriority {
                    accountsByKey[dedupeKey] = mergeOpenAIAccount(primary: account, fallback: existing)
                } else if existingPriority > accountPriority {
                    accountsByKey[dedupeKey] = mergeOpenAIAccount(primary: existing, fallback: account)
                } else {
                    accountsByKey[dedupeKey] = mergeOpenAIAccount(primary: existing, fallback: account)
                }
                continue
            }

            keyOrder.append(dedupeKey)
            accountsByKey[dedupeKey] = account
        }

        let primaryDeduped = keyOrder.compactMap { accountsByKey[$0] }

        // Secondary merge by email to bridge sources where one account is missing accountId
        // but can still be identified by id_token email (Codex auth vs codex-lb).
        var emailIndexMap: [String: Int] = [:]
        var mergedResults: [OpenAIAuthAccount] = []

        for account in primaryDeduped {
            guard let normalizedEmail = normalizedNonEmpty(account.email)?.lowercased(),
                  !normalizedEmail.isEmpty else {
                mergedResults.append(account)
                continue
            }

            if let existingIndex = emailIndexMap[normalizedEmail] {
                let existing = mergedResults[existingIndex]
                let accountPriority = priority(for: account.source)
                let existingPriority = priority(for: existing.source)
                if accountPriority > existingPriority {
                    mergedResults[existingIndex] = mergeOpenAIAccount(primary: account, fallback: existing)
                } else {
                    mergedResults[existingIndex] = mergeOpenAIAccount(primary: existing, fallback: account)
                }
                continue
            }

            emailIndexMap[normalizedEmail] = mergedResults.count
            mergedResults.append(account)
        }

        return mergedResults
    }

    private func mergeOpenAIAccount(primary: OpenAIAuthAccount, fallback: OpenAIAuthAccount) -> OpenAIAuthAccount {
        let primaryAccountId = primary.accountId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackAccountId = fallback.accountId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryEmail = primary.email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackEmail = fallback.email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mergedSourceLabels = mergeSourceLabels(primary.sourceLabels, fallback.sourceLabels)

        return OpenAIAuthAccount(
            accessToken: primary.accessToken,
            accountId: (primaryAccountId?.isEmpty == false) ? primaryAccountId : fallbackAccountId,
            email: (primaryEmail?.isEmpty == false) ? primaryEmail : fallbackEmail,
            authSource: primary.authSource,
            sourceLabels: mergedSourceLabels,
            source: primary.source
        )
    }

    // MARK: - Shared JSON Helpers

    private func normalizedKey(_ key: String) -> String {
        return key.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private func readJSONDictionary(at url: URL) -> [String: Any]? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard fileManager.isReadableFile(atPath: url.path) else {
            logger.warning("JSON file not readable at \(url.path)")
            return nil
        }
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
            guard fileManager.isReadableFile(atPath: accountsPath.path) else {
                logger.warning("Antigravity accounts file not readable at \(accountsPath.path)")
                return nil
            }
            
            do {
                let data = try Data(contentsOf: accountsPath)
                let accounts = try JSONDecoder().decode(AntigravityAccounts.self, from: data)
                cachedAntigravityAccounts = accounts
                antigravityCacheTimestamp = Date()
                logger.info("Successfully loaded Antigravity accounts")
                return accounts
            } catch let decodingError as DecodingError {
                logger.error("Failed to decode Antigravity accounts: \(String(describing: decodingError))")
                return nil
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
                    sourceLabels: [claudeSourceLabel(for: source)],
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
                    sourceLabels: [claudeSourceLabel(for: .claudeCodeKeychain)],
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
                    sourceLabels: [claudeSourceLabel(for: .opencodeAuth)],
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
                let accountPriority = priority(for: account.source)
                let existingPriority = priority(for: existing.source)
                if accountPriority > existingPriority {
                    byToken[account.accessToken] = mergeClaudeAccount(primary: account, fallback: existing)
                } else if existingPriority > accountPriority {
                    byToken[account.accessToken] = mergeClaudeAccount(primary: existing, fallback: account)
                } else {
                    byToken[account.accessToken] = mergeClaudeAccount(primary: existing, fallback: account)
                }
            } else {
                byToken[account.accessToken] = account
            }
        }
        return Array(byToken.values)
    }

    private func mergeClaudeAccount(primary: ClaudeAuthAccount, fallback: ClaudeAuthAccount) -> ClaudeAuthAccount {
        let primaryAccountId = primary.accountId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackAccountId = fallback.accountId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryEmail = primary.email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackEmail = fallback.email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mergedSourceLabels = mergeSourceLabels(primary.sourceLabels, fallback.sourceLabels)

        return ClaudeAuthAccount(
            accessToken: primary.accessToken,
            accountId: (primaryAccountId?.isEmpty == false) ? primaryAccountId : fallbackAccountId,
            email: (primaryEmail?.isEmpty == false) ? primaryEmail : fallbackEmail,
            authSource: primary.authSource,
            sourceLabels: mergedSourceLabels,
            source: primary.source
        )
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

    /// Gets all OpenAI accounts (OpenCode auth + codex-lb + Codex native auth)
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
                    email: nil,
                    authSource: authSource,
                    sourceLabels: [openAISourceLabel(for: .opencodeAuth)],
                    source: .opencodeAuth
                )
            )
        }

        let codexLBAccounts = readCodexLBOpenAIAccounts()
        if !codexLBAccounts.isEmpty {
            accounts.append(contentsOf: codexLBAccounts)
        }

        if let codexAuth = readCodexAuth(),
           let access = codexAuth.tokens?.accessToken,
           !access.isEmpty {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            let authSource = homeDir
                .appendingPathComponent(".codex")
                .appendingPathComponent("auth.json")
                .path
            let idTokenPayload = decodeOpenAIIDTokenPayload(codexAuth.tokens?.idToken)
            let codexEmail = normalizedNonEmpty(idTokenPayload?.email)
            accounts.append(
                OpenAIAuthAccount(
                    accessToken: access,
                    accountId: codexAuth.tokens?.accountId,
                    email: codexEmail,
                    authSource: authSource,
                    sourceLabels: [openAISourceLabel(for: .codexAuth)],
                    source: .codexAuth
                )
            )
        }

        let deduped = dedupeOpenAIAccounts(accounts)
        logger.info("OpenAI accounts discovered: \(deduped.count)")
        return deduped
    }

    // MARK: - Gemini OAuth Auth File Reading (jenslys/opencode-gemini-auth)

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

    private func geminiOAuthClientCredentials(for audience: String?) -> (clientId: String, clientSecret: String) {
        let normalizedAudience = normalizedNonEmpty(audience)
        if normalizedAudience == TokenManager.geminiAuthPluginClientId {
            return (TokenManager.geminiAuthPluginClientId, TokenManager.geminiAuthPluginClientSecret)
        }
        if normalizedAudience == TokenManager.geminiClientId {
            return (TokenManager.geminiClientId, TokenManager.geminiClientSecret)
        }
        return (TokenManager.geminiClientId, TokenManager.geminiClientSecret)
    }

    /// Thread-safe read of Gemini OAuth auth stored under "google" in OpenCode auth.json (jenslys/opencode-gemini-auth)
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

    private func geminiOAuthCredsPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini")
            .appendingPathComponent("oauth_creds.json")
    }

    /// Thread-safe read of Gemini CLI OAuth creds (~/.gemini/oauth_creds.json)
    func readGeminiOAuthCreds() -> GeminiOAuthCreds? {
        return queue.sync {
            if let cached = cachedGeminiOAuthCreds,
               let timestamp = geminiOAuthCredsCacheTimestamp,
               Date().timeIntervalSince(timestamp) < cacheValiditySeconds {
                return cached
            }

            let credsPath = geminiOAuthCredsPath()
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: credsPath.path) else {
                lastFoundGeminiOAuthCredsPath = nil
                cachedGeminiOAuthCreds = nil
                geminiOAuthCredsCacheTimestamp = nil
                return nil
            }
            guard fileManager.isReadableFile(atPath: credsPath.path) else {
                logger.warning("Gemini oauth_creds.json is not readable at \(credsPath.path)")
                lastFoundGeminiOAuthCredsPath = nil
                cachedGeminiOAuthCreds = nil
                geminiOAuthCredsCacheTimestamp = nil
                return nil
            }

            do {
                let data = try Data(contentsOf: credsPath)
                let creds = try JSONDecoder().decode(GeminiOAuthCreds.self, from: data)
                lastFoundGeminiOAuthCredsPath = credsPath
                cachedGeminiOAuthCreds = creds
                geminiOAuthCredsCacheTimestamp = Date()
                logger.info("Successfully loaded Gemini OAuth creds from: \(credsPath.path)")
                return creds
            } catch {
                logger.warning("Failed to parse Gemini OAuth creds at \(credsPath.path): \(error.localizedDescription)")
                lastFoundGeminiOAuthCredsPath = nil
                cachedGeminiOAuthCreds = nil
                geminiOAuthCredsCacheTimestamp = nil
                return nil
            }
        }
    }

    private func decodeGeminiIDTokenPayload(_ idToken: String?) -> GeminiIDTokenPayload? {
        guard let token = normalizedNonEmpty(idToken) else {
            return nil
        }

        let parts = token.split(separator: ".")
        guard parts.count >= 2 else {
            return nil
        }

        let payload = String(parts[1])
        do {
            let data = try decodeBase64URL(payload)
            return try JSONDecoder().decode(GeminiIDTokenPayload.self, from: data)
        } catch {
            logger.warning("Failed to decode Gemini id_token payload: \(error.localizedDescription)")
            return nil
        }
    }

    private func decodeOpenAIIDTokenPayload(_ idToken: String?) -> OpenAIIDTokenPayload? {
        guard let token = normalizedNonEmpty(idToken) else {
            return nil
        }

        let parts = token.split(separator: ".")
        guard parts.count >= 2 else {
            return nil
        }

        let payload = String(parts[1])
        do {
            let data = try decodeBase64URL(payload)
            return try JSONDecoder().decode(OpenAIIDTokenPayload.self, from: data)
        } catch {
            logger.warning("Failed to decode OpenAI id_token payload: \(error.localizedDescription)")
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

    func getNanoGptAPIKey() -> String? {
        guard let auth = readOpenCodeAuth() else { return nil }
        return auth.nanoGpt?.key
    }

    func getSyntheticAPIKey() -> String? {
        guard let auth = readOpenCodeAuth() else { return nil }
        return auth.synthetic?.key
    }

    func getChutesAPIKey() -> String? {
        guard let auth = readOpenCodeAuth() else { return nil }
        return auth.chutes?.key
    }

    func getTavilyAPIKey() -> String? {
        guard let config = readOpenCodeConfigJSON() else { return nil }

        let envKey = nestedString(in: config, path: ["mcp", "tavily", "environment", "TAVILY_API_KEY"])
        if let resolved = resolveConfigValue(envKey) {
            return resolved
        }

        let authorization = nestedString(in: config, path: ["mcp", "tavily", "headers", "Authorization"])
        if let resolved = resolveConfigValue(authorization) {
            return resolved
        }

        let headerKey = nestedString(in: config, path: ["mcp", "tavily", "headers", "X-API-Key"])
        return resolveConfigValue(headerKey)
    }

    func getBraveSearchAPIKey() -> String? {
        guard let config = readOpenCodeConfigJSON() else { return nil }

        let envKey = nestedString(in: config, path: ["mcp", "brave-search", "environment", "BRAVE_API_KEY"])
        if let resolved = resolveConfigValue(envKey) {
            return resolved
        }

        let headerKey = nestedString(in: config, path: ["mcp", "brave-search", "headers", "X-Subscription-Token"])
        return resolveConfigValue(headerKey)
    }

    /// Gets Gemini refresh token from discovered Gemini account sources
    /// - Returns: Refresh token string if available, nil otherwise
    func getGeminiRefreshToken() -> String? {
        return getAllGeminiAccounts().first?.refreshToken
    }

    /// Gets Gemini account email from discovered Gemini account sources
    /// - Returns: Email string if available, nil otherwise
    func getGeminiAccountEmail() -> String? {
        return getAllGeminiAccounts().first?.email
    }

    /// Gets all Gemini accounts (NoeFabris/opencode-antigravity-auth + jenslys/opencode-gemini-auth)
    /// and enriches account identity metadata from ~/.gemini/oauth_creds.json when available.
    func getAllGeminiAccounts() -> [GeminiAuthAccount] {
        var accounts: [GeminiAuthAccount] = []
        let oauthCreds = readGeminiOAuthCreds()
        let oauthCredsPayload = decodeGeminiIDTokenPayload(oauthCreds?.idToken)
        let oauthCredsAccountId = normalizedNonEmpty(oauthCredsPayload?.sub)
        let oauthCredsEmail = normalizedNonEmpty(oauthCredsPayload?.email)
        let oauthCredsRefreshToken = normalizedNonEmpty(oauthCreds?.refreshToken)
        let oauthCredsAudience = normalizedNonEmpty(oauthCredsPayload?.audience)
        let oauthCredsClient = geminiOAuthClientCredentials(for: oauthCredsAudience)
        let geminiOAuthCredsSource = lastFoundGeminiOAuthCredsPath?.path ?? geminiOAuthCredsPath().path

        if oauthCreds != nil {
            logger.info(
                """
                Gemini oauth_creds.json discovered: refresh=\(oauthCredsRefreshToken != nil ? "YES" : "NO"), \
                accountId=\(oauthCredsAccountId != nil ? "YES" : "NO"), \
                email=\(oauthCredsEmail != nil ? "YES" : "NO"), \
                audience=\(oauthCredsAudience ?? "unknown")
                """
            )
        }

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
                        accountId: nil,
                        email: nil,
                        refreshToken: parts.refreshToken,
                        projectId: projectId,
                        authSource: authSource,
                        sourceLabels: [geminiSourceLabel(for: .opencodeAuth)],
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
            let antigravityAccounts = antigravity.accounts.enumerated().compactMap { index, account -> GeminiAuthAccount? in
                if account.enabled == false {
                    logger.info("Skipping disabled Antigravity account at index \(index)")
                    return nil
                }

                let refreshToken = account.refreshToken?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if refreshToken.isEmpty {
                    logger.warning("Skipping Antigravity account at index \(index): missing refresh token")
                    return nil
                }

                let primaryProjectId = account.projectId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let fallbackProjectId = account.managedProjectId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let projectId = primaryProjectId.isEmpty ? fallbackProjectId : primaryProjectId
                if projectId.isEmpty {
                    logger.warning("Skipping Antigravity account at index \(index): missing project ID")
                    return nil
                }

                let normalizedEmail = normalizedNonEmpty(account.email)
                let isRefreshTokenMatch = oauthCredsRefreshToken == refreshToken
                let isEmailMatch: Bool = {
                    guard let lhs = normalizedEmail?.lowercased(),
                          let rhs = oauthCredsEmail?.lowercased() else {
                        return false
                    }
                    return lhs == rhs
                }()
                let matchedOAuthCreds = isRefreshTokenMatch || isEmailMatch

                var sourceLabels = [geminiSourceLabel(for: .antigravity)]
                let mergedAccountId: String?
                let mergedEmail: String?
                if matchedOAuthCreds {
                    sourceLabels = mergeSourceLabels(sourceLabels, [geminiSourceLabel(for: .oauthCreds)])
                    mergedAccountId = oauthCredsAccountId
                    mergedEmail = normalizedEmail ?? oauthCredsEmail
                } else {
                    mergedAccountId = nil
                    mergedEmail = normalizedEmail
                }

                return GeminiAuthAccount(
                    index: index,
                    accountId: mergedAccountId,
                    email: mergedEmail,
                    refreshToken: refreshToken,
                    projectId: projectId,
                    authSource: authSource,
                    sourceLabels: sourceLabels,
                    clientId: TokenManager.geminiClientId,
                    clientSecret: TokenManager.geminiClientSecret,
                    source: .antigravity
                )
            }
            accounts.append(contentsOf: antigravityAccounts)
        }

        if accounts.isEmpty,
           let refreshToken = oauthCredsRefreshToken {
            let standaloneProjectId = normalizedNonEmpty(oauthCreds?.projectId)
                ?? normalizedNonEmpty(oauthCreds?.quotaProjectId)
                ?? normalizedNonEmpty(ProcessInfo.processInfo.environment["GEMINI_PROJECT_ID"])

            if let projectId = standaloneProjectId {
                accounts.append(
                    GeminiAuthAccount(
                        index: 0,
                        accountId: oauthCredsAccountId,
                        email: oauthCredsEmail,
                        refreshToken: refreshToken,
                        projectId: projectId,
                        authSource: geminiOAuthCredsSource,
                        sourceLabels: [geminiSourceLabel(for: .oauthCreds)],
                        clientId: oauthCredsClient.clientId,
                        clientSecret: oauthCredsClient.clientSecret,
                        source: .oauthCreds
                    )
                )
                logger.info("Gemini oauth_creds.json used as standalone account source")
            } else {
                logger.info("Gemini oauth_creds.json found but project ID is missing; skipping standalone account source")
            }
        }

        if accounts.isEmpty {
            return []
        }

        return accounts.enumerated().map { index, account in
            GeminiAuthAccount(
                index: index,
                accountId: account.accountId,
                email: account.email,
                refreshToken: account.refreshToken,
                projectId: account.projectId,
                authSource: account.authSource,
                sourceLabels: account.sourceLabels,
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
    
    /// OAuth client used by jenslys/opencode-gemini-auth plugin
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

        let codexLBAccounts = readCodexLBOpenAIAccounts()
        let codexLBCandidates = codexLBStorageCandidates()
        let codexLBExistingCandidate = codexLBCandidates.first {
            fileManager.fileExists(atPath: $0.databaseURL.path) || fileManager.fileExists(atPath: $0.keyURL.path)
        }
        if let storePath = lastFoundCodexLBStorePath,
           let keyPath = lastFoundCodexLBKeyPath {
            lines.append(
                "  codex-lb store.db (\(shortPath(storePath.path))): FOUND (\(codexLBAccounts.count) account(s))"
            )
            lines.append("  codex-lb encryption.key (\(shortPath(keyPath.path))): FOUND")
        } else if let candidate = codexLBExistingCandidate {
            let dbStatus: String
            if !fileManager.fileExists(atPath: candidate.databaseURL.path) {
                dbStatus = "NOT FOUND"
            } else if !fileManager.isReadableFile(atPath: candidate.databaseURL.path) {
                dbStatus = "UNREADABLE"
            } else {
                dbStatus = "FOUND"
            }

            let keyStatus: String
            if !fileManager.fileExists(atPath: candidate.keyURL.path) {
                keyStatus = "NOT FOUND"
            } else if !fileManager.isReadableFile(atPath: candidate.keyURL.path) {
                keyStatus = "UNREADABLE"
            } else {
                keyStatus = "FOUND"
            }

            lines.append("  codex-lb store.db (\(shortPath(candidate.databaseURL.path))): \(dbStatus)")
            lines.append("  codex-lb encryption.key (\(shortPath(candidate.keyURL.path))): \(keyStatus)")
            if dbStatus == "FOUND", keyStatus == "FOUND" {
                lines.append("  codex-lb accounts: 0 decryptable account(s)")
            }
        } else {
            let defaultCodexLBStore = homeDir.appendingPathComponent(".codex-lb").appendingPathComponent("store.db")
            let defaultCodexLBKey = homeDir.appendingPathComponent(".codex-lb").appendingPathComponent("encryption.key")
            lines.append("  codex-lb store.db (\(shortPath(defaultCodexLBStore.path))): NOT FOUND")
            lines.append("  codex-lb encryption.key (\(shortPath(defaultCodexLBKey.path))): NOT FOUND")
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
            lines.append("  OpenCode auth.json (google.oauth, jenslys/opencode-gemini-auth, \(shortPath(geminiAuthPath))): FOUND")
        } else {
            lines.append("  OpenCode auth.json (google.oauth, jenslys/opencode-gemini-auth, \(shortPath(geminiAuthPath))): NOT FOUND")
        }
        let geminiOAuthCreds = readGeminiOAuthCreds()
        let geminiOAuthCredsPath = lastFoundGeminiOAuthCredsPath?.path ?? geminiOAuthCredsPath().path
        if let geminiOAuthCreds {
            let refreshStatus = normalizedNonEmpty(geminiOAuthCreds.refreshToken) == nil ? "MISSING REFRESH TOKEN" : "FOUND"
            let payload = decodeGeminiIDTokenPayload(geminiOAuthCreds.idToken)
            let accountIdStatus = normalizedNonEmpty(payload?.sub) == nil ? "NO" : "YES"
            let emailStatus = normalizedNonEmpty(payload?.email) == nil ? "NO" : "YES"
            lines.append("  Gemini oauth_creds.json (\(shortPath(geminiOAuthCredsPath))): \(refreshStatus) (accountId: \(accountIdStatus), email: \(emailStatus))")
        } else {
            lines.append("  Gemini oauth_creds.json (\(shortPath(geminiOAuthCredsPath))): NOT FOUND")
        }
        if let accounts = readAntigravityAccounts() {
            lines.append("  Antigravity accounts (NoeFabris/opencode-antigravity-auth, \(shortPath(antigravityAccountsPath().path))): FOUND (\(accounts.accounts.count) account(s))")
        } else {
            lines.append("  Antigravity accounts (NoeFabris/opencode-antigravity-auth, \(shortPath(antigravityAccountsPath().path))): NOT FOUND")
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
            debugLines.append("  [Nano-GPT] \(auth.nanoGpt != nil ? "CONFIGURED" : "NOT CONFIGURED")")
        } else {
            debugLines.append("  [auth.json] PARSE FAILED or NOT FOUND")
        }

        // 4. Antigravity accounts
        if let accounts = readAntigravityAccounts() {
            let activeIndexText: String
            if let activeIndex = accounts.activeIndex {
                let invalidMarker = activeIndex < 0 || activeIndex >= accounts.accounts.count ? " (INVALID)" : ""
                activeIndexText = "\(activeIndex)\(invalidMarker)"
            } else {
                activeIndexText = "n/a"
            }
            debugLines.append("  [Antigravity] \(accounts.accounts.count) account(s), active index: \(activeIndexText)")
        } else {
            debugLines.append("  [Antigravity] NOT CONFIGURED")
        }
        if let geminiOAuthCreds = readGeminiOAuthCreds() {
            let refreshStatus = normalizedNonEmpty(geminiOAuthCreds.refreshToken) == nil ? "NO" : "YES"
            let payload = decodeGeminiIDTokenPayload(geminiOAuthCreds.idToken)
            let accountIdStatus = normalizedNonEmpty(payload?.sub) == nil ? "NO" : "YES"
            debugLines.append("  [Gemini oauth_creds] refreshToken: \(refreshStatus), accountId: \(accountIdStatus)")
        } else {
            debugLines.append("  [Gemini oauth_creds] NOT CONFIGURED")
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

        // 6. codex-lb multi-account auth (~/.codex-lb/store.db + encryption.key)
        debugLines.append("")
        debugLines.append("codex-lb Auth (~/.codex-lb):")
        let codexLBAccounts = readCodexLBOpenAIAccounts()
        if let storePath = lastFoundCodexLBStorePath,
           let keyPath = lastFoundCodexLBKeyPath {
            debugLines.append("  [FOUND] store.db: \(storePath.path)")
            debugLines.append("  [FOUND] encryption.key: \(keyPath.path)")
            debugLines.append("  [ACCOUNTS] \(codexLBAccounts.count) decryptable account(s)")
        } else {
            let candidates = codexLBStorageCandidates()
            if let candidate = candidates.first(where: {
                fileManager.fileExists(atPath: $0.databaseURL.path) || fileManager.fileExists(atPath: $0.keyURL.path)
            }) {
                let dbState = fileManager.fileExists(atPath: candidate.databaseURL.path) ? "FOUND" : "NOT FOUND"
                let keyState = fileManager.fileExists(atPath: candidate.keyURL.path) ? "FOUND" : "NOT FOUND"
                debugLines.append("  [\(dbState)] store.db: \(candidate.databaseURL.path)")
                debugLines.append("  [\(keyState)] encryption.key: \(candidate.keyURL.path)")
                debugLines.append("  [ACCOUNTS] 0 decryptable account(s)")
            } else {
                let defaultStore = homeDir.appendingPathComponent(".codex-lb").appendingPathComponent("store.db")
                let defaultKey = homeDir.appendingPathComponent(".codex-lb").appendingPathComponent("encryption.key")
                debugLines.append("  [NOT FOUND] store.db: \(defaultStore.path)")
                debugLines.append("  [NOT FOUND] encryption.key: \(defaultKey.path)")
            }
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

            if let nanoGpt = auth.nanoGpt {
                debugLines.append("[Nano-GPT] API Key Present")
                debugLines.append("  - Key Length: \(nanoGpt.key.count) chars")
                debugLines.append("  - Key Preview: \(maskToken(nanoGpt.key))")
            } else {
                debugLines.append("[Nano-GPT] NOT CONFIGURED")
            }
        } else {
            debugLines.append("[auth.json] PARSE FAILED or NOT FOUND")
        }

        // 6. Antigravity accounts
        if let accounts = readAntigravityAccounts() {
            debugLines.append("[Antigravity Accounts] \(accounts.accounts.count) account(s)")
            debugLines.append("  - Active Index: \(accounts.activeIndex.map { String($0) } ?? "n/a")")
            for (index, account) in accounts.accounts.enumerated() {
                let activeMarker = index == accounts.activeIndex ? " (ACTIVE)" : ""
                debugLines.append("  - [\(index)] \(account.email ?? "unknown")\(activeMarker)")
                debugLines.append("    - Enabled: \(account.enabled == false ? "NO" : "YES")")
                debugLines.append("    - Refresh Token: \(account.refreshToken?.count ?? 0) chars")
                debugLines.append("    - Project ID: \(account.projectId ?? account.managedProjectId ?? "missing")")
            }
        } else {
            debugLines.append("[Antigravity Accounts] NOT FOUND or PARSE FAILED")
        }

        if let geminiOAuthCreds = readGeminiOAuthCreds() {
            debugLines.append("[Gemini oauth_creds] FOUND at \(lastFoundGeminiOAuthCredsPath?.path ?? geminiOAuthCredsPath().path)")
            debugLines.append("  - Refresh Token: \(normalizedNonEmpty(geminiOAuthCreds.refreshToken) != nil ? "YES" : "NO")")
            let payload = decodeGeminiIDTokenPayload(geminiOAuthCreds.idToken)
            debugLines.append("  - Account ID: \(normalizedNonEmpty(payload?.sub) ?? "nil")")
            debugLines.append("  - Email: \(normalizedNonEmpty(payload?.email) ?? "nil")")
        } else {
            debugLines.append("[Gemini oauth_creds] NOT FOUND or PARSE FAILED")
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

        // 8. codex-lb auth (~/.codex-lb/store.db + encryption.key)
        debugLines.append("---------- codex-lb Auth ----------")
        let codexLBAccounts = readCodexLBOpenAIAccounts()
        if let storePath = lastFoundCodexLBStorePath,
           let keyPath = lastFoundCodexLBKeyPath {
            debugLines.append("[codex-lb] store.db: \(storePath.path)")
            debugLines.append("[codex-lb] encryption.key: \(keyPath.path)")
            debugLines.append("[codex-lb] Accounts: \(codexLBAccounts.count) decryptable")
        } else {
            let candidates = codexLBStorageCandidates()
            if let candidate = candidates.first(where: {
                fileManager.fileExists(atPath: $0.databaseURL.path) || fileManager.fileExists(atPath: $0.keyURL.path)
            }) {
                let dbState = fileManager.fileExists(atPath: candidate.databaseURL.path) ? "FOUND" : "NOT FOUND"
                let keyState = fileManager.fileExists(atPath: candidate.keyURL.path) ? "FOUND" : "NOT FOUND"
                debugLines.append("[codex-lb] store.db: \(candidate.databaseURL.path) (\(dbState))")
                debugLines.append("[codex-lb] encryption.key: \(candidate.keyURL.path) (\(keyState))")
                debugLines.append("[codex-lb] Accounts: 0 decryptable")
            } else {
                debugLines.append("[codex-lb] store.db: NOT FOUND")
                debugLines.append("[codex-lb] encryption.key: NOT FOUND")
            }
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
