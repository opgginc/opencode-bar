import Foundation

struct DailyUsage: Codable {
    let date: Date              // UTC date
    let includedRequests: Double // Included requests
    let billedRequests: Double   // Add-on billed requests
    let grossAmount: Double      // Gross amount
    let billedAmount: Double     // Add-on billed amount
    
    // UTC calendar for date calculations - safely initialized with fallback
    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        if let utc = TimeZone(identifier: "UTC") {
            cal.timeZone = utc
        } else {
            // Fallback to system timezone if UTC is unavailable (should never happen)
            cal.timeZone = TimeZone.current
        }
        return cal
    }()
    
    var dayOfWeek: Int { Self.utcCalendar.component(.weekday, from: date) }
    var isWeekend: Bool { dayOfWeek == 1 || dayOfWeek == 7 }
    
    /// Total requests (included + billed) for prediction calculations
    var totalRequests: Double { includedRequests + billedRequests }
}

struct UsageHistory: Codable {
    let fetchedAt: Date
    let days: [DailyUsage]       // ⚠️ Stores full month data (separate from 7-day UI display)
    
    var totalRequests: Double { days.reduce(0) { $0 + $1.totalRequests } }
    var totalBilledAmount: Double { days.reduce(0) { $0 + $1.billedAmount } }
    
    // Recent 7 days slice for UI
    var recentDays: [DailyUsage] { Array(days.prefix(7)) }
}
