import Charts
import SwiftUI

enum QuotaDailyUsagePresentation {
    static let chartHeight: CGFloat = 110
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
        Chart(usablePoints) { point in
            BarMark(
                x: .value("日期", date(point.dayStart)),
                y: .value("额度消耗", point.usedPercent)
            )
            .foregroundStyle(barColor(for: point))
            .cornerRadius(3)
            .annotation(position: .top, spacing: 2) {
                Text(QuotaDailyUsagePresentation.percentage(point.usedPercent))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityLabel(
                QuotaDailyUsagePresentation.accessibilityLabel(
                    dayStart: point.dayStart,
                    usedPercent: point.usedPercent,
                    now: now,
                    calendar: calendar
                )
            )

            if selectedDay == point.dayStart {
                RuleMark(x: .value("已选日期", date(point.dayStart)))
                    .foregroundStyle(.secondary.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartXScale(domain: dayDomain.map(date))
        .chartXAxis {
            AxisMarks(values: dayDomain.map(date)) { value in
                AxisValueLabel {
                    if let day = value.as(Date.self) {
                        Text(
                            QuotaDailyUsagePresentation.weekdayLabel(
                                Int64(day.timeIntervalSince1970),
                                calendar: calendar
                            )
                        )
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .chartXSelection(value: selectedDate)
        .frame(height: QuotaDailyUsagePresentation.chartHeight)
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
            Text("单击或拖动查看日期明细")
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

    private var selectedDate: Binding<Date?> {
        Binding(
            get: { selectedDay.map(date) },
            set: { selectedDate in
                selectedDay = selectedDate.flatMap {
                    QuotaDailyUsageChartSelection.nearestPoint(
                        to: Int64($0.timeIntervalSince1970.rounded()),
                        in: usablePoints
                    )?.dayStart
                }
            }
        )
    }

    private func date(_ timestamp: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
}
