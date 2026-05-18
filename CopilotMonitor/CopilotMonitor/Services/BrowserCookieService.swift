import Foundation
import Security
import SQLite3
import CommonCrypto
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "BrowserCookieService")
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Service for extracting and decrypting cookies from Chromium-based browsers.
/// Supports Chrome, Brave, Arc, and Edge on macOS.
/// Uses macOS Keychain for encryption key retrieval and PBKDF2 + AES-CBC for decryption.
class BrowserCookieService {
    static let shared = BrowserCookieService()

    private init() {}

    private func debugLog(_ message: String) {
        #if DEBUG
        let msg = "[\(Date())] BrowserCookieService: \(message)\n"
        if let data = msg.data(using: .utf8) {
            let path = "/tmp/cookie_debug.log"
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

    func getGitHubCookies() throws -> GitHubCookies {
        debugLog("Starting GitHub cookie extraction from browsers")

        for browser in SupportedBrowser.allCases {
            debugLog("Trying browser: \(browser.displayName)")
            let paths = browser.cookieDBPaths
            debugLog("Available cookie paths: \(paths.count)")

            do {
                let cookies = try extractCookies(from: browser)
                debugLog("Cookies extracted - userSession: \(cookies.userSession?.prefix(10) ?? "nil")..., loggedIn: \(cookies.loggedIn ?? "nil")")
                if cookies.isValid {
                    debugLog("Successfully extracted cookies from \(browser.displayName)")
                    return cookies
                }
                debugLog("Cookies from \(browser.displayName) are not valid (missing user_session or logged_in)")
            } catch {
                debugLog("Failed to extract from \(browser.displayName): \(error.localizedDescription)")
                continue
            }
        }

        debugLog("No browser found with valid GitHub cookies")
        throw BrowserCookieError.noBrowserFound
    }

    func getCookies(hostSuffix: String, names: Set<String>) throws -> [BrowserCookie] {
        var allCookies: [BrowserCookie] = []
        guard let normalizedHost = normalizedDomainHost(hostSuffix) else {
            throw BrowserCookieError.noBrowserFound
        }

        for browser in SupportedBrowser.allCases {
            let paths = browser.cookieDBPaths
            guard !paths.isEmpty else { continue }

            do {
                let encryptionKey = try getEncryptionKey(for: browser)
                let aesKey = try deriveAESKey(from: encryptionKey)

                for path in paths {
                    do {
                        let cookies = try readBrowserCookies(
                            from: path,
                            aesKey: aesKey,
                            hostSuffix: normalizedHost,
                            names: names
                        )
                        allCookies.append(contentsOf: cookies)
                    } catch {
                        debugLog("Failed to read browser cookies from \(path): \(error.localizedDescription)")
                    }
                }
            } catch {
                debugLog("Failed to prepare \(browser.displayName) cookie extraction: \(error.localizedDescription)")
            }
        }

        guard !allCookies.isEmpty else {
            throw BrowserCookieError.noBrowserFound
        }

        return allCookies
    }

    func getHistoryEntries(hostSuffix: String, pathPrefix: String, limit: Int = 100) throws -> [BrowserHistoryEntry] {
        var allEntries: [BrowserHistoryEntry] = []
        guard let normalizedHost = normalizedDomainHost(hostSuffix) else {
            throw BrowserCookieError.noBrowserFound
        }

        for browser in SupportedBrowser.allCases {
            for cookieDBPath in browser.cookieDBPaths {
                let historyPath = URL(fileURLWithPath: cookieDBPath)
                    .deletingLastPathComponent()
                    .appendingPathComponent("History")
                    .path

                guard FileManager.default.fileExists(atPath: historyPath) else { continue }

                do {
                    let entries = try readHistoryEntries(
                        from: historyPath,
                        browser: browser,
                        hostSuffix: normalizedHost,
                        pathPrefix: pathPrefix,
                        limit: limit
                    )
                    allEntries.append(contentsOf: entries)
                } catch {
                    debugLog("Failed to read browser history from \(historyPath): \(error.localizedDescription)")
                }
            }
        }

        guard !allEntries.isEmpty else {
            throw BrowserCookieError.noBrowserFound
        }

        return allEntries.sorted { $0.lastVisitTime > $1.lastVisitTime }
    }

    // MARK: - Browser Detection & Cookie Extraction

    private func extractCookies(from browser: SupportedBrowser) throws -> GitHubCookies {
        let cookieDBPaths = browser.cookieDBPaths
        debugLog("Found \(cookieDBPaths.count) cookie paths for \(browser.displayName)")

        guard !cookieDBPaths.isEmpty else {
            throw BrowserCookieError.cookieDBNotFound
        }

        let encryptionKey = try getEncryptionKey(for: browser)
        let aesKey = try deriveAESKey(from: encryptionKey)

        for path in cookieDBPaths {
            debugLog("Trying cookie path: \(path)")
            do {
                let cookies = try readCookies(from: path, aesKey: aesKey)
                if cookies.isValid {
                    debugLog("Found valid cookies at: \(path)")
                    return cookies
                }
                debugLog("Cookies at \(path) are not valid")
            } catch {
                debugLog("Failed to read cookies from \(path): \(error.localizedDescription)")
                continue
            }
        }

        throw BrowserCookieError.noBrowserFound
    }

    // MARK: - Keychain Access

    // Uses /usr/bin/security instead of SecItemCopyMatching to read
    // third-party keychain items. The security binary is Apple-signed and
    // matches the `apple-tool:` partition_id present on all keychain items,
    // so it never triggers a password prompt — even after app updates.
    private func getEncryptionKey(for browser: SupportedBrowser) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", browser.keychainService,
            "-a", browser.keychainAccount,
            "-w"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("Failed to run security command for \(browser.displayName): \(error)")
            throw BrowserCookieError.keychainAccessFailed
        }

        guard process.terminationStatus == 0 else {
            logger.error("security find-generic-password failed for \(browser.displayName), exit: \(process.terminationStatus)")
            throw BrowserCookieError.keychainAccessFailed
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let password = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !password.isEmpty else {
            logger.error("Empty encryption key from Keychain for \(browser.displayName)")
            throw BrowserCookieError.keychainAccessFailed
        }

        return password
    }

    // MARK: - Key Derivation (PBKDF2)

    /// Chrome PBKDF2: salt='saltysalt', iterations=1003, SHA1, 16-byte key
    private func deriveAESKey(from password: String) throws -> Data {
        let salt = "saltysalt"
        let iterations: UInt32 = 1003
        let keyLength = kCCKeySizeAES128

        var derivedKey = Data(count: keyLength)

        let derivationStatus = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            salt.data(using: .utf8)!.withUnsafeBytes { saltBytes in
                password.data(using: .utf8)!.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.utf8.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.utf8.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        iterations,
                        derivedKeyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }

        guard derivationStatus == kCCSuccess else {
            logger.error("PBKDF2 key derivation failed with status: \(derivationStatus)")
            throw BrowserCookieError.decryptionFailed
        }

        return derivedKey
    }

    // MARK: - SQLite Cookie Reading

    /// Copies database to temp file (Chrome locks the original)
    private func readCookies(from dbPath: String, aesKey: Data) throws -> GitHubCookies {
        let tempPath = NSTemporaryDirectory() + "github_cookies_temp_\(UUID().uuidString).db"
        try? FileManager.default.removeItem(atPath: tempPath)
        try FileManager.default.copyItem(atPath: dbPath, toPath: tempPath)
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tempPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            logger.error("Failed to open SQLite database at \(tempPath)")
            throw BrowserCookieError.invalidCookieFormat
        }
        defer { sqlite3_close(db) }

        let query = "SELECT name, encrypted_value, value FROM cookies WHERE host_key LIKE '%github.com%'"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            logger.error("Failed to prepare SQLite statement")
            throw BrowserCookieError.invalidCookieFormat
        }
        defer { sqlite3_finalize(statement) }

