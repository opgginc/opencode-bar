//
//  UsagePredictor.swift
//  CopilotMonitor
//
//  Created by opencode on 2026-01-18.
//

import Foundation

/// Monthly usage prediction result
struct UsagePrediction {
    let predictedMonthlyRequests: Double  // Predicted total requests at EOM
    let predictedBilledAmount: Double     // Predicted add-on cost
    let confidenceLevel: ConfidenceLevel  // low/medium/high
    let daysUsedForPrediction: Int        // Days used for prediction
}

/// Prediction confidence level
enum ConfidenceLevel: String {
    case low = "Low prediction accuracy"
    case medium = "Medium prediction accuracy"
    case high = "High prediction accuracy"
}

/// Usage prediction algorithm implementation
/// - Weighted prediction based on configurable days
/// - Considers day-of-week patterns (weekday/weekend differences)
class UsagePredictor {
    // UTC calendar for prediction calculations - safely initialized with fallback
    private let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        if let utc = TimeZone(identifier: "UTC") {
            cal.timeZone = utc
        } else {
            // Fallback to system timezone if UTC is unavailable (should never happen)
            cal.timeZone = TimeZone.current
        }
        return cal
    }()
    
    // Dynamic weights passed from settings
    private let weights: [Double]
    
    // Cost per request (fixed)
    private let costPerRequest: Double = 0.04  // $0.04/request
    
    init(weights: [Double] = [1.5, 1.5, 1.2, 1.2, 1.2, 1.0, 1.0]) {
        self.weights = weights
    }
    
    /// 월말 사용량 및 비용 예측
    /// - Parameters:
    ///   - history: 일별 사용량 히스토리
    ///   - currentUsage: Current usage info (includes limit)
    /// - Returns: Prediction result
    func predict(history: UsageHistory, currentUsage: CopilotUsage) -> UsagePrediction {
        let dailyData = history.days
        
        // Edge case: No data
        guard !dailyData.isEmpty else {
            return UsagePrediction(
                predictedMonthlyRequests: 0,
                predictedBilledAmount: 0,
                confidenceLevel: .low,
                daysUsedForPrediction: 0
            )
        }
        
        // Step 1: Calculate weighted average daily usage
        let weightedAvgDailyUsage = calculateWeightedAverageDailyUsage(dailyData: dailyData)
        
        // Step 2: Weekend/weekday pattern adjustment
        let weekendRatio = calculateWeekendRatio(dailyData: dailyData)
        
        // Step 3: Calculate remaining days
        let today = Date()  // Today in UTC
        let daysInMonth = utcCalendar.range(of: .day, in: .month, for: today)?.count ?? 30
        let currentDay = utcCalendar.component(.day, from: today)
        let remainingDays = daysInMonth - currentDay
        
        let (remainingWeekdays, remainingWeekends) = countRemainingWeekdaysAndWeekends(
            from: today,
            remainingDays: remainingDays
        )
        
        // Step 4: Predict total monthly usage
        let predictedRemainingWeekdayUsage = weightedAvgDailyUsage * Double(remainingWeekdays)
        let predictedRemainingWeekendUsage = weightedAvgDailyUsage * weekendRatio * Double(remainingWeekends)
        
        let currentTotalUsage = history.totalRequests
        let predictedMonthlyTotal = currentTotalUsage + predictedRemainingWeekdayUsage + predictedRemainingWeekendUsage
        
        // Step 5: Calculate predicted add-on cost
        let limit = Double(currentUsage.limitRequests)
        let predictedBilledAmount: Double
        
        if predictedMonthlyTotal > limit {
            let excessRequests = predictedMonthlyTotal - limit
            predictedBilledAmount = excessRequests * costPerRequest
        } else {
            predictedBilledAmount = 0
        }
        
        // Step 6: Confidence Level 결정
        let daysUsed = dailyData.count
        let confidenceLevel: ConfidenceLevel
        
        if daysUsed < 3 {
            confidenceLevel = .low
        } else if daysUsed < 7 {
            confidenceLevel = .medium
        } else {
            confidenceLevel = .high
        }
        
        return UsagePrediction(
            predictedMonthlyRequests: predictedMonthlyTotal,
            predictedBilledAmount: predictedBilledAmount,
            confidenceLevel: confidenceLevel,
            daysUsedForPrediction: daysUsed
        )
    }
    
    // MARK: - Step 1: Weighted Average Calculation
    
    /// Calculate weighted average daily usage
    /// - Parameter dailyData: Array of daily usage (needs to be sorted by recency)
    /// - Returns: Weighted average daily usage
    private func calculateWeightedAverageDailyUsage(dailyData: [DailyUsage]) -> Double {
        // Sort by most recent (date descending)
        let sortedData = dailyData.sorted { $0.date > $1.date }
        
        var weightedSum: Double = 0
        var totalWeight: Double = 0
        
        // Use up to 7 days (weights array size)
        let daysToUse = min(sortedData.count, weights.count)
        
        for i in 0..<daysToUse {
            let usage = sortedData[i].totalRequests  // Use totalRequests (included + billed)
            let weight = weights[i]
            weightedSum += usage * weight
            totalWeight += weight
        }
        
        // Prevent division by zero
        guard totalWeight > 0 else {
            return 0
        }
        
        return weightedSum / totalWeight
    }
    
    // MARK: - Step 2: Weekend/Weekday Pattern Adjustment
    
    /// Calculate weekend vs weekday usage ratio
    /// - Parameter dailyData: Array of daily usage
    /// - Returns: Weekend ratio (weekend avg / weekday avg)
    private func calculateWeekendRatio(dailyData: [DailyUsage]) -> Double {
        var weekdaySum: Double = 0
        var weekendSum: Double = 0
        var weekdayCount: Int = 0
        var weekendCount: Int = 0
        
        for day in dailyData {
            let weekday = utcCalendar.component(.weekday, from: day.date)
            
            // weekday: 1=Sunday, 2=Monday, ..., 7=Saturday
            if weekday == 1 || weekday == 7 {
                // Weekend (Sun, Sat)
                weekendSum += day.totalRequests
                weekendCount += 1
            } else {
                // Weekday (Mon-Fri)
                weekdaySum += day.totalRequests
                weekdayCount += 1
            }
        }
        
        let weekdayAvg = weekdayCount > 0 ? weekdaySum / Double(weekdayCount) : 0
        let weekendAvg = weekendCount > 0 ? weekendSum / Double(weekendCount) : 0
        
        // Fallback handling
        if weekendAvg == 0 && weekdayAvg > 0 {
            return 0.1  // No weekend data, assume 10% of weekday
        }
        
        if weekdayAvg == 0 {
            return 1.0  // No weekday data, assume 1:1 ratio
        }
        
        return weekendAvg / weekdayAvg
    }
    
    // MARK: - Step 3: Remaining Days Calculation
    
    /// Count remaining weekdays and weekends
    /// - Parameters:
    ///   - today: Current date (UTC)
    ///   - remainingDays: Total days remaining until EOM
    /// - Returns: (remaining weekdays, remaining weekends)
    private func countRemainingWeekdaysAndWeekends(from today: Date, remainingDays: Int) -> (weekdays: Int, weekends: Int) {
        var weekdays = 0
        var weekends = 0
        
        // Guard against negative remaining days (can happen on last day of month)
        guard remainingDays > 0 else {
            return (0, 0)
        }
        
        for dayOffset in 1...remainingDays {
            guard let futureDate = utcCalendar.date(byAdding: .day, value: dayOffset, to: today) else {
                continue
            }
            
            let weekday = utcCalendar.component(.weekday, from: futureDate)
            
            if weekday == 1 || weekday == 7 {
                weekends += 1
            } else {
                weekdays += 1
            }
        }
        
        return (weekdays, weekends)
    }
}
