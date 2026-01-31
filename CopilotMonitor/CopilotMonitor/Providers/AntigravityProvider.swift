import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "AntigravityProvider")

private func runCommandAsync(executableURL: URL, arguments: [String]) async throws -> String {
    return try await withCheckedThrowingContinuation { continuation in
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        var outputData = Data()
        
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                outputData.append(data)
            }
        }
        
        process.terminationHandler = { _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            
            let remainingData = pipe.fileHandleForReading.readDataToEndOfFile()
            if !remainingData.isEmpty {
                outputData.append(remainingData)
            }
            
            guard let output = String(data: outputData, encoding: .utf8) else {
                continuation.resume(throwing: ProviderError.providerError("Cannot decode output"))
                return
            }
            
            continuation.resume(returning: output)
        }
        
        do {
            try process.run()
        } catch {
            continuation.resume(throwing: error)
        }
    }
}

// MARK: - Antigravity API Response Models

/// Response structure from Antigravity local language server API
struct AntigravityResponse: Codable {
    let userStatus: UserStatus?
    
    struct UserStatus: Codable {
        let email: String?
        let userTier: UserTier?
        let planStatus: PlanStatus?
        let cascadeModelConfigData: CascadeModelConfigData?
        
        struct UserTier: Codable {
            let name: String?
        }
        
        struct PlanStatus: Codable {
            let planInfo: PlanInfo?
            
            struct PlanInfo: Codable {
                let planDisplayName: String?
            }
        }
        
        struct CascadeModelConfigData: Codable {
            let clientModelConfigs: [ClientModelConfig]?
        }
        
        struct ClientModelConfig: Codable {
            let label: String
            let modelOrAlias: ModelOrAlias?
            let quotaInfo: QuotaInfo?
            
            struct ModelOrAlias: Codable {
                let model: String?
            }
            
            struct QuotaInfo: Codable {
                let remainingFraction: Double?
                let resetTime: String?
            }
        }
    }
}

// MARK: - AntigravityProvider Implementation

