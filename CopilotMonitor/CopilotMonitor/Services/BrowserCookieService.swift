import Foundation
import Security
import SQLite3
import CommonCrypto
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "BrowserCookieService")

/// Service for extracting and decrypting GitHub cookies from Chromium-based browsers.
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

    private func getEncryptionKey(for browser: SupportedBrowser) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: browser.keychainService,
            kSecAttrAccount as String: browser.keychainAccount,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            logger.error("Failed to get encryption key from Keychain for \(browser.displayName), status: \(status)")
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
