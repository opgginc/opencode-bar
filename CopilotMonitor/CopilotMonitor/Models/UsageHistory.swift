import Foundation

struct DailyUsage: Codable {
    let date: Date              // UTC 날짜
    let includedRequests: Double // 포함된 요청 수
    let billedRequests: Double   // 추가 과금 요청 수
    let grossAmount: Double      // 총 금액
    let billedAmount: Double     // 추가 과금 금액
    
    // ⚠️ UTC 캘린더 고정: 날짜 저장이 UTC이므로 요일 판별도 UTC로 통일
    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
    
    var dayOfWeek: Int { Self.utcCalendar.component(.weekday, from: date) }
    var isWeekend: Bool { dayOfWeek == 1 || dayOfWeek == 7 }
}

struct UsageHistory: Codable {
    let fetchedAt: Date
    let days: [DailyUsage]       // ⚠️ 월 전체 데이터 저장 (UI 표시 7일과 별개)
    
    var totalIncludedRequests: Double { days.reduce(0) { $0 + $1.includedRequests } }
    var totalBilledAmount: Double { days.reduce(0) { $0 + $1.billedAmount } }
    
    // UI용 최근 7일 슬라이스
    var recentDays: [DailyUsage] { Array(days.prefix(7)) }
}
