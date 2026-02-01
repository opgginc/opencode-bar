import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "CopilotHistoryService")

/// Service for fetching Copilot daily usage history from GitHub API using browser cookies.
/// Extracts customer_id from billing page, then fetches paginated usage table data.
class CopilotHistoryService {
    static let shared = CopilotHistoryService()

    private var cachedCustomerId: String?

    private init() {}

    // MARK: - Main Entry Point

    /// Fetches daily usage history from GitHub Copilot billing API.
    /// - Returns: Array of DailyUsage sorted by date (most recent first)
    /// - Throws: CopilotHistoryError on failure
    func fetchHistory() async throws -> [DailyUsage] {
        logger.info("Starting Copilot history fetch")

        // 1. Get cookies from browser
        let cookies: GitHubCookies
        do {
            cookies = try BrowserCookieService.shared.getGitHubCookies()
        } catch {
            logger.error("Failed to get GitHub cookies: \(error.localizedDescription)")
            throw CopilotHistoryError.invalidCookies
        }

        guard cookies.isValid else {
            logger.error("GitHub cookies are not valid (missing user_session or logged_in)")
            throw CopilotHistoryError.invalidCookies
        }

        // 2. Get customer_id from billing page
        let customerId = try await fetchCustomerId(cookies: cookies)
        logger.info("Got customer ID: \(customerId)")

        // 3. Fetch usage table (paginated)
        let history = try await fetchUsageTable(customerId: customerId, cookies: cookies)
        logger.info("Fetched \(history.count) days of history")

        return history
    }

    // MARK: - Customer ID Extraction

    /// Fetches customer_id from GitHub billing page HTML.
    /// Uses cached value if available.
    private func fetchCustomerId(cookies: GitHubCookies) async throws -> String {
        if let cached = cachedCustomerId {
            return cached
        }

        guard let url = URL(string: "https://github.com/settings/billing") else {
            throw CopilotHistoryError.apiRequestFailed
        }

        var request = URLRequest(url: url)
        request.setValue(cookies.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                logger.error("Session expired or invalid (HTTP \(httpResponse.statusCode))")
                throw CopilotHistoryError.sessionExpired
            }
        }

        guard let html = String(data: data, encoding: .utf8) else {
            logger.error("Failed to decode billing page HTML")
            throw CopilotHistoryError.invalidResponse
        }

