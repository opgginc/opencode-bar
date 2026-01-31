import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "GeminiCLIProvider")

// MARK: - Gemini CLI API Response Models

/// Response structure from Gemini CLI quota API
struct GeminiQuotaResponse: Codable {
    struct Bucket: Codable {
        let modelId: String
        let remainingFraction: Double
        let resetTime: String
    }
    
    let buckets: [Bucket]
}

// MARK: - GeminiCLIProvider Implementation

/// Provider for Google Gemini CLI quota tracking via cloudcode-pa.googleapis.com
/// Uses OAuth token refresh from antigravity-accounts.json
final class GeminiCLIProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .geminiCLI
    let type: ProviderType = .quotaBased
    
    private let tokenManager: TokenManager
    private let session: URLSession
    
    init(tokenManager: TokenManager = .shared, session: URLSession = .shared) {
        self.tokenManager = tokenManager
        self.session = session
    }
    
    // MARK: - ProviderProtocol Implementation
    
    func fetch() async throws -> ProviderResult {
        let allAccounts = tokenManager.getAllGeminiAccounts()
        
        guard !allAccounts.isEmpty else {
            logger.error("No Gemini accounts found")
            throw ProviderError.authenticationFailed("No Gemini accounts configured")
        }
        
        var geminiAccountQuotas: [GeminiAccountQuota] = []
        var overallMinPercentage = 100.0
        
        for account in allAccounts {
            do {
                let quotaResult = try await fetchQuotaForAccount(
                    refreshToken: account.refreshToken,
                    accountIndex: account.index,
                    email: account.email
                )
                geminiAccountQuotas.append(quotaResult)
                overallMinPercentage = min(overallMinPercentage, quotaResult.remainingPercentage)
            } catch {
                logger.warning("Failed to fetch quota for account #\(account.index + 1) (\(account.email)): \(error.localizedDescription)")
            }
        }
        
        guard !geminiAccountQuotas.isEmpty else {
            logger.error("Failed to fetch quota for any Gemini account")
            throw ProviderError.providerError("All account quota fetches failed")
        }
        
        logger.info("Gemini CLI: Fetched quota for \(geminiAccountQuotas.count)/\(allAccounts.count) accounts, overall min: \(overallMinPercentage)%")
        
        let usage = ProviderUsage.quotaBased(
            remaining: Int(overallMinPercentage),
            entitlement: 100,
            overagePermitted: false
        )
        
        let details = DetailedUsage(
            authSource: "~/.config/opencode/antigravity-accounts.json",
            geminiAccounts: geminiAccountQuotas
        )
        
        return ProviderResult(usage: usage, details: details)
    }
    
    // MARK: - Private Helpers
    
    private func fetchQuotaForAccount(refreshToken: String, accountIndex: Int, email: String) async throws -> GeminiAccountQuota {
        guard let accessToken = await tokenManager.refreshGeminiAccessToken(refreshToken: refreshToken) else {
            throw ProviderError.authenticationFailed("Unable to refresh token for account #\(accountIndex + 1)")
        }
        
        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota") else {
            throw ProviderError.networkError("Invalid API endpoint")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{}".data(using: .utf8)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response type")
        }
        
        if httpResponse.statusCode == 401 {
            throw ProviderError.authenticationFailed("Token expired for account #\(accountIndex + 1)")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }
        
        let quotaResponse = try JSONDecoder().decode(GeminiQuotaResponse.self, from: data)
        
        guard !quotaResponse.buckets.isEmpty else {
            throw ProviderError.decodingError("Empty buckets array")
        }
        
        var modelBreakdown: [String: Double] = [:]
        var minFraction = 1.0
        
        for bucket in quotaResponse.buckets {
            let percentage = bucket.remainingFraction * 100.0
            modelBreakdown[bucket.modelId] = percentage
            minFraction = min(minFraction, bucket.remainingFraction)
        }
        
        let remainingPercentage = minFraction * 100.0
        
        logger.info("Gemini CLI account #\(accountIndex + 1) (\(email)): \(remainingPercentage)% remaining")
        
        return GeminiAccountQuota(
            accountIndex: accountIndex,
            email: email,
            remainingPercentage: remainingPercentage,
            modelBreakdown: modelBreakdown,
            authSource: "~/.config/opencode/antigravity-accounts.json"
        )
    }
}
