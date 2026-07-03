import Foundation
import os.log

struct MiniMaxCodingPlanResponse: Decodable {
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
        let currentIntervalRemainingPercent: Int?
        let modelName: String?
        let currentWeeklyTotalCount: Int?
        let currentWeeklyUsageCount: Int?
        let currentWeeklyRemainingPercent: Int?
        let weeklyStartTime: Int64?
        let weeklyEndTime: Int64?
        let weeklyRemainsTime: Int64?

        private enum CodingKeys: String, CodingKey {
            case startTime = "start_time"
            case endTime = "end_time"
            case remainsTime = "remains_time"
            case currentIntervalTotalCount = "current_interval_total_count"
            case currentIntervalUsageCount = "current_interval_usage_count"
            case currentIntervalRemainingPercent = "current_interval_remaining_percent"
            case modelName = "model_name"
            case currentWeeklyTotalCount = "current_weekly_total_count"
            case currentWeeklyUsageCount = "current_weekly_usage_count"
            case currentWeeklyRemainingPercent = "current_weekly_remaining_percent"
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
            currentIntervalRemainingPercent = Self.decodeInt(container, forKey: .currentIntervalRemainingPercent)
            modelName = (try? container.decodeIfPresent(String.self, forKey: .modelName))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            currentWeeklyTotalCount = Self.decodeInt(container, forKey: .currentWeeklyTotalCount)
            currentWeeklyUsageCount = Self.decodeInt(container, forKey: .currentWeeklyUsageCount)
            currentWeeklyRemainingPercent = Self.decodeInt(container, forKey: .currentWeeklyRemainingPercent)
            weeklyStartTime = Self.decodeInt64(container, forKey: .weeklyStartTime)
            weeklyEndTime = Self.decodeInt64(container, forKey: .weeklyEndTime)
            weeklyRemainsTime = Self.decodeInt64(container, forKey: .weeklyRemainsTime)
        }

        var fiveHourUsagePercent: Double? {
            if let remainingPercent = currentIntervalRemainingPercent {
                let used = max(0, min(100, 100 - remainingPercent))
                return Double(used)
            }
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
            if let remainingPercent = currentWeeklyRemainingPercent {
                let used = max(0, min(100, 100 - remainingPercent))
                return Double(used)
            }
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
            (currentIntervalTotalCount ?? 0) > 0
                || (currentWeeklyTotalCount ?? 0) > 0
                || currentIntervalRemainingPercent != nil
                || currentWeeklyRemainingPercent != nil
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelRemains = (try? container.decode([ModelRemain].self, forKey: .modelRemains)) ?? []
        baseResponse = try? container.decode(BaseResponse.self, forKey: .baseResponse)
    }
}

