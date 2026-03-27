import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "MiniMaxProvider")

private struct MiniMaxCodingPlanResponse: Decodable {
    struct BaseResponse: Decodable {
        let statusCode: Int?
        let statusMessage: String?

        private enum CodingKeys: String, CodingKey {
            case statusCode = "status_code"
            case statusMessage = "status_msg"
        }
    }

    struct ModelRemain: Decodable {
        let startTime: Int64?
        let endTime: Int64?
        let remainsTime: Int64?
        let currentIntervalTotalCount: Int?
        let currentIntervalUsageCount: Int?
        let modelName: String?
        let currentWeeklyTotalCount: Int?
        let currentWeeklyUsageCount: Int?
        let weeklyStartTime: Int64?
        let weeklyEndTime: Int64?
        let weeklyRemainsTime: Int64?

        private enum CodingKeys: String, CodingKey {
            case startTime = "start_time"
            case endTime = "end_time"
            case remainsTime = "remains_time"
            case currentIntervalTotalCount = "current_interval_total_count"
            case currentIntervalUsageCount = "current_interval_usage_count"
            case modelName = "model_name"
            case currentWeeklyTotalCount = "current_weekly_total_count"
            case currentWeeklyUsageCount = "current_weekly_usage_count"
            case weeklyStartTime = "weekly_start_time"
            case weeklyEndTime = "weekly_end_time"
            case weeklyRemainsTime = "weekly_remains_time"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            startTime = Self.decodeInt64(container, forKey: .startTime)
            endTime = Self.decodeInt64(container, forKey: .endTime)
            remainsTime = Self.decodeInt64(container, forKey: .remainsTime)
            currentIntervalTotalCount = Self.decodeInt(container, forKey: .currentIntervalTotalCount)
            currentIntervalUsageCount = Self.decodeInt(container, forKey: .currentIntervalUsageCount)
            modelName = (try? container.decodeIfPresent(String.self, forKey: .modelName))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            currentWeeklyTotalCount = Self.decodeInt(container, forKey: .currentWeeklyTotalCount)
            currentWeeklyUsageCount = Self.decodeInt(container, forKey: .currentWeeklyUsageCount)
            weeklyStartTime = Self.decodeInt64(container, forKey: .weeklyStartTime)
            weeklyEndTime = Self.decodeInt64(container, forKey: .weeklyEndTime)
            weeklyRemainsTime = Self.decodeInt64(container, forKey: .weeklyRemainsTime)
        }

        var fiveHourUsagePercent: Double? {
            guard let total = currentIntervalTotalCount,
                  let remaining = currentIntervalUsageCount,
                  total > 0 else {
                return nil
            }
            let clampedRemaining = min(max(remaining, 0), total)
            let used = total - clampedRemaining
            return (Double(used) / Double(total)) * 100.0
        }

        var weeklyUsagePercent: Double? {
            guard let total = currentWeeklyTotalCount,
                  let remaining = currentWeeklyUsageCount,
                  total > 0 else {
                return nil
            }
            let clampedRemaining = min(max(remaining, 0), total)
            let used = total - clampedRemaining
            return (Double(used) / Double(total)) * 100.0
        }

        var hasQuotaData: Bool {
            (currentIntervalTotalCount ?? 0) > 0 || (currentWeeklyTotalCount ?? 0) > 0
        }

        var quotaScore: Int {
            max(currentIntervalTotalCount ?? 0, currentWeeklyTotalCount ?? 0)
        }

        private static func decodeInt(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int? {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return Int(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return Int(value)
            }
            return nil
        }

        private static func decodeInt64(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int64? {
            if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return Int64(value)
            }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return Int64(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return Int64(value)
            }
            return nil
        }
    }

    let modelRemains: [ModelRemain]
    let baseResponse: BaseResponse?

    private enum CodingKeys: String, CodingKey {
        case modelRemains = "model_remains"
        case baseResponse = "base_resp"
    }
}

final class MiniMaxProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .minimaxCodingPlan
    let type: ProviderType = .quotaBased

    private let tokenManager: TokenManager
    private let session: URLSession
    private let endpoints = [
        "https://api.minimax.io/v1/api/openplatform/coding_plan/remains",
        "https://www.minimax.io/v1/api/openplatform/coding_plan/remains"
    ]

    init(tokenManager: TokenManager = .shared, session: URLSession = .shared) {
        self.tokenManager = tokenManager
        self.session = session
    }