        var cookies: [String: String] = [:]

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(statement, 0) else { continue }
            let name = String(cString: namePtr)

            if let encryptedBlob = sqlite3_column_blob(statement, 1) {
                let encryptedLength = Int(sqlite3_column_bytes(statement, 1))
                if encryptedLength > 0 {
                    let encryptedData = Data(bytes: encryptedBlob, count: encryptedLength)

                    if let decrypted = try? decryptCookie(encryptedData, aesKey: aesKey), !decrypted.isEmpty {
                        cookies[name] = decrypted
                        logger.debug("Decrypted cookie: \(name)")
                        continue
                    }
                }
            }

            if let valuePtr = sqlite3_column_text(statement, 2) {
                let value = String(cString: valuePtr)
                if !value.isEmpty {
                    cookies[name] = value
                    logger.debug("Found plaintext cookie: \(name)")
                }
            }
        }

        logger.info("Found \(cookies.count) GitHub cookies")

        return GitHubCookies(
            userSession: cookies["user_session"],
            ghSess: cookies["__Host-gh_sess"],
            dotcomUser: cookies["dotcom_user"],
            loggedIn: cookies["logged_in"]
        )
    }

    private func readBrowserCookies(
        from dbPath: String,
        aesKey: Data,
        hostSuffix: String,
        names: Set<String>
    ) throws -> [BrowserCookie] {
        let tempPath = NSTemporaryDirectory() + "browser_cookies_temp_\(UUID().uuidString).db"
        try? FileManager.default.removeItem(atPath: tempPath)
        try FileManager.default.copyItem(atPath: dbPath, toPath: tempPath)
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tempPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            logger.error("Failed to open SQLite database at \(tempPath)")
            throw BrowserCookieError.invalidCookieFormat
        }
        defer { sqlite3_close(db) }

        let cookieNames = names.sorted()
        let nameFilter = cookieNames.isEmpty
            ? ""
            : " AND name IN (\(cookieNames.map { _ in "?" }.joined(separator: ", ")))"
        let query = """
            SELECT name, encrypted_value, value, host_key
            FROM cookies
            WHERE (host_key = ? OR host_key LIKE ? ESCAPE '\\')\(nameFilter)
            ORDER BY expires_utc DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            logger.error("Failed to prepare generic cookie SQLite statement")
            throw BrowserCookieError.invalidCookieFormat
        }
        defer { sqlite3_finalize(statement) }

        try bindText(hostSuffix, to: 1, in: statement, context: "cookie host")
        try bindText("%.\(escapedLikeLiteral(hostSuffix))", to: 2, in: statement, context: "cookie host pattern")
        for (offset, name) in cookieNames.enumerated() {
            try bindText(name, to: Int32(offset + 3), in: statement, context: "cookie name")
        }

        let dbURL = URL(fileURLWithPath: dbPath)
        let profileName = dbURL.deletingLastPathComponent().lastPathComponent
        let browser = SupportedBrowser.browser(forCookieDBPath: dbPath)
        var cookies: [BrowserCookie] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(statement, 0),
                  let domainPtr = sqlite3_column_text(statement, 3) else {
                continue
            }

            let name = String(cString: namePtr)
            guard names.isEmpty || names.contains(name) else { continue }

            var value: String?
            if let encryptedBlob = sqlite3_column_blob(statement, 1) {
                let encryptedLength = Int(sqlite3_column_bytes(statement, 1))
                if encryptedLength > 0 {
                    let encryptedData = Data(bytes: encryptedBlob, count: encryptedLength)
                    value = try? decryptCookie(encryptedData, aesKey: aesKey)
                }
            }

            if value?.isEmpty ?? true,
               let valuePtr = sqlite3_column_text(statement, 2) {
                value = String(cString: valuePtr)
            }

            guard let value, !value.isEmpty else { continue }

            cookies.append(BrowserCookie(
                name: name,
                value: value,
                domain: String(cString: domainPtr),
                browserName: browser?.displayName ?? "Browser",
                profileName: profileName,
                databasePath: dbPath
            ))
        }

        return cookies
    }

    private func readHistoryEntries(
        from dbPath: String,
        browser: SupportedBrowser,
        hostSuffix: String,
        pathPrefix: String,
        limit: Int
    ) throws -> [BrowserHistoryEntry] {
        let tempPath = NSTemporaryDirectory() + "browser_history_temp_\(UUID().uuidString).db"
        try? FileManager.default.removeItem(atPath: tempPath)
        try FileManager.default.copyItem(atPath: dbPath, toPath: tempPath)
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tempPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            logger.error("Failed to open SQLite history database at \(tempPath)")
            throw BrowserCookieError.invalidCookieFormat
        }
        defer { sqlite3_close(db) }

        let escapedHost = escapedLikeLiteral(hostSuffix)
        let escapedPrefix = escapedLikeLiteral(normalizedPathPrefix(pathPrefix))
        let cappedLimit = max(1, min(limit, 500))
        let query = """
            SELECT url, title, last_visit_time
            FROM urls
            WHERE url LIKE ? ESCAPE '\\'
               OR url LIKE ? ESCAPE '\\'
               OR url LIKE ? ESCAPE '\\'
               OR url LIKE ? ESCAPE '\\'
            ORDER BY last_visit_time DESC
            LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            logger.error("Failed to prepare browser history SQLite statement")
            throw BrowserCookieError.invalidCookieFormat
        }
        defer { sqlite3_finalize(statement) }

        let urlPatterns = [
            "https://\(escapedHost)\(escapedPrefix)%",
            "http://\(escapedHost)\(escapedPrefix)%",
            "https://%.\(escapedHost)\(escapedPrefix)%",
            "http://%.\(escapedHost)\(escapedPrefix)%"
        ]
        for (offset, pattern) in urlPatterns.enumerated() {
            try bindText(pattern, to: Int32(offset + 1), in: statement, context: "history URL pattern")
        }
        guard sqlite3_bind_int(statement, 5, Int32(cappedLimit)) == SQLITE_OK else {
            logger.error("Failed to bind browser history limit")
            throw BrowserCookieError.invalidCookieFormat
        }

        let dbURL = URL(fileURLWithPath: dbPath)
        let profileName = dbURL.deletingLastPathComponent().lastPathComponent
        var entries: [BrowserHistoryEntry] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let urlPtr = sqlite3_column_text(statement, 0),
                  let url = URL(string: String(cString: urlPtr)) else {
                continue
            }

            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let lastVisitTime = sqlite3_column_int64(statement, 2)

            entries.append(BrowserHistoryEntry(
                url: url,
                title: title,
                browserName: browser.displayName,
                profileName: profileName,
                databasePath: dbPath,
                lastVisitTime: lastVisitTime
            ))
        }

        return entries
    }

    private func normalizedDomainHost(_ host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let withoutLeadingDot = trimmed.hasPrefix(".") ? String(trimmed.dropFirst()) : trimmed
        return withoutLeadingDot.isEmpty ? nil : withoutLeadingDot
    }

    private func normalizedPathPrefix(_ pathPrefix: String) -> String {
        let trimmed = pathPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    private func escapedLikeLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func bindText(
        _ value: String,
        to index: Int32,
        in statement: OpaquePointer?,
        context: String
    ) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, sqliteTransient)
        }
        guard result == SQLITE_OK else {
            logger.error("Failed to bind SQLite text value for \(context, privacy: .public)")
            throw BrowserCookieError.invalidCookieFormat
        }
    }

    // MARK: - AES-CBC Decryption

    /// Chromium cookies: v10/v11 prefix, IV=16 spaces (0x20), skip first 32 garbage bytes
    private func decryptCookie(_ encryptedData: Data, aesKey: Data) throws -> String {
        guard encryptedData.count > 3 else {
            throw BrowserCookieError.invalidCookieFormat
        }

        let prefix = encryptedData.prefix(3)
        let prefixString = String(data: prefix, encoding: .utf8)

        guard prefixString == "v10" || prefixString == "v11" else {
            if let plaintext = String(data: encryptedData, encoding: .utf8) {
                return plaintext
            }
            throw BrowserCookieError.invalidCookieFormat
        }

        let ciphertext = Data(encryptedData.dropFirst(3))
        guard !ciphertext.isEmpty else {
            throw BrowserCookieError.invalidCookieFormat
        }

        // Chrome uses 16 spaces (0x20) as IV
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)

        let bufferSize = ciphertext.count + kCCBlockSizeAES128
        var outputBuffer = Data(count: bufferSize)
        var decryptedLength: size_t = 0

        let cryptStatus = outputBuffer.withUnsafeMutableBytes { outputBytes in
            ciphertext.withUnsafeBytes { ciphertextBytes in
                iv.withUnsafeBytes { ivBytes in
                    aesKey.withUnsafeBytes { keyBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, kCCKeySizeAES128,
                            ivBytes.baseAddress,
                            ciphertextBytes.baseAddress, ciphertext.count,
                            outputBytes.baseAddress, bufferSize,
                            &decryptedLength
                        )
                    }
                }
            }
        }

        guard cryptStatus == kCCSuccess else {
            logger.error("AES decryption failed with status: \(cryptStatus)")
            throw BrowserCookieError.decryptionFailed
        }

        let decryptedData = outputBuffer.prefix(decryptedLength)

        // Chrome on macOS prepends 32 bytes of garbage (2 AES blocks)
        let skipBytes = 32
        if decryptedData.count > skipBytes {
            let actualData = Data(decryptedData.dropFirst(skipBytes))
            if let result = String(data: actualData, encoding: .utf8) {
                return result.trimmingCharacters(in: .controlCharacters)
            }

            for i in 0..<actualData.count {
                let slice = actualData.dropFirst(i)
                if let result = String(data: slice, encoding: .utf8), !result.isEmpty {
                    return result.trimmingCharacters(in: .controlCharacters)
                }
            }
        }

        if let result = String(data: decryptedData, encoding: .utf8) {
            return result.trimmingCharacters(in: .controlCharacters)
        }

        throw BrowserCookieError.invalidCookieFormat
    }
}