        // Try multiple regex patterns for robustness (different HTML encodings)
        let patterns = [
            #""customerId":\s*(\d+)"#,      // JSON in script
            #""customerId&quot;:(\d+)"#,    // HTML-encoded JSON
            #"customer_id=(\d+)"#,          // URL parameter
            #"customerId":(\d+)"#           // Without quotes
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let customerId = String(html[range])
                cachedCustomerId = customerId
                return customerId
            }
        }

        logger.error("Could not find customer ID in billing page")
        throw CopilotHistoryError.customerIdNotFound
    }

    // MARK: - Usage Table Fetching

    /// Fetches paginated usage table data from GitHub API.
    /// Combines data from both period=3 (current month) and period=5 (previous month) to ensure
    /// complete history across month boundaries.
    /// - Parameters:
    ///   - customerId: GitHub customer ID
    ///   - cookies: Valid GitHub cookies
    /// - Returns: Array of DailyUsage sorted by date (most recent first)
    private func fetchUsageTable(customerId: String, cookies: GitHubCookies) async throws -> [DailyUsage] {
        // Fetch both periods in parallel to get complete history across month boundaries
        // period=3: current billing period (resets on month change)
        // period=5: previous month's billing period
        async let period3Data = fetchUsageTableForPeriod(customerId: customerId, cookies: cookies, period: 3)
        async let period5Data = fetchUsageTableForPeriod(customerId: customerId, cookies: cookies, period: 5)

        let (history3, history5) = try await (period3Data, period5Data)

        logger.debug("Fetched \(history3.count) rows from period=3, \(history5.count) rows from period=5")

        // Merge results: use date as key, prefer data with higher request counts
        var mergedByDate: [Date: DailyUsage] = [:]

        // First add all period=5 data (all-time history)
        for usage in history5 {
            mergedByDate[usage.date] = usage
        }

        // Then overlay period=3 data (current month - may have more recent/accurate data)
        for usage in history3 {
            if let existing = mergedByDate[usage.date] {
                // Keep the entry with higher total requests (more complete data)
                let existingTotal = existing.includedRequests + existing.billedRequests
                let newTotal = usage.includedRequests + usage.billedRequests
                if newTotal > existingTotal {
                    mergedByDate[usage.date] = usage
                }
            } else {
                mergedByDate[usage.date] = usage
            }
        }

        let allHistory = Array(mergedByDate.values)
        logger.info("Merged to \(allHistory.count) unique days of history")

        // Sort by date, most recent first
        return allHistory.sorted { $0.date > $1.date }
    }

    /// Fetches paginated usage table data for a specific billing period.
    /// - Parameters:
    ///   - customerId: GitHub customer ID
    ///   - cookies: Valid GitHub cookies
    ///   - period: Billing period (3=current month, 5=previous month)
    /// - Returns: Array of DailyUsage for the specified period
    private func fetchUsageTableForPeriod(customerId: String, cookies: GitHubCookies, period: Int) async throws -> [DailyUsage] {
        var allHistory: [DailyUsage] = []
        var page = 1
        let maxPages = 3  // ~30 days of history (10 rows per page)

        while page <= maxPages {
            let urlString = "https://github.com/settings/billing/copilot_usage_table?customer_id=\(customerId)&group=0&period=\(period)&query=&page=\(page)"

            guard let url = URL(string: urlString) else {
                logger.warning("Failed to construct URL for period=\(period), page=\(page)")
                break
            }

            var request = URLRequest(url: url)
            request.setValue(cookies.cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    logger.error("Session expired during table fetch (HTTP \(httpResponse.statusCode))")
                    throw CopilotHistoryError.sessionExpired
                }

                if httpResponse.statusCode != 200 {
                    logger.warning("Unexpected status code for period=\(period): \(httpResponse.statusCode)")
                    break
                }
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let table = json["table"] as? [String: Any],
                  let rows = table["rows"] as? [[String: Any]] else {
                logger.debug("No more data at period=\(period), page=\(page) or invalid JSON structure")
                break
            }

            if rows.isEmpty {
                logger.debug("Empty rows at period=\(period), page=\(page), stopping pagination")
                break
            }

            let pageHistory = parseRows(rows)
            allHistory.append(contentsOf: pageHistory)

            logger.debug("Period=\(period), page=\(page): parsed \(pageHistory.count) rows")
            page += 1
        }

        return allHistory
    }

    // MARK: - Row Parsing

    /// Parses table rows into DailyUsage array.
    /// Each row has 5 cells: date, included_requests, billed_requests, gross_amount, billed_amount
    private func parseRows(_ rows: [[String: Any]]) -> [DailyUsage] {
        var history: [DailyUsage] = []

        for row in rows {
            guard let cells = row["cells"] as? [[String: Any]],
                  cells.count >= 5 else {
                logger.debug("Skipping row: insufficient cells")
                continue
            }

            // Cell 0: Date (e.g., "Jan 29" or "Jan 29, 2026")
            guard let dateString = cells[0]["value"] as? String else {
                logger.debug("Skipping row: no date value")
                continue
            }
            let date = parseDate(dateString)

            // Cell 1: Included requests
            let includedRequests = parseNumber(cells[1]["value"])

            // Cell 2: Billed requests (add-on)
            let billedRequests = parseNumber(cells[2]["value"])

            // Cell 3: Gross amount
            let grossAmount = parseCurrency(cells[3]["value"])

            // Cell 4: Billed amount (actual charge)
            let billedAmount = parseCurrency(cells[4]["value"])

            let dailyUsage = DailyUsage(
                date: date,
                includedRequests: includedRequests,
                billedRequests: billedRequests,
                grossAmount: grossAmount,
                billedAmount: billedAmount
            )

            history.append(dailyUsage)
        }

        return history
    }

    // MARK: - Parsing Helpers

    /// Parses date string from GitHub format.
    /// GitHub returns "Jan 29" or "Jan 29, 2026" format.
    private func parseDate(_ dateString: String) -> Date {
        let trimmed = dateString.trimmingCharacters(in: .whitespaces)

        // Try full format first (with year): "Jan 29, 2026"
        let fullFormatter = DateFormatter()
        fullFormatter.dateFormat = "MMM d, yyyy"
        fullFormatter.locale = Locale(identifier: "en_US_POSIX")
        fullFormatter.timeZone = TimeZone(identifier: "UTC")

        if let date = fullFormatter.date(from: trimmed) {
            return date
        }

        // Short format without year: "Jan 29"
        let shortFormatter = DateFormatter()
        shortFormatter.dateFormat = "MMM d"
        shortFormatter.locale = Locale(identifier: "en_US_POSIX")
        shortFormatter.timeZone = TimeZone(identifier: "UTC")

        if let date = shortFormatter.date(from: trimmed) {
            // Add current year
            var components = Calendar.current.dateComponents([.month, .day], from: date)
            components.year = Calendar.current.component(.year, from: Date())
            components.timeZone = TimeZone(identifier: "UTC")

            if let fullDate = Calendar.current.date(from: components) {
                return fullDate
            }
        }

        logger.warning("Failed to parse date: '\(dateString)', using current date")
        return Date()
    }

    /// Parses numeric value from API response.
    /// Handles both String and NSNumber types.
    private func parseNumber(_ value: Any?) -> Double {
        if let string = value as? String {
            let cleaned = string.replacingOccurrences(of: ",", with: "")
            return Double(cleaned) ?? 0.0
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let intValue = value as? Int {
            return Double(intValue)
        }
        if let doubleValue = value as? Double {
            return doubleValue
        }
        return 0.0
    }

    /// Parses currency value from API response.
    /// Handles "$1,234.56" format.
    private func parseCurrency(_ value: Any?) -> Double {
        if let string = value as? String {
            let cleaned = string
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Double(cleaned) ?? 0.0
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let doubleValue = value as? Double {
            return doubleValue
        }
        return 0.0
    }

    // MARK: - Cache Management

    /// Clears cached customer ID (call when user logs out)
    func clearCache() {
        cachedCustomerId = nil
        logger.info("Cleared customer ID cache")
    }
}

// MARK: - Error Types

enum CopilotHistoryError: LocalizedError {
    case invalidCookies
    case customerIdNotFound
    case apiRequestFailed
    case invalidResponse
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .invalidCookies:
            return "GitHub cookies are missing or invalid. Please log in to GitHub in your browser."
        case .customerIdNotFound:
            return "Could not find customer ID. Please ensure you're logged in to GitHub."
        case .apiRequestFailed:
            return "Failed to connect to GitHub API."
        case .invalidResponse:
            return "Received invalid response from GitHub API."
        case .sessionExpired:
            return "GitHub session expired. Please refresh your browser login."
        }
    }
}