    func fetch() async throws -> ProviderResult {
        logger.info("MiniMax Coding Plan fetch started")

        guard let apiKey = tokenManager.getMiniMaxCodingPlanAPIKey() else {
            logger.error("MiniMax Coding Plan API key not found")
            throw ProviderError.authenticationFailed("MiniMax Coding Plan API key not available")
        }

        let response = try await fetchRemains(apiKey: apiKey)
        if let statusCode = response.baseResponse?.statusCode, statusCode != 0 {
            let message = response.baseResponse?.statusMessage ?? "MiniMax Coding Plan returned status \(statusCode)"
            logger.error("MiniMax Coding Plan API status error: \(message, privacy: .public)")
            throw ProviderError.providerError(message)
        }

        guard let primaryRow = primaryQuotaRow(from: response.modelRemains) else {
            logger.error("MiniMax Coding Plan response missing quota rows")
            throw ProviderError.decodingError("Missing MiniMax Coding Plan quota data")
        }

        let fiveHourUsage = primaryRow.fiveHourUsagePercent
        let weeklyUsage = primaryRow.weeklyUsagePercent

        guard fiveHourUsage != nil || weeklyUsage != nil else {
            logger.error("MiniMax Coding Plan quota row missing usable percentage values")
            throw ProviderError.decodingError("MiniMax Coding Plan quota values are missing")
        }

        let overallUsed = max(fiveHourUsage ?? 0, weeklyUsage ?? 0)
        let remainingPercent = Int((100.0 - overallUsed).rounded())

        let usage = ProviderUsage.quotaBased(
            remaining: remainingPercent,
            entitlement: 100,
            overagePermitted: false
        )

        let details = DetailedUsage(
            fiveHourUsage: fiveHourUsage,
            fiveHourReset: dateFromMilliseconds(primaryRow.endTime),
            sevenDayUsage: weeklyUsage,
            sevenDayReset: dateFromMilliseconds(primaryRow.weeklyEndTime),
            authSource: "~/.local/share/opencode/auth.json"
        )

        logger.info(
            "MiniMax Coding Plan usage fetched: model=\(primaryRow.modelName ?? "unknown", privacy: .public), 5h=\(fiveHourUsage?.description ?? "n/a", privacy: .public)%, weekly=\(weeklyUsage?.description ?? "n/a", privacy: .public)%"
        )

        return ProviderResult(usage: usage, details: details)
    }

    private func fetchRemains(apiKey: String) async throws -> MiniMaxCodingPlanResponse {
        var lastNetworkError: ProviderError?

        for (index, endpoint) in endpoints.enumerated() {
            guard let url = URL(string: endpoint) else { continue }

            do {
                logger.debug("MiniMax Coding Plan request started: \(endpoint, privacy: .public)")
                let data = try await fetchData(url: url, apiKey: apiKey)
                let decoded = try JSONDecoder().decode(MiniMaxCodingPlanResponse.self, from: data)
                return decoded
            } catch let error as ProviderError {
                switch error {
                case .authenticationFailed:
                    throw error
                case .networkError:
                    lastNetworkError = error
                    logger.warning("MiniMax Coding Plan request failed at endpoint #\(index + 1): \(error.localizedDescription, privacy: .public)")
                    continue
                case .decodingError, .providerError, .unsupported:
                    throw error
                }
            } catch let error as DecodingError {
                logger.error("MiniMax Coding Plan decode failed: \(error.localizedDescription, privacy: .public)")
                throw ProviderError.decodingError("Invalid MiniMax Coding Plan response")
            } catch {
                logger.error("MiniMax Coding Plan request failed: \(error.localizedDescription, privacy: .public)")
                throw ProviderError.networkError(error.localizedDescription)
            }
        }

        throw lastNetworkError ?? ProviderError.networkError("MiniMax Coding Plan request failed")
    }

    private func fetchData(url: URL, apiKey: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response type")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw ProviderError.authenticationFailed("MiniMax Coding Plan access token invalid or missing")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }

        return data
    }

    private func primaryQuotaRow(from rows: [MiniMaxCodingPlanResponse.ModelRemain]) -> MiniMaxCodingPlanResponse.ModelRemain? {
        let quotaRows = rows.filter(\.hasQuotaData)
        guard !quotaRows.isEmpty else { return nil }

        return quotaRows.max { lhs, rhs in
            if lhs.quotaScore != rhs.quotaScore {
                return lhs.quotaScore < rhs.quotaScore
            }

            let lhsPercent = max(lhs.fiveHourUsagePercent ?? 0, lhs.weeklyUsagePercent ?? 0)
            let rhsPercent = max(rhs.fiveHourUsagePercent ?? 0, rhs.weeklyUsagePercent ?? 0)
            return lhsPercent < rhsPercent
        }
    }

    private func dateFromMilliseconds(_ milliseconds: Int64?) -> Date? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000.0)
    }
}
