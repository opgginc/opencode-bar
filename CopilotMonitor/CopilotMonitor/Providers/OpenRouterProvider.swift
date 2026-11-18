import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "OpenRouterProvider")

/// Provider for OpenRouter API usage tracking
/// Uses pay-as-you-go billing model with credit-based utilization
final class OpenRouterProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .openRouter
    let type: ProviderType = .payAsYouGo

    // MARK: - API Response Structures

    /// Response structure for /api/v1/credits endpoint
    private struct CreditsResponse: Codable {
        let data: CreditsData

        struct CreditsData: Codable {
            let total_credits: Double
            let total_usage: Double
        }
    }

    /// Response structure for /api/v1/key endpoint
    /// Contains rate limit and usage information
    private struct KeyResponse: Codable {
        let data: KeyData

        struct KeyData: Codable {
            let limit: Double?
            let limit_remaining: Double?
            let limit_reset: String?
            let usage_daily: Double?
            let usage_weekly: Double?
            let usage_monthly: Double?
        }
    }

    // MARK: - ProviderProtocol

    func fetch() async throws -> ProviderResult {
        guard let apiKey = TokenManager.shared.getOpenRouterAPIKey() else {
            logger.error("Failed to retrieve OpenRouter API key")
            throw ProviderError.authenticationFailed("OpenRouter API key not found")
        }

        let creditsResponse = try await fetchCredits(apiKey: apiKey)
        let keyResponse = try await fetchKeyInfo(apiKey: apiKey)

        // Calculate utilization as percentage of credits used
        let utilization: Double
        if creditsResponse.data.total_credits > 0 {
            utilization = (creditsResponse.data.total_usage / creditsResponse.data.total_credits) * 100.0
        } else {
            utilization = 0.0
            logger.warning("Total credits is zero, setting utilization to 0%")
        }

        // Extract monthly cost from API response
        let monthlyCost = keyResponse.data.usage_monthly ?? 0.0
        let dailyCost = keyResponse.data.usage_daily
        let weeklyCost = keyResponse.data.usage_weekly

        // Calculate remaining credits
        let remainingCredits = creditsResponse.data.total_credits - creditsResponse.data.total_usage

        logger.info("Successfully fetched OpenRouter usage: \(String(format: "%.2f", utilization))% utilized (used: \(creditsResponse.data.total_usage), total: \(creditsResponse.data.total_credits)), monthly cost: $\(String(format: "%.2f", monthlyCost))")

        let details = DetailedUsage(
            dailyUsage: dailyCost,
            weeklyUsage: weeklyCost,
            monthlyUsage: keyResponse.data.usage_monthly,
            totalCredits: creditsResponse.data.total_credits,
            remainingCredits: remainingCredits,
            limit: keyResponse.data.limit,
            limitRemaining: keyResponse.data.limit_remaining,
            resetPeriod: keyResponse.data.limit_reset,
            monthlyCost: monthlyCost,
            creditsRemaining: remainingCredits,
            creditsTotal: creditsResponse.data.total_credits,
            authSource: TokenManager.shared.openCodeAuthSourceLabel
        )

        return ProviderResult(
            usage: .payAsYouGo(utilization: utilization, cost: monthlyCost, resetsAt: nil),
            details: details
        )
    }

    // MARK: - Private API Methods

    /// Fetches credit information from OpenRouter API
    /// - Parameter apiKey: OpenRouter API key
    /// - Returns: CreditsResponse containing total_credits and total_usage
    private func fetchCredits(apiKey: String) async throws -> CreditsResponse {
        let endpoint = "https://openrouter.ai/api/v1/credits"

        guard let url = URL(string: endpoint) else {
            logger.error("Invalid credits endpoint URL")
            throw ProviderError.networkError("Invalid endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type from credits API")
            throw ProviderError.networkError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            logger.error("Credits API request failed with status code: \(httpResponse.statusCode)")
            throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }

        do {
            let creditsResponse = try JSONDecoder().decode(CreditsResponse.self, from: data)
            return creditsResponse
        } catch {
            logger.error("Failed to decode credits response: \(error.localizedDescription)")
            throw ProviderError.decodingError(error.localizedDescription)
        }
    }

    /// Fetches API key information including rate limits (for future use)
    /// - Parameter apiKey: OpenRouter API key
    /// - Returns: KeyResponse containing limit and usage information
    private func fetchKeyInfo(apiKey: String) async throws -> KeyResponse {
        let endpoint = "https://openrouter.ai/api/v1/key"

        guard let url = URL(string: endpoint) else {
            logger.error("Invalid key endpoint URL")
            throw ProviderError.networkError("Invalid endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type from key API")
            throw ProviderError.networkError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            logger.error("Key API request failed with status code: \(httpResponse.statusCode)")
            throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }

        do {
            let keyResponse = try JSONDecoder().decode(KeyResponse.self, from: data)
            return keyResponse
        } catch {
            logger.error("Failed to decode key response: \(error.localizedDescription)")
            throw ProviderError.decodingError(error.localizedDescription)
        }
    }
}
