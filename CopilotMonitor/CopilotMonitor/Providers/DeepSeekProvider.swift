import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "DeepSeekProvider")

/// Provider for DeepSeek pay-as-you-go balance tracking.
///
/// DeepSeek is billed as prepaid credit: the account carries a CNY balance
/// (split into topped-up and granted parts) reported by the official
/// `GET https://api.deepseek.com/user/balance` endpoint. There is no quota
/// window or utilization percentage — the balance is the only metric, so it
/// is surfaced through `DetailedUsage.creditsBalance` (plus
/// `balanceCurrency` / `balanceGranted` / `balanceToppedUp`) while
/// `payAsYouGo.cost` stays nil: cost means money spent, and a remaining
/// balance must never count toward the aggregate spend total.
final class DeepSeekProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .deepSeek
    let type: ProviderType = .payAsYouGo

    private let tokenManager: TokenManager
    private let session: URLSession
    /// Optional injected API key for tests; falls back to the credential store.
    private let apiKeyOverride: String?

    init(tokenManager: TokenManager = .shared, session: URLSession = .shared, apiKey: String? = nil) {
        self.tokenManager = tokenManager
        self.session = session
        self.apiKeyOverride = apiKey
    }

    // MARK: - API Response Structures

    /// Response structure for /user/balance
    struct BalanceResponse: Decodable {
        let isAvailable: Bool?
        let balanceInfos: [BalanceInfo]?

        enum CodingKeys: String, CodingKey {
            case isAvailable = "is_available"
            case balanceInfos = "balance_infos"
        }
    }

    struct BalanceInfo: Decodable {
        let currency: String?
        let totalBalance: String?
        let grantedBalance: String?
        let toppedUpBalance: String?

        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
            case grantedBalance = "granted_balance"
            case toppedUpBalance = "topped_up_balance"
        }
    }

    // MARK: - ProviderProtocol

    func fetch() async throws -> ProviderResult {
        logger.info("DeepSeek balance fetch started")

        guard let apiKey = apiKeyOverride ?? tokenManager.getDeepSeekAPIKey() else {
            logger.error("DeepSeek API key not found")
            throw ProviderError.authenticationFailed("DeepSeek API key not available")
        }

        let balanceResponse = try await fetchBalance(apiKey: apiKey)

        // `is_available=false` means the account currently has no usable
        // balance for API calls; surface it as a warning for diagnostics.
        // balance_infos is still rendered (a frozen/zero balance is informative).
        if balanceResponse.isAvailable == false {
            logger.warning("DeepSeek reports balance is not currently available for API calls")
        }

        guard let balanceInfos = balanceResponse.balanceInfos, !balanceInfos.isEmpty else {
            logger.error("DeepSeek balance response missing balance_infos")
            throw ProviderError.decodingError("Missing balance_infos")
        }

        // Explicit currency policy: prefer CNY (the account currency), fall
        // back to USD; anything else is unsupported. Never pick `.first` —
        // balance_infos order is not guaranteed.
        let info = balanceInfos.first { $0.currency?.uppercased() == "CNY" }
            ?? balanceInfos.first { $0.currency?.uppercased() == "USD" }
        guard let info else {
            let currencies = balanceInfos.compactMap { $0.currency }.joined(separator: ", ")
            logger.error("DeepSeek balance response has no supported currency (CNY/USD), got: \(currencies)")
            throw ProviderError.decodingError("Unsupported balance currency")
        }

        guard let totalBalance = Double(info.totalBalance ?? "") else {
            logger.error("DeepSeek balance response has unparseable total_balance: \(info.totalBalance ?? "nil")")
            throw ProviderError.decodingError("Invalid total_balance")
        }
        // Granted/topped-up are secondary details; tolerate unparseable values.
        let grantedBalance = Double(info.grantedBalance ?? "") ?? 0.0
        let toppedUpBalance = Double(info.toppedUpBalance ?? "") ?? 0.0
        let currency = info.currency ?? "CNY"

        logger.info("DeepSeek balance fetched: \(currency) \(String(format: "%.2f", totalBalance)) (granted: \(String(format: "%.2f", grantedBalance)), topped-up: \(String(format: "%.2f", toppedUpBalance)))")

        let details = DetailedUsage(
            creditsBalance: totalBalance,
            balanceCurrency: currency,
            balanceGranted: grantedBalance,
            balanceToppedUp: toppedUpBalance,
            authSource: tokenManager.lastFoundAuthPath?.path ?? "~/.local/share/opencode/auth.json"
        )

        // `cost` stays nil: it represents money already spent, while DeepSeek
        // reports money remaining. The menu row reads the balance from details
        // and the aggregate spend total never counts this provider.
        return ProviderResult(
            usage: .payAsYouGo(utilization: 0, cost: nil, resetsAt: nil),
            details: details
        )
    }

    // MARK: - Private API Methods

    /// Fetches the account balance from the DeepSeek API
    /// - Parameter apiKey: DeepSeek API key
    /// - Returns: BalanceResponse containing balance_infos
    private func fetchBalance(apiKey: String) async throws -> BalanceResponse {
        let endpoint = "https://api.deepseek.com/user/balance"

        guard let url = URL(string: endpoint) else {
            logger.error("Invalid balance endpoint URL")
            throw ProviderError.networkError("Invalid endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type from balance API")
            throw ProviderError.networkError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            logger.error("Balance API request failed with status code: \(httpResponse.statusCode)")
            throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }

        do {
            return try JSONDecoder().decode(BalanceResponse.self, from: data)
        } catch {
            logger.error("Failed to decode balance response: \(error.localizedDescription)")
            throw ProviderError.decodingError(error.localizedDescription)
        }
    }
}
