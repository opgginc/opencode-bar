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

    enum CodingKeys: String, CodingKey {
        case anthropic, openai, openrouter, opencode
        case githubCopilot = "github-copilot"
        case kimiForCoding = "kimi-for-coding"
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

    /// Reads OpenCode auth tokens with fallback paths
    /// Tries multiple locations in priority order until a valid auth.json is found
    /// - Returns: OpenCodeAuth structure if file exists and is valid, nil otherwise
    func readOpenCodeAuth() -> OpenCodeAuth? {
        let fileManager = FileManager.default
        let paths = getAuthFilePaths()

        for authPath in paths {
            guard fileManager.fileExists(atPath: authPath.path) else {
                logger.debug("Auth file not found at: \(authPath.path)")
                continue
            }

            do {
                let data = try Data(contentsOf: authPath)
                let auth = try JSONDecoder().decode(OpenCodeAuth.self, from: data)
                lastFoundAuthPath = authPath
                logger.info("Successfully loaded OpenCode auth from: \(authPath.path)")
                return auth
            } catch {
                logger.warning("Failed to parse auth at \(authPath.path): \(error.localizedDescription)")
                continue
            }
        }

        lastFoundAuthPath = nil
        logger.error("No valid auth.json found in any location. Searched: \(paths.map { $0.path }.joined(separator: ", "))")
        return nil
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

    func getOpenCodeAPIKey() -> String? {
        guard let auth = readOpenCodeAuth() else { return nil }
        return auth.opencode?.key
    }

    func getKimiAPIKey() -> String? {
        guard let auth = readOpenCodeAuth() else { return nil }
        return auth.kimiForCoding?.key
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
        return accounts.accounts.enumerated().map { index, account in
            (index: index, email: account.email, refreshToken: account.refreshToken)
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

    func logDebugEnvironmentInfo() {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser

        var debugLines: [String] = []
        debugLines.append("========== Environment Debug Info ==========")

        // 0. XDG_DATA_HOME environment variable
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
            switch index {
            case 0 where ProcessInfo.processInfo.environment["XDG_DATA_HOME"] != nil:
                pathLabel = "$XDG_DATA_HOME/opencode"
            case 0, 1:
                pathLabel = "~/.local/share/opencode"
            default:
                pathLabel = "~/Library/Application Support/opencode"
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

        // 4. OpenCode CLI existence (dynamic search)
        debugLines.append("[OpenCode CLI] Searching...")
        if let cliPath = findOpenCodeCLI() {
            debugLines.append("[OpenCode CLI] FOUND at \(cliPath)")
        } else {
            debugLines.append("[OpenCode CLI] NOT FOUND in PATH or common locations")
            debugLines.append("  Searched: /opt/homebrew/bin, /usr/local/bin, ~/.opencode/bin, ~/.local/bin")
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

        debugLines.append("================================================")

        // Log all debug info
        let fullDebugLog = debugLines.joined(separator: "\n")
        logger.info("\n\(fullDebugLog)")

        // Also write to debug file for easier access
        #if DEBUG
        writeToDebugFile(fullDebugLog)
        #endif
    }

    private func findOpenCodeCLI() -> String? {
        // Try 'which opencode' first
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["opencode"]
        let whichPipe = Pipe()
        whichProcess.standardOutput = whichPipe
        whichProcess.standardError = FileHandle.nullDevice
        
        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            if whichProcess.terminationStatus == 0 {
                let data = whichPipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    return path
                }
            }
        } catch {}
        
        // Try login shell PATH
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellProcess = Process()
        shellProcess.executableURL = URL(fileURLWithPath: shell)
        shellProcess.arguments = ["-lc", "which opencode 2>/dev/null"]
        let shellPipe = Pipe()
        shellProcess.standardOutput = shellPipe
        shellProcess.standardError = FileHandle.nullDevice
        
        do {
            try shellProcess.run()
            shellProcess.waitUntilExit()
            if shellProcess.terminationStatus == 0 {
                let data = shellPipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    return path
                }
            }
        } catch {}
        
        // Fallback to hardcoded paths
        let fallbackPaths = [
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opencode/bin/opencode").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/opencode").path,
        ]
        
        for path in fallbackPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        
        return nil
    }
    
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