func fetchMiniMaxCodingPlanUsage(
    apiKey: String,
    baseURL: String,
    identifier: ProviderIdentifier,
    logger: Logger,
    session: URLSession
) async throws -> ProviderResult {
    logger.info("\(identifier.displayName) fetch started")

    guard let url = URL(string: baseURL) else {
        logger.error("\(identifier.displayName) invalid base URL")
        throw ProviderError.networkError("Invalid API endpoint")
    }

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
        throw ProviderError.authenticationFailed("\(identifier.displayName) access token invalid or missing")
    }

    guard (200...299).contains(httpResponse.statusCode) else {
        throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
    }

    let decoded: MiniMaxCodingPlanResponse
    do {
        decoded = try JSONDecoder().decode(MiniMaxCodingPlanResponse.self, from: data)
    } catch let error as DecodingError {
        logger.error("\(identifier.displayName) decode failed: \(error.localizedDescription, privacy: .public)")
        throw ProviderError.decodingError("Invalid \(identifier.displayName) response")
    } catch {
        logger.error("\(identifier.displayName) request failed: \(error.localizedDescription, privacy: .public)")
        throw ProviderError.networkError(error.localizedDescription)
    }

    if let statusCode = decoded.baseResponse?.statusCode, statusCode != 0 {
        let message = decoded.baseResponse?.statusMessage ?? "\(identifier.displayName) returned status \(statusCode)"
        logger.error("\(identifier.displayName) API status error: \(message, privacy: .public)")
        throw ProviderError.providerError(message)
    }

    guard let primaryRow = primaryMiniMaxQuotaRow(from: decoded.modelRemains) else {
        logger.error("\(identifier.displayName) response missing quota rows")
        throw ProviderError.decodingError("Missing \(identifier.displayName) quota data")
    }

    let fiveHourUsage = primaryRow.fiveHourUsagePercent
    let weeklyUsage = primaryRow.weeklyUsagePercent

    guard fiveHourUsage != nil || weeklyUsage != nil else {
        logger.error("\(identifier.displayName) quota row missing usable percentage values")
        throw ProviderError.decodingError("\(identifier.displayName) quota values are missing")
    }

    let overallUsed = max(fiveHourUsage ?? 0, weeklyUsage ?? 0)
    let aggregateUsedPercent = UsagePercentDisplayFormatter.wholePercent(from: overallUsed)
    let remainingPercent = max(0, 100 - aggregateUsedPercent)

    let usage = ProviderUsage.quotaBased(
        remaining: remainingPercent,
        entitlement: 100,
        overagePermitted: false
    )

    let details = DetailedUsage(
        fiveHourUsage: fiveHourUsage,
        fiveHourReset: resetDateFromMiniMaxFields(
            endTime: primaryRow.endTime,
            remainsTime: primaryRow.remainsTime
        ),
        sevenDayUsage: weeklyUsage,
        sevenDayReset: resetDateFromMiniMaxFields(
            endTime: primaryRow.weeklyEndTime,
            remainsTime: primaryRow.weeklyRemainsTime
        ),
        authSource: "~/.local/share/opencode/auth.json"
    )

    logger.info(
        "\(identifier.displayName) usage fetched: model=\(primaryRow.modelName ?? "unknown", privacy: .public), 5h=\(fiveHourUsage?.description ?? "n/a", privacy: .public)%, weekly=\(weeklyUsage?.description ?? "n/a", privacy: .public)%"
    )

    return ProviderResult(usage: usage, details: details)
}

private func primaryMiniMaxQuotaRow(from rows: [MiniMaxCodingPlanResponse.ModelRemain]) -> MiniMaxCodingPlanResponse.ModelRemain? {
    let quotaRows = rows.filter(\.hasQuotaData)
    guard !quotaRows.isEmpty else { return nil }

    return quotaRows.max { lhs, rhs in
        let lhsPercent = max(lhs.fiveHourUsagePercent ?? 0, lhs.weeklyUsagePercent ?? 0)
        let rhsPercent = max(rhs.fiveHourUsagePercent ?? 0, rhs.weeklyUsagePercent ?? 0)
        if lhsPercent != rhsPercent {
            return lhsPercent < rhsPercent
        }

        if lhs.quotaScore != rhs.quotaScore {
            return lhs.quotaScore < rhs.quotaScore
        }

        let lhsName = lhs.modelName ?? ""
        let rhsName = rhs.modelName ?? ""
        return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
    }
}

private func dateFromMiniMaxMilliseconds(_ milliseconds: Int64?) -> Date? {
    guard let milliseconds, milliseconds > 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000.0)
}

/// Computes the reset date from MiniMax window fields.
///
/// The API returns both an absolute window end timestamp (`end_time`) and a
/// relative remaining duration (`remains_time`). Prefer `remains_time` because
/// it reflects the server-side "time until reset" at response generation time,
/// which matches what users see in the MiniMax dashboard and avoids small
/// drift from client/server clock skew. Fall back to the absolute `end_time`
/// when the relative value is missing or invalid.
func resetDateFromMiniMaxFields(
    endTime: Int64?,
    remainsTime: Int64?,
    referenceDate: Date = Date()
) -> Date? {
    if let remainsTime = remainsTime, remainsTime > 0 {
        return referenceDate.addingTimeInterval(TimeInterval(remainsTime) / 1000.0)
    }
    return dateFromMiniMaxMilliseconds(endTime)
}
