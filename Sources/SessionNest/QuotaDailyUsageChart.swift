import SwiftUI

enum QuotaDailyUsagePresentation {
    static let chartHeight: CGFloat = 110
    static let barAreaHeight: CGFloat = 62
    static let emptyText = "从现在开始记录每日额度变化"
    static let observationCaption = "仅统计本地观察到的 Codex 额度快照，无法回溯此前用量"

    static func dayDomain(now: Int64, calendar: Calendar) -> [Int64] {
        let today = calendar.startOfDay(
            for: Date(timeIntervalSince1970: TimeInterval(now))
        )
        return (0..<7).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map {
                Int64($0.timeIntervalSince1970)
            }
        }
    }

    static func dayLabel(_ dayStart: Int64, now: Int64, calendar: Calendar) -> String {
        let day = Date(timeIntervalSince1970: TimeInterval(dayStart))
        let today = calendar.startOfDay(
            for: Date(timeIntervalSince1970: TimeInterval(now))
        )
        if calendar.isDate(day, inSameDayAs: today) { return "今天" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
            calendar.isDate(day, inSameDayAs: yesterday)
        {
            return "昨天"
        }

        let components = calendar.dateComponents([.month, .day], from: day)
        return "\(components.month ?? 0)月\(components.day ?? 0)日"
    }

    static func weekdayLabel(_ dayStart: Int64, calendar: Calendar) -> String {
        let weekday = calendar.component(
            .weekday,
            from: Date(timeIntervalSince1970: TimeInterval(dayStart))
        )
        return ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][weekday - 1]
    }

    static func percentage(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        return value.formatted(
            .number.precision(.fractionLength(0...1)).locale(Locale(identifier: "zh-Hans-CN"))
        ) + "%"
    }

    static func barHeight(usedPercent: Double, maximum: Double) -> CGFloat {
        guard
            usedPercent.isFinite,
            usedPercent > 0,
            maximum.isFinite,
            maximum > 0
        else { return 0 }

        return max(3, barAreaHeight * min(usedPercent / maximum, 1))
    }

    static func tokenText(
        for dayStart: Int64,
        in points: [StatisticsDailyPoint]
    ) -> String? {
        points.first { $0.dayStart == dayStart }.map {
            let value = $0.usage.totalTokens.formatted(
                .number.notation(.compactName).locale(Locale(identifier: "zh-Hans-CN"))
            )
            return "\(value) Token"
        }
    }

    static func accessibilityLabel(
        dayStart: Int64,
        usedPercent: Double,
        now: Int64,
        calendar: Calendar
    ) -> String {
        let relativeLabel = dayLabel(dayStart, now: now, calendar: calendar)
        let fullDateLabel = fullDateLabel(dayStart, calendar: calendar)
        let dateLabel =
            relativeLabel == "今天" || relativeLabel == "昨天"
            ? "\(relativeLabel)，\(fullDateLabel)"
            : fullDateLabel
        return "\(dateLabel)，消耗 \(percentage(usedPercent))"
    }

    private static func fullDateLabel(_ dayStart: Int64, calendar: Calendar) -> String {
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: Date(timeIntervalSince1970: TimeInterval(dayStart))
        )
        return "\(components.year ?? 0)年\(components.month ?? 0)月\(components.day ?? 0)日"
    }
}

enum QuotaDailyUsageChartSelection {
    static func nearestPoint(
        to timestamp: Int64,
        in points: [QuotaDailyUsagePoint]
    ) -> QuotaDailyUsagePoint? {
        points.min { lhs, rhs in
            let leftDistance = abs(lhs.dayStart - timestamp)
            let rightDistance = abs(rhs.dayStart - timestamp)
            if leftDistance != rightDistance { return leftDistance < rightDistance }
            return lhs.dayStart < rhs.dayStart
        }
    }

    static func reconcile(
        selectedDay: Int64?,
        in points: [QuotaDailyUsagePoint]
    ) -> Int64? {
        guard let selectedDay else { return nil }
        return points.contains { $0.dayStart == selectedDay } ? selectedDay : nil
    }
}

struct QuotaDailyUsageChart: View {
    let points: [QuotaDailyUsagePoint]
    let statisticsDailyPoints: [StatisticsDailyPoint]
    let now: Int64
    let calendar: Calendar
    let quotaColor: MenuBarQuotaColor

