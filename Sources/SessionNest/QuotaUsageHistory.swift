import Foundation

struct QuotaUsageSample: Equatable, Sendable {
    let cycleResetsAt: Int64
    let capturedAt: Int64
    let usedPercent: Double
}

struct QuotaDailyUsagePoint: Equatable, Identifiable, Sendable {
    let dayStart: Int64
    let usedPercent: Double

    var id: Int64 { dayStart }
}

enum QuotaDailyUsage {
    static let maximumGap: Int64 = 30 * 60

    static func build(
        samples: [QuotaUsageSample],
        cycleResetsAt: Int64,
        now: Int64,
        calendar: Calendar
    ) -> [QuotaDailyUsagePoint] {
        let currentDay = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(now)))
        guard let earliestDay = calendar.date(byAdding: .day, value: -6, to: currentDay) else {
            return []
        }

        let earliestDayStart = Int64(earliestDay.timeIntervalSince1970)
        let qualifyingSamples =
            samples
            .filter {
                $0.cycleResetsAt == cycleResetsAt
                    && $0.capturedAt <= now
                    && $0.usedPercent.isFinite
            }
            .sorted { $0.capturedAt < $1.capturedAt }

        let dailyUsage = zip(qualifyingSamples, qualifyingSamples.dropFirst()).reduce(
            into: [Int64: Double]()
        ) { totals, pair in
            let (earlier, later) = pair
            let interval = later.capturedAt - earlier.capturedAt
            let usage = later.usedPercent - earlier.usedPercent
            guard interval >= 1, interval <= maximumGap, usage.isFinite, usage > 0 else {
                return
            }

            let dayStart = Int64(
                calendar.startOfDay(
                    for: Date(timeIntervalSince1970: TimeInterval(later.capturedAt))
                ).timeIntervalSince1970
            )
            guard dayStart >= earliestDayStart else { return }
            totals[dayStart] = min(100, (totals[dayStart] ?? 0) + usage)
        }

        return
            dailyUsage
            .map { QuotaDailyUsagePoint(dayStart: $0.key, usedPercent: $0.value) }
            .sorted { $0.dayStart < $1.dayStart }
    }
}
