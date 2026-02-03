import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "SyntheticProvider")

struct SyntheticQuotasResponse: Codable {
    struct Subscription: Codable {
        let limit: Int
        let requests: Double  // API returns decimal values (e.g., 35.6)
        let renewsAt: String?

        enum CodingKeys: String, CodingKey {
            case limit, requests
            case renewsAt = "renewsAt"
        }
    }

    let subscription: Subscription
}

final class SyntheticProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .synthetic
    let type: ProviderType = .quotaBased

    private let tokenManager: TokenManager
    private let session: URLSession

    init(tokenManager: TokenManager = .shared, session: URLSession = .shared) {
        self.tokenManager = tokenManager
        self.session = session
    }

    func fetch() async throws -> ProviderResult {
        guard let apiKey = tokenManager.getSyntheticAPIKey() else {
            logger.error("Synthetic API key not found")
            throw ProviderError.authenticationFailed("Synthetic API key not available")
        }

        guard let url = URL(string: "https://api.synthetic.new/v2/quotas") else {
            logger.error("Invalid Synthetic API URL")
            throw ProviderError.networkError("Invalid API endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response type")
        }

        if httpResponse.statusCode == 401 {
            throw ProviderError.authenticationFailed("Invalid API key")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }

        do {
            let decoder = JSONDecoder()
            let apiResponse = try decoder.decode(SyntheticQuotasResponse.self, from: data)

            let limit = apiResponse.subscription.limit
            let requests = apiResponse.subscription.requests
            let remainingVal = Double(limit) - requests
            let remaining = max(0, Int(remainingVal))  // Handle fractional requests
            let usagePercent = limit > 0 ? (Double(requests) / Double(limit) * 100) : 0

            let renewsAt: Date?
            if let dateStr = apiResponse.subscription.renewsAt {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: dateStr) {
                    renewsAt = date
                } else {
                    let fallbackFormatter = ISO8601DateFormatter()
                    fallbackFormatter.formatOptions = [.withInternetDateTime]
                    renewsAt = fallbackFormatter.date(from: dateStr)
                }
            } else {
                renewsAt = nil
            }

            logger.info("Synthetic usage fetched: \(requests)/\(limit), renews at \(renewsAt?.description ?? "nil")")

            let usage = ProviderUsage.quotaBased(
                remaining: remaining,
                entitlement: limit,
                overagePermitted: false
            )

            let authSource = tokenManager.lastFoundAuthPath?.path ?? "~/.local/share/opencode/auth.json"
            let details = DetailedUsage(
                limit: Double(limit),
                limitRemaining: Double(remaining),
                resetPeriod: nil,
                fiveHourUsage: usagePercent,
                fiveHourReset: renewsAt,
                authSource: authSource
            )

            return ProviderResult(usage: usage, details: details)

        } catch let error as DecodingError {
            logger.error("Failed to decode Synthetic response: \(error.localizedDescription)")
            throw ProviderError.decodingError("Invalid response format")
        } catch {
            throw ProviderError.providerError("Failed to parse response: \(error.localizedDescription)")
        }
    }
}
