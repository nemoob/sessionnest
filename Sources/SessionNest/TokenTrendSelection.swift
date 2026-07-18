import Foundation

enum TokenTrendSelectionDirection {
    case previous
    case next
}

enum TokenTrendSelection {
    static func nearestPoint(
        to timestamp: Int64,
        in points: [StatisticsDailyPoint]
    ) -> StatisticsDailyPoint? {
        points.min { lhs, rhs in
            let leftDistance = abs(lhs.dayStart - timestamp)
            let rightDistance = abs(rhs.dayStart - timestamp)
            if leftDistance != rightDistance { return leftDistance < rightDistance }
            return lhs.dayStart < rhs.dayStart
        }
    }

    static func reconcile(
        selectedDay: Int64?,
        in points: [StatisticsDailyPoint]
    ) -> Int64? {
        guard let selectedDay else { return nil }
        return points.contains { $0.dayStart == selectedDay } ? selectedDay : nil
    }

    static func adjacentPoint(
        from selectedDay: Int64?,
        direction: TokenTrendSelectionDirection,
        in points: [StatisticsDailyPoint]
    ) -> StatisticsDailyPoint? {
        let sorted = points.sorted { $0.dayStart < $1.dayStart }
        guard !sorted.isEmpty else { return nil }
        guard let selectedDay,
            let index = sorted.firstIndex(where: { $0.dayStart == selectedDay })
        else {
            return direction == .next ? sorted.first : sorted.last
        }

        switch direction {
        case .previous:
            return sorted[max(0, index - 1)]
        case .next:
            return sorted[min(sorted.count - 1, index + 1)]
        }
    }
}
