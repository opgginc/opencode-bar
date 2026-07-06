import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "OpenCodeProvider")

/// Provider for OpenCode API usage tracking
/// Uses pay-as-you-go billing model with credit-based utilization
final class OpenCodeProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .openCode
    let type: ProviderType = .payAsYouGo

    private let tokenManager = TokenManager.shared

    // MARK: - API Response Structures

    private struct CreditsResponse: Codable {
        let data: CreditsData

        struct CreditsData: Codable {
            let total_credits: Double
            let used_credits: Double
            let remaining_credits: Double
        }
    }

    // MARK: - ProviderProtocol

    func fetch() async throws -> ProviderResult {
        guard let apiKey = tokenManager.getOpenCodeAPIKey() else {
            logger.debug("OpenCode API key not found")
            throw ProviderError.authenticationFailed("OpenCode API key not found")
        }

        let endpoint = "https://api.opencode.ai/v1/credits"
        guard let url = URL(string: endpoint) else {
            logger.error("Invalid credits endpoint URL")
            throw ProviderError.networkError("Invalid endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type from credits API")
            throw ProviderError.networkError("Invalid response type")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 || httpResponse.statusCode == 404 {
            logger.debug("OpenCode API not available (HTTP \(httpResponse.statusCode))")
            throw ProviderError.authenticationFailed("API not available (HTTP \(httpResponse.statusCode))")
        }

        guard httpResponse.statusCode == 200 else {
            logger.error("Credits API request failed with status code: \(httpResponse.statusCode)")
            throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }

        // OpenCode API returns "Not Found" text with HTTP 200 when endpoint doesn't exist
        if let bodyString = String(data: data, encoding: .utf8),
           bodyString.trimmingCharacters(in: .whitespacesAndNewlines) == "Not Found" {
            logger.debug("OpenCode API endpoint not available (returned 'Not Found')")
            throw ProviderError.authenticationFailed("API endpoint not available")
        }

        let decoded: CreditsResponse
        do {
            decoded = try JSONDecoder().decode(CreditsResponse.self, from: data)
        } catch {
            logger.error("Failed to decode credits response: \(error.localizedDescription)")
            throw ProviderError.decodingError(error.localizedDescription)
        }

        let utilization: Double
        if decoded.data.total_credits > 0 {
            utilization = (decoded.data.used_credits / decoded.data.total_credits) * 100.0
        } else {
            utilization = 0.0
            logger.warning("Total credits is zero, setting utilization to 0%")
        }

        logger.info("Successfully fetched OpenCode usage: \(String(format: "%.2f", utilization))% utilized (used: \(decoded.data.used_credits), total: \(decoded.data.total_credits))")

        let details = DetailedUsage(
            monthlyUsage: decoded.data.used_credits,
            limit: decoded.data.total_credits,
            limitRemaining: decoded.data.remaining_credits,
            mcpUsagePercent: utilization
        )

        return ProviderResult(
            usage: .payAsYouGo(utilization: utilization, cost: nil, resetsAt: nil),
            details: details
        )
    }
}
