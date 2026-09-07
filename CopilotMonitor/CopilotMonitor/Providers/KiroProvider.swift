import Foundation
import SQLite3
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "KiroProvider")

final class KiroProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .kiro
    let type: ProviderType = .quotaBased
    let fetchTimeout: TimeInterval = 25
    let minimumFetchInterval: TimeInterval = 300

    private let databaseURL: URL
    private let session: URLSession

    init(databaseURL: URL? = nil, session: URLSession = .shared) {
        self.databaseURL = databaseURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kiro-cli/data.sqlite3")
        self.session = session
    }

    func fetch() async throws -> ProviderResult {
        let credentials = try readCredentials()
        guard let expiry = APIValueParser.parseDate(from: credentials.expiresAt), expiry > Date(),
              !credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.notice("Kiro usage skipped: stored credentials are expired or incomplete")
            throw ProviderError.authenticationFailed("Kiro credentials have expired. Sign in using Kiro to update them.")
        }

        // The profile selects the regional service; validate it before constructing a credential-bearing URL.
        let region = credentials.region ?? credentials.profileArn?.split(separator: ":").dropFirst(3).first.map(String.init) ?? "us-east-1"
        guard region.range(of: #"^[a-z]{2}(?:-[a-z]+)+-[0-9]+$"#, options: .regularExpression) != nil,
              var components = URLComponents(string: "https://management.\(region).kiro.dev/Get-Usage-Limits") else {
            throw ProviderError.authenticationFailed("Kiro credentials contain an invalid region.")
        }
        components.queryItems = [URLQueryItem(name: "origin", value: "CLI")]
        if let arn = credentials.profileArn, !arn.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "profileArn", value: arn))
        }
        guard let url = components.url else {
            throw ProviderError.authenticationFailed("Kiro credentials contain an invalid profile.")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: fetchTimeout)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        if credentials.isIdentityCenter {
            request.setValue("SSO_OIDC", forHTTPHeaderField: "TokenType")
        }

        logger.info("Kiro usage request started with stored credentials")
        let (data, response) = try await session.data(for: request, delegate: KiroUsageRedirectPolicy())
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Kiro returned an invalid response.")
        }
        logger.info("Kiro usage request completed: HTTP \(http.statusCode)")
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderError.authenticationFailed("Kiro rejected the stored credentials. Sign in using Kiro to update them.")
        }
        guard http.statusCode == 200 else {
            throw ProviderError.networkError("Kiro usage request failed (HTTP \(http.statusCode)).")
        }
        return try Self.parseUsageResponse(data, authSource: databaseURL.path)
    }

    private struct Credentials: Decodable {
        let accessToken: String
        let expiresAt: String
        let profileArn: String?
        let region: String?
        var isIdentityCenter = false

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresAt = "expires_at"
            case profileArn = "profile_arn"
            case region
        }
    }

    private func readCredentials() throws -> Credentials {
        var database: OpaquePointer?
        // Kiro owns the credential store. Read-only mode also prevents creating an empty database.
        let status = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        guard status == SQLITE_OK else {
            throw ProviderError.authenticationFailed("Kiro credentials are unavailable. Sign in using Kiro first.")
        }
        sqlite3_busy_timeout(database, 1_000)
        var statement: OpaquePointer?
        let query = """
        SELECT key, value FROM auth_kv
        WHERE key IN ('kirocli:social:token', 'kirocli:odic:token')
        """
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            throw ProviderError.authenticationFailed("Kiro credential database could not be read.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let key = sqlite3_column_text(statement, 0),
              let value = sqlite3_column_text(statement, 1) else {
            throw ProviderError.authenticationFailed("Kiro credentials are missing. Sign in using Kiro first.")
        }
        do {
            var credentials = try JSONDecoder().decode(Credentials.self, from: Data(String(cString: value).utf8))
            credentials.isIdentityCenter = String(cString: key) == "kirocli:odic:token"
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ProviderError.authenticationFailed("Kiro credential selection is ambiguous or unreadable.")
            }
            return credentials
        } catch {
            throw ProviderError.authenticationFailed("Kiro credentials are incomplete or invalid.")
        }
    }

    static func parseUsageResponse(_ data: Data, authSource: String, now: Date = Date()) throws -> ProviderResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let response: UsageResponse
        do {
            response = try decoder.decode(UsageResponse.self, from: data)
        } catch {
            throw ProviderError.decodingError("Kiro usage response could not be decoded.")
        }
        guard let credits = response.usageBreakdownList.first(where: { $0.resourceType == "CREDIT" }),
              let used = credits.currentUsageWithPrecision ?? credits.currentUsage,
              let total = credits.usageLimitWithPrecision ?? credits.usageLimit,
              used.isFinite, used >= 0, total.isFinite, total > 0,
              used < Double(Int.max) / 100, total < Double(Int.max) / 100 else {
            throw ProviderError.decodingError("Kiro usage response did not include valid credit usage.")
        }

        var bonuses = (credits.bonuses ?? []).filter {
            ($0.status == "ACTIVE" || $0.status == "EXHAUSTED") && ($0.expiresAt.map { $0 > now } ?? true)
        }
        if let trial = credits.freeTrialInfo, trial.freeTrialStatus == "ACTIVE",
           let expiry = trial.freeTrialExpiry, expiry > now,
           let trialUsed = trial.currentUsageWithPrecision ?? trial.currentUsage,
           let trialTotal = trial.usageLimitWithPrecision ?? trial.usageLimit {
            bonuses.append(Bonus(status: "ACTIVE", currentUsage: trialUsed, usageLimit: trialTotal, expiresAt: expiry))
        }
        let bonusUsed = bonuses.reduce(0) { $0 + $1.currentUsage }
        let bonusTotal = bonuses.reduce(0) { $0 + $1.usageLimit }
        let bonusPercent = bonusTotal > 0 ? bonusUsed / bonusTotal * 100 : 0
        guard bonuses.allSatisfy({
            $0.currentUsage.isFinite && $0.currentUsage >= 0 && $0.usageLimit.isFinite && $0.usageLimit > 0
        }), bonusUsed.isFinite, bonusTotal.isFinite,
              bonusPercent.isFinite, bonusPercent < Double(Int.max) else {
            throw ProviderError.decodingError("Kiro usage response contained invalid bonus credit usage.")
        }
        let plan = response.subscriptionInfo?.subscriptionTitle
            .replacingOccurrences(of: "KIRO ", with: "", options: .caseInsensitive)
            .capitalized
        let details = DetailedUsage(
            secondaryUsage: bonusTotal > 0 ? bonusPercent : nil,
            secondaryReset: bonuses.compactMap(\.expiresAt).min(),
            primaryReset: credits.nextDateReset ?? response.nextDateReset,
            planType: plan,
            monthlyCost: used,
            creditsRemaining: total - used,
            creditsTotal: total,
            authSource: authSource
        )
        // ProviderUsage stores integers, so retain centicredit precision when building the shared model.
        return ProviderResult(
            usage: .quotaBased(
                remaining: Int(((total - used) * 100).rounded()),
                entitlement: max(Int((total * 100).rounded()), 1),
                overagePermitted: response.overageConfiguration?.overageStatus == "ENABLED"
            ),
            details: details
        )
    }

    private struct UsageResponse: Decodable {
        let nextDateReset: Date?
        let usageBreakdownList: [CreditUsage]
        let subscriptionInfo: Subscription?
        let overageConfiguration: Overage?
    }

    private struct CreditUsage: Decodable {
        let resourceType: String
        let currentUsage: Double?
        let currentUsageWithPrecision: Double?
        let usageLimit: Double?
        let usageLimitWithPrecision: Double?
        let nextDateReset: Date?
        let freeTrialInfo: Trial?
        let bonuses: [Bonus]?
    }

    private struct Trial: Decodable {
        let freeTrialStatus: String
        let freeTrialExpiry: Date?
        let currentUsage: Double?
        let currentUsageWithPrecision: Double?
        let usageLimit: Double?
        let usageLimitWithPrecision: Double?
    }

    private struct Bonus: Decodable {
        let status: String
        let currentUsage: Double
        let usageLimit: Double
        let expiresAt: Date?
    }

    private struct Subscription: Decodable {
        let subscriptionTitle: String
    }

    private struct Overage: Decodable {
        let overageStatus: String
    }
}

private final class KiroUsageRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Credentials belong only to the usage endpoint selected above.
        completionHandler(nil)
    }
}