// MARK: - Supporting Types

enum SupportedBrowser: CaseIterable {
    case chrome
    case brave
    case arc
    case edge

    var displayName: String {
        switch self {
        case .chrome: return "Chrome"
        case .brave: return "Brave"
        case .arc: return "Arc"
        case .edge: return "Edge"
        }
    }

    var cookieDBPath: String {
        cookieDBPaths.first ?? ""
    }

    var cookieDBPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths: [String] = []

        switch self {
        case .chrome:
            let baseDir = "\(home)/Library/Application Support/Google/Chrome"
            paths.append("\(baseDir)/Default/Cookies")
            paths.append(contentsOf: findProfilePaths(in: baseDir))
        case .brave:
            let baseDir = "\(home)/Library/Application Support/BraveSoftware/Brave-Browser"
            paths.append("\(baseDir)/Default/Cookies")
            paths.append(contentsOf: findProfilePaths(in: baseDir))
        case .arc:
            let baseDir = "\(home)/Library/Application Support/Arc/User Data"
            paths.append("\(baseDir)/Default/Cookies")
            paths.append(contentsOf: findProfilePaths(in: baseDir))
        case .edge:
            let baseDir = "\(home)/Library/Application Support/Microsoft Edge"
            paths.append("\(baseDir)/Default/Cookies")
            paths.append(contentsOf: findProfilePaths(in: baseDir))
        }

