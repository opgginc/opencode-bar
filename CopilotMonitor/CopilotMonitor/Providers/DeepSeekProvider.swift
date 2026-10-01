import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "DeepSeekProvider")

/// Provider for DeepSeek pay-as-you-go balance tracking.
///
/// DeepSeek is billed as prepaid credit. Its official balance endpoint may
/// return separate balances in CNY and USD; currencies are never merged into
/// one number, and one broken ledger never hides the others (malformed or
/// unsupported entries are skipped and logged; the fetch fails only when
/// nothing usable remains). There is no quota window or utilization
/// percentage, so balances are surfaced as remaining funds while
/// `payAsYouGo.cost` stays nil: cost means money spent and must not count
/// toward the aggregate spend total.
final class DeepSeekProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .deepSeek
    let type: ProviderType = .payAsYouGo

    /// Currencies DeepSeek may bill in, in display order (CNY first). This
    /// list is the single source of truth for both what parses and how the
    /// stored balances are ordered, so adding a third currency here is the
    /// only edit needed.
    private static let supportedCurrencies = ["CNY", "USD"]

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

        // Preserve every supported currency: balance_infos can contain both
        // CNY and USD, and one currency may be zero while the other is funded.
        // One broken ledger must not hide the rest: unsupported codes and
        // unparseable totals are skipped and logged, and the fetch only
        // fails when nothing usable is left.
        var skippedUnsupported: [String] = []
        var skippedMalformed: [String] = []
        let parsedBalances: [ProviderBalanceInfo] = balanceInfos.compactMap { info in
            guard let currency = info.currency?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() else {
                skippedUnsupported.append("<missing>")
                return nil
            }
            guard Self.supportedCurrencies.contains(currency) else {
                skippedUnsupported.append(currency)
                return nil
            }

            guard let totalBalance = Double(info.totalBalance ?? ""), totalBalance.isFinite else {
                skippedMalformed.append(currency)
                return nil
            }

            let grantedBalance = Double(info.grantedBalance ?? "").flatMap { $0.isFinite ? $0 : nil } ?? 0.0
            let toppedUpBalance = Double(info.toppedUpBalance ?? "").flatMap { $0.isFinite ? $0 : nil } ?? 0.0
            return ProviderBalanceInfo(
                currency: currency,
                totalBalance: totalBalance,
                grantedBalance: grantedBalance,
                toppedUpBalance: toppedUpBalance
            )
        }

        if !skippedUnsupported.isEmpty {
            logger.warning("DeepSeek: skipped ledgers with unsupported currency: \(skippedUnsupported.joined(separator: ", "), privacy: .public)")
        }
        if !skippedMalformed.isEmpty {
            logger.error("DeepSeek: skipped ledgers with unparseable total_balance: \(skippedMalformed.joined(separator: ", "), privacy: .public)")
        }

        // supportedCurrencies is both the whitelist and the display order,
        // so the stored list is built by walking it instead of sorting.
        let orderedBalances = Self.supportedCurrencies.compactMap { code in
            parsedBalances.first { $0.currency == code }
        }
        guard let primaryBalance = orderedBalances.first(where: \.isFunded)
                ?? orderedBalances.first else {
            let supported = Self.supportedCurrencies.joined(separator: "/")
            let currencies = balanceInfos.compactMap { $0.currency }.joined(separator: ", ")
            if !skippedMalformed.isEmpty {
                logger.error("DeepSeek balance response has no usable ledger (malformed: \(skippedMalformed.joined(separator: ", "), privacy: .public), seen: \(currencies, privacy: .public))")
                throw ProviderError.decodingError("Invalid total_balance")
            }
            logger.error("DeepSeek balance response has no supported currency (\(supported, privacy: .public)), got: \(currencies, privacy: .public)")
            throw ProviderError.decodingError("Unsupported balance currency")
        }
        let balanceSummary = orderedBalances
            .map { "\($0.currency) \(String(format: "%.2f", $0.totalBalance))" }
            .joined(separator: ", ")
        logger.info("DeepSeek balances fetched: \(balanceSummary, privacy: .private)")

        let details = DetailedUsage(
            creditsBalance: primaryBalance.totalBalance,
            balanceCurrency: primaryBalance.currency,
            balanceGranted: primaryBalance.grantedBalance,
            balanceToppedUp: primaryBalance.toppedUpBalance,
            authSource: tokenManager.lastFoundAuthPath?.path ?? "~/.local/share/opencode/auth.json"
        )

        // `cost` stays nil: it represents money already spent, while DeepSeek
        // reports money remaining. The menu row reads the balance from details
        // and the aggregate spend total never counts this provider.
        return ProviderResult(
            usage: .payAsYouGo(utilization: 0, cost: nil, resetsAt: nil),
            details: details,
            balanceInfos: orderedBalances
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