    @State private var selectedDay: Int64?

    private var selectedPoint: QuotaDailyUsagePoint? {
        guard let selectedDay else { return nil }
        return usablePoints.first { $0.dayStart == selectedDay }
    }

    private var dayDomain: [Int64] {
        QuotaDailyUsagePresentation.dayDomain(now: now, calendar: calendar)
    }

    private var usablePoints: [QuotaDailyUsagePoint] {
        let visibleDays = Set(dayDomain)
        return
            points
            .filter {
                visibleDays.contains($0.dayStart) && $0.usedPercent.isFinite
                    && $0.usedPercent > 0
            }
            .sorted { $0.dayStart < $1.dayStart }
    }

    private var pointsByDay: [Int64: QuotaDailyUsagePoint] {
        Dictionary(uniqueKeysWithValues: usablePoints.map { ($0.dayStart, $0) })
    }

    private var maximumObservedPercent: Double {
        max(10, usablePoints.map(\.usedPercent).max() ?? 10)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if usablePoints.isEmpty {
                Text(QuotaDailyUsagePresentation.emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                chart
                detail
            }

            Text(QuotaDailyUsagePresentation.observationCaption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: usablePoints.map(\.dayStart)) {
            selectedDay = QuotaDailyUsageChartSelection.reconcile(
                selectedDay: selectedDay,
                in: usablePoints
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("本周期每日消耗")
        .accessibilityAction(named: "清除选择") {
            selectedDay = nil
        }
    }

    private var chart: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(dayDomain, id: \.self) { dayStart in
                dayBar(dayStart)
            }
        }
        .frame(height: QuotaDailyUsagePresentation.chartHeight)
    }

    private func dayBar(_ dayStart: Int64) -> some View {
        let point = pointsByDay[dayStart]
        let isSelected = selectedDay == dayStart

        return Button {
            guard point != nil else { return }
            selectedDay = isSelected ? nil : dayStart
        } label: {
            VStack(spacing: 4) {
                Text(QuotaDailyUsagePresentation.percentage(point?.usedPercent))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .opacity(point == nil ? 0 : 1)

                VStack {
                    Spacer(minLength: 0)
                    if let point {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(barColor(for: point))
                            .frame(
                                height: QuotaDailyUsagePresentation.barHeight(
                                    usedPercent: point.usedPercent,
                                    maximum: maximumObservedPercent
                                )
                            )
                    }
                }
                .frame(height: QuotaDailyUsagePresentation.barAreaHeight)

                Text(QuotaDailyUsagePresentation.weekdayLabel(dayStart, calendar: calendar))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 2)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.primary.opacity(0.08) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(point == nil)
        .accessibilityLabel(
            point.map {
                QuotaDailyUsagePresentation.accessibilityLabel(
                    dayStart: dayStart,
                    usedPercent: $0.usedPercent,
                    now: now,
                    calendar: calendar
                )
            } ?? "\(QuotaDailyUsagePresentation.weekdayLabel(dayStart, calendar: calendar))，无观测数据"
        )
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedPoint {
            HStack(spacing: 8) {
                Text(
                    QuotaDailyUsagePresentation.dayLabel(
                        selectedPoint.dayStart,
                        now: now,
                        calendar: calendar
                    )
                )
                .fontWeight(.semibold)
                Text("额度变化 \(QuotaDailyUsagePresentation.percentage(selectedPoint.usedPercent))")
                    .monospacedDigit()
                if let tokenText = QuotaDailyUsagePresentation.tokenText(
                    for: selectedPoint.dayStart,
                    in: statisticsDailyPoints
                ) {
                    Spacer()
                    Text("本地 \(tokenText)")
                        .monospacedDigit()
                }
            }
            .font(.caption)
        } else {
            Text("单击柱条查看日期明细")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func barColor(for point: QuotaDailyUsagePoint) -> Color {
        let today = calendar.startOfDay(
            for: Date(timeIntervalSince1970: TimeInterval(now))
        )
        let isToday = calendar.isDate(
            Date(timeIntervalSince1970: TimeInterval(point.dayStart)),
            inSameDayAs: today
        )
        return quotaColor.swiftUIColor.opacity(isToday ? 1 : 0.32)
    }

}