        return paths.filter { FileManager.default.fileExists(atPath: $0) }
    }

    private func findProfilePaths(in baseDir: String) -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: baseDir) else {
            return []
        }

        return contents
            .filter { $0.hasPrefix("Profile ") }
            .map { "\(baseDir)/\($0)/Cookies" }
    }

    static func browser(forCookieDBPath path: String) -> SupportedBrowser? {
        allCases.first { browser in
            browser.cookieDBPaths.contains(path)
        }
    }

    var keychainService: String {
        switch self {
        case .chrome: return "Chrome Safe Storage"
        case .brave: return "Brave Safe Storage"
        case .arc: return "Arc Safe Storage"
        case .edge: return "Microsoft Edge Safe Storage"
        }
    }

    var keychainAccount: String {
        switch self {
        case .chrome: return "Chrome"
        case .brave: return "Brave"
        case .arc: return "Arc"
        case .edge: return "Microsoft Edge"
        }
    }
}

struct GitHubCookies {
    let userSession: String?
    let ghSess: String?
    let dotcomUser: String?
    let loggedIn: String?

    var isValid: Bool {
        return loggedIn == "yes" && userSession != nil
    }

    var cookieHeader: String {
        var parts: [String] = []
        if let userSession = userSession {
            parts.append("user_session=\(userSession)")
        }
        if let ghSess = ghSess {
            parts.append("__Host-gh_sess=\(ghSess)")
        }
        if let dotcomUser = dotcomUser {
            parts.append("dotcom_user=\(dotcomUser)")
        }
        if let loggedIn = loggedIn {
            parts.append("logged_in=\(loggedIn)")
        }
        return parts.joined(separator: "; ")
    }
}

