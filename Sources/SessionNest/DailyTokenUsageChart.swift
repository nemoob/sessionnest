import SwiftUI

enum DailyTokenUsagePresentation {
    static let chartHeight: CGFloat = 110
    static let barAreaHeight: CGFloat = 62
    static let emptyText = "暂无每日非缓存 Token 记录"
    static let observationCaption = "按本机日志估算非缓存 Token，不代表服务端额度消耗"

    private static let compactNumberFormat = IntegerFormatStyle<Int64>.number
        .notation(.compactName)
        .locale(Locale(identifier: "zh-Hans-CN"))
    private static let exactNumberFormat = IntegerFormatStyle<Int64>.number
        .locale(Locale(identifier: "zh-Hans-CN"))

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

    static func compactTokenText(_ tokens: Int64) -> String {
        max(0, tokens).formatted(compactNumberFormat)
    }

    static func exactTokenText(_ tokens: Int64) -> String {
        "\(max(0, tokens).formatted(exactNumberFormat)) Token"
    }

    static func nonCachedTokens(_ usage: TokenUsageBreakdown) -> Int64 {
        usage.nonCachedTokens
    }

    static func cachePercentageText(_ usage: TokenUsageBreakdown) -> String {
        guard usage.totalTokens > 0 else { return "0%" }
        let fraction = min(
            max(Double(usage.cachedInputTokens) / Double(usage.totalTokens), 0),
            1
        )
        return "\(Int((fraction * 100).rounded()))%"
    }

    static func barHeight(tokens: Int64, maximum: Int64) -> CGFloat {
        guard tokens > 0, maximum > 0 else { return 0 }
        return max(3, barAreaHeight * min(CGFloat(tokens) / CGFloat(maximum), 1))
    }

    static func accessibilityLabel(
        dayStart: Int64,
        tokens: Int64,
        now: Int64,
        calendar: Calendar
    ) -> String {
        let relativeLabel = dayLabel(dayStart, now: now, calendar: calendar)
        let fullDateLabel = fullDateLabel(dayStart, calendar: calendar)
        let dateLabel =
            relativeLabel == "今天" || relativeLabel == "昨天"
            ? "\(relativeLabel)，\(fullDateLabel)"
            : fullDateLabel
        return "\(dateLabel)，非缓存 \(exactTokenText(tokens))"
    }

    private static func fullDateLabel(_ dayStart: Int64, calendar: Calendar) -> String {
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: Date(timeIntervalSince1970: TimeInterval(dayStart))
        )
        return "\(components.year ?? 0)年\(components.month ?? 0)月\(components.day ?? 0)日"
    }
}

enum DailyTokenUsageSelection {
    static func reconcile(
        selectedDay: Int64?,
        in points: [StatisticsDailyPoint]
    ) -> Int64? {
        guard let selectedDay else { return nil }
        return points.contains { $0.dayStart == selectedDay } ? selectedDay : nil
    }
}

struct DailyTokenUsageChart: View {
    let points: [StatisticsDailyPoint]
    let now: Int64
    let calendar: Calendar

    @State private var selectedDay: Int64?

    private var selectedPoint: StatisticsDailyPoint? {
        guard let selectedDay else { return nil }
        return usablePoints.first { $0.dayStart == selectedDay }
    }

    private var dayDomain: [Int64] {
        DailyTokenUsagePresentation.dayDomain(now: now, calendar: calendar)
    }

    private var usablePoints: [StatisticsDailyPoint] {
        let visibleDays = Set(dayDomain)
        return
            points
            .filter { visibleDays.contains($0.dayStart) && $0.usage.totalTokens > 0 }
            .sorted { $0.dayStart < $1.dayStart }
    }

    private var pointsByDay: [Int64: StatisticsDailyPoint] {
        usablePoints.reduce(into: [:]) { $0[$1.dayStart] = $1 }
    }

    private var maximumObservedTokens: Int64 {
        usablePoints.map { DailyTokenUsagePresentation.nonCachedTokens($0.usage) }.max() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if usablePoints.isEmpty {
                Text(DailyTokenUsagePresentation.emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                chart
                detail
            }

            Text(DailyTokenUsagePresentation.observationCaption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: usablePoints.map(\.dayStart)) {
            selectedDay = DailyTokenUsageSelection.reconcile(
                selectedDay: selectedDay,
                in: usablePoints
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("每日非缓存 Token")
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
        .frame(height: DailyTokenUsagePresentation.chartHeight)
    }

    private func dayBar(_ dayStart: Int64) -> some View {
        let point = pointsByDay[dayStart]
        let isSelected = selectedDay == dayStart

        return Button {
            guard point != nil else { return }
            selectedDay = isSelected ? nil : dayStart
        } label: {
            VStack(spacing: 4) {
                Text(
                    point.map {
                        DailyTokenUsagePresentation.compactTokenText(
                            DailyTokenUsagePresentation.nonCachedTokens($0.usage)
                        )
                    } ?? "--"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .opacity(point == nil ? 0 : 1)

                VStack {
                    Spacer(minLength: 0)
                    if let point {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(barColor(dayStart: point.dayStart))
                            .frame(
                                height: DailyTokenUsagePresentation.barHeight(
                                    tokens: DailyTokenUsagePresentation.nonCachedTokens(
                                        point.usage
                                    ),
                                    maximum: maximumObservedTokens
                                )
                            )
                    }
                }
                .frame(height: DailyTokenUsagePresentation.barAreaHeight)

                Text(DailyTokenUsagePresentation.weekdayLabel(dayStart, calendar: calendar))
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
                DailyTokenUsagePresentation.accessibilityLabel(
                    dayStart: dayStart,
                    tokens: DailyTokenUsagePresentation.nonCachedTokens($0.usage),
                    now: now,
                    calendar: calendar
                )
            }
                ?? "\(DailyTokenUsagePresentation.weekdayLabel(dayStart, calendar: calendar))，无本地非缓存 Token 记录"
        )
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedPoint {
            let nonCachedText = DailyTokenUsagePresentation.exactTokenText(
                DailyTokenUsagePresentation.nonCachedTokens(selectedPoint.usage)
            )
            let totalText = DailyTokenUsagePresentation.exactTokenText(
                selectedPoint.usage.totalTokens
            )
            let cachedText = DailyTokenUsagePresentation.exactTokenText(
                selectedPoint.usage.cachedInputTokens
            )
            let cachePercentage = DailyTokenUsagePresentation.cachePercentageText(
                selectedPoint.usage
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(
                        DailyTokenUsagePresentation.dayLabel(
                            selectedPoint.dayStart,
                            now: now,
                            calendar: calendar
                        )
                    )
                    .fontWeight(.semibold)
                    Spacer()
                    Text("非缓存 \(nonCachedText)")
                        .monospacedDigit()
                }
                HStack(spacing: 8) {
                    Text("总计 \(totalText)")
                    Spacer()
                    Text("缓存 \(cachedText) · \(cachePercentage)")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .font(.caption)
        } else {
            Text("单击柱条查看非缓存、总计和缓存占比")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func barColor(dayStart: Int64) -> Color {
        let today = calendar.startOfDay(
            for: Date(timeIntervalSince1970: TimeInterval(now))
        )
        let isToday = calendar.isDate(
            Date(timeIntervalSince1970: TimeInterval(dayStart)),
            inSameDayAs: today
        )
        return Color.accentColor.opacity(isToday ? 1 : 0.35)
    }
}