/// Provider for Antigravity local language server usage tracking
/// Connects to local language_server_macos process via HTTPS API
/// Uses quota-based model with per-model remaining percentages
final class AntigravityProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .antigravity
    let type: ProviderType = .quotaBased
    
    // MARK: - ProviderProtocol Implementation
    
    /// Fetches Antigravity usage data from local language server
    /// - Returns: ProviderResult with minimum remaining quota percentage across all models
    /// - Throws: ProviderError if fetch fails or Antigravity not running
    func fetch() async throws -> ProviderResult {
        // Step 1: Find language_server_macos process
        let (pid, csrfToken) = try await detectProcessInfo()
        logger.info("Found Antigravity process: PID=\(pid), CSRF=\(csrfToken.prefix(8))...")
        
        // Step 2: Find listening port
        let port = try await detectPort(pid: pid)
        logger.info("Found listening port: \(port)")
        
        // Step 3: Call API
        let response = try await makeRequest(port: port, csrfToken: csrfToken)
        
        // Step 4: Parse response and calculate usage
        return try parseResponse(response)
    }
    
    // MARK: - Private Helpers
    
    private func detectProcessInfo() async throws -> (Int, String) {
        let output = try await runCommandAsync(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-ax", "-o", "pid=,command="]
        )
        
        let lines = output.components(separatedBy: "\n")
        guard let processLine = lines.first(where: { 
            $0.contains("language_server_macos") && $0.contains("antigravity") && !$0.contains("grep")
        }) else {
            logger.warning("Antigravity language server not running")
            throw ProviderError.providerError("Antigravity not running")
        }
        
        let components = processLine.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces)
        guard let pidString = components.first, let pid = Int(pidString) else {
            logger.error("Cannot parse PID from process line")
            throw ProviderError.providerError("Cannot parse PID")
        }
        
        let csrfPattern = "--csrf_token[= ]+([a-zA-Z0-9-]+)"
        guard let regex = try? NSRegularExpression(pattern: csrfPattern),
              let match = regex.firstMatch(in: processLine, range: NSRange(processLine.startIndex..., in: processLine)),
              let range = Range(match.range(at: 1), in: processLine) else {
            logger.error("Cannot extract CSRF token from process args")
            throw ProviderError.providerError("Cannot extract CSRF token")
        }
        
        let csrfToken = String(processLine[range])
        return (pid, csrfToken)
    }
    
    private func detectPort(pid: Int) async throws -> Int {
        let output = try await runCommandAsync(
            executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", "\(pid)"]
        )
        
        let portPattern = "(?:\\*|127\\.0\\.0\\.1):(\\d+) \\(LISTEN\\)"
        guard let regex = try? NSRegularExpression(pattern: portPattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output),
              let port = Int(output[range]) else {
            logger.error("Cannot find listening port in lsof output: \(output)")
            throw ProviderError.providerError("Cannot find listening port")
        }
        
        return port
    }
    
    /// Makes HTTPS request to local language server API
    /// - Parameters:
    ///   - port: Port number
    ///   - csrfToken: CSRF token for authentication
    /// - Returns: Decoded AntigravityResponse
    /// - Throws: ProviderError if request fails
    private func makeRequest(port: Int, csrfToken: String) async throws -> AntigravityResponse {
        guard let url = URL(string: "https://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/GetUserStatus") else {
            logger.error("Invalid API URL")
            throw ProviderError.networkError("Invalid API endpoint")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Request body
        let requestBody: [String: Any] = [
            "metadata": [
                "ideName": "antigravity",
                "extensionName": "antigravity",
                "ideVersion": "unknown",
                "locale": "en"
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        // Create session with self-signed cert delegate
        let configuration = URLSessionConfiguration.default
        let session = URLSession(configuration: configuration, delegate: SelfSignedCertDelegate(), delegateQueue: nil)
        
        // Execute request
        let (data, response) = try await session.data(for: request)
        
        // Check HTTP status
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type from Antigravity API")
            throw ProviderError.networkError("Invalid response type")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            logger.error("Antigravity API returned status \(httpResponse.statusCode)")
            throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }
        
        // Parse response
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(AntigravityResponse.self, from: data)
        } catch {
            logger.error("Failed to decode Antigravity response: \(error.localizedDescription)")
            throw ProviderError.decodingError("Invalid response format: \(error.localizedDescription)")
        }
    }
    
    /// Parses Antigravity response and calculates usage
    /// - Parameter response: Decoded API response
    /// - Returns: ProviderResult with quota-based usage
    /// - Throws: ProviderError if response is invalid
    private func parseResponse(_ response: AntigravityResponse) throws -> ProviderResult {
        guard let userStatus = response.userStatus else {
            logger.error("Antigravity API response missing userStatus")
            throw ProviderError.providerError("Missing userStatus")
        }
        
        // Extract email
        let email = userStatus.email
        
        // Extract plan name (try userTier.name first, fallback to planStatus.planInfo.planDisplayName)
        let plan = userStatus.userTier?.name ?? userStatus.planStatus?.planInfo?.planDisplayName ?? "unknown"
        
        // Extract model quotas
        guard let modelConfigs = userStatus.cascadeModelConfigData?.clientModelConfigs else {
            logger.error("Antigravity API response missing model configs")
            throw ProviderError.providerError("Missing model configs")
        }
        
        // Calculate remaining percentages for each model
        var modelBreakdown: [String: Double] = [:]
        var remainingPercentages: [Double] = []
        
        for config in modelConfigs {
            guard let quotaInfo = config.quotaInfo else { continue }
            
            // remainingFraction is 0.0-1.0, convert to percentage
            let remainingFraction = quotaInfo.remainingFraction ?? 1.0
            let remainingPercent = remainingFraction * 100.0
            
            modelBreakdown[config.label] = remainingPercent
            remainingPercentages.append(remainingPercent)
            
            logger.debug("Model \(config.label): \(String(format: "%.1f", remainingPercent))% remaining")
        }
        
        // Use minimum remaining percentage across all models
        let minRemaining = remainingPercentages.min() ?? 0.0
        
        logger.info("Antigravity usage fetched: \(String(format: "%.1f", minRemaining))% remaining (min of \(remainingPercentages.count) models)")
        
        // Build detailed usage
        let details = DetailedUsage(
            modelBreakdown: modelBreakdown,
            planType: plan,
            email: email
        )
        
        // Return as quota-based usage
        let usage = ProviderUsage.quotaBased(
            remaining: Int(minRemaining),
            entitlement: 100,
            overagePermitted: false
        )
        
        return ProviderResult(usage: usage, details: details)
    }
}

// MARK: - SSL Delegate for Self-Signed Certificates

/// URLSessionDelegate that accepts self-signed certificates for localhost
/// Required because Antigravity language server uses self-signed HTTPS
private class SelfSignedCertDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Accept self-signed certificates for localhost only
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust,
           challenge.protectionSpace.host == "127.0.0.1" {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