struct BrowserCookie {
    let name: String
    let value: String
    let domain: String
    let browserName: String
    let profileName: String
    let databasePath: String

    var profileKey: String {
        "\(browserName)::\(profileName)::\(URL(fileURLWithPath: databasePath).deletingLastPathComponent().path)"
    }

    var displaySource: String {
        "\(browserName) \(profileName)"
    }
}

struct BrowserHistoryEntry {
    let url: URL
    let title: String?
    let browserName: String
    let profileName: String
    let databasePath: String
    let lastVisitTime: Int64

    var profileKey: String {
        "\(browserName)::\(profileName)::\(URL(fileURLWithPath: databasePath).deletingLastPathComponent().path)"
    }

    var displaySource: String {
        "\(browserName) \(profileName)"
    }
}

enum BrowserCookieError: LocalizedError {
    case noBrowserFound
    case cookieDBNotFound
    case keychainAccessFailed
    case decryptionFailed
    case invalidCookieFormat

    var errorDescription: String? {
        switch self {
        case .noBrowserFound:
            return "No supported browser found with GitHub cookies"
        case .cookieDBNotFound:
            return "Cookie database not found"
        case .keychainAccessFailed:
            return "Failed to access browser encryption key from Keychain"
        case .decryptionFailed:
            return "Failed to decrypt cookie value"
        case .invalidCookieFormat:
            return "Invalid or corrupted cookie format"
        }
    }
}
