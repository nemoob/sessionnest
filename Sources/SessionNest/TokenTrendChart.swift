import Charts
import SwiftUI

enum TokenTrendChartPresentation {
    case dashboard
    case popover
}

struct TokenTrendChart: View {
    let points: [StatisticsDailyPoint]
    let presentation: TokenTrendChartPresentation

    @State private var hoveredDay: Int64?
    @State private var pinnedDay: Int64?

    private var selectedDay: Int64? { pinnedDay ?? hoveredDay }

    private var selectedPoint: StatisticsDailyPoint? {
        guard let selectedDay else { return nil }
        return points.first { $0.dayStart == selectedDay }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: presentation == .dashboard ? 12 : 8) {
            chart
            detail
        }
        .onChange(of: points.map(\.dayStart)) {
            pinnedDay = TokenTrendSelection.reconcile(selectedDay: pinnedDay, in: points)
            hoveredDay = TokenTrendSelection.reconcile(selectedDay: hoveredDay, in: points)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("每日 Token 趋势")
        .accessibilityValue(selectedPoint.map(accessibilityValue) ?? "未选择日期")
        .accessibilityAction(named: "上一日") {
            moveSelection(.previous)
        }
        .accessibilityAction(named: "下一日") {
            moveSelection(.next)
        }
        .accessibilityAction(named: "清除选择") {
            pinnedDay = nil
            hoveredDay = nil
        }
    }

    private var chart: some View {
        Chart(points) { point in
            LineMark(
                x: .value("日期", date(point.dayStart)),
                y: .value("Token", point.usage.totalTokens),
                series: .value("类型", "总 Token")
            )
            .foregroundStyle(by: .value("类型", "总 Token"))
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("日期", date(point.dayStart)),
                y: .value("Token", point.usage.cachedInputTokens),
                series: .value("类型", "缓存输入")
            )
            .foregroundStyle(by: .value("类型", "缓存输入"))
            .interpolationMethod(.monotone)

            if points.count == 1 && selectedDay != point.dayStart {
                markers(for: point, size: 36)
            }

            if selectedDay == point.dayStart {
                RuleMark(x: .value("已选日期", date(point.dayStart)))
                    .foregroundStyle(.secondary.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                markers(for: point, size: presentation == .dashboard ? 52 : 42)
            }
        }
        .chartForegroundStyleScale([
            "总 Token": Color.accentColor,
            "缓存输入": Color.orange,
        ])
        .chartXAxis(presentation == .popover ? .hidden : .automatic)
        .chartYAxis {
            AxisMarks(position: presentation == .dashboard ? .leading : .trailing) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Int64.self) {
                        Text(compact(amount))
                    }
                }
            }
        }
        .chartLegend(
            presentation == .dashboard ? .visible : .hidden
        )
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let location):
                            hoveredDay =
                                point(at: location, proxy: proxy, geometry: geometry)?.dayStart
                        case .ended:
                            hoveredDay = nil
                        }
                    }
                    .simultaneousGesture(
                        SpatialTapGesture().onEnded { value in
                            guard
                                let point = point(
                                    at: value.location,
                                    proxy: proxy,
                                    geometry: geometry
                                )
                            else {
                                pinnedDay = nil
                                return
                            }
                            pinnedDay = pinnedDay == point.dayStart ? nil : point.dayStart
                        }
                    )
            }
        }
        .frame(height: presentation == .dashboard ? 230 : 130)
    }

    @ChartContentBuilder
    private func markers(for point: StatisticsDailyPoint, size: CGFloat) -> some ChartContent {
        PointMark(
            x: .value("日期", date(point.dayStart)),
            y: .value("Token", point.usage.totalTokens)
        )
        .foregroundStyle(Color.accentColor)
        .symbolSize(size)

        PointMark(
            x: .value("日期", date(point.dayStart)),
            y: .value("Token", point.usage.cachedInputTokens)
        )
        .foregroundStyle(Color.orange)
        .symbolSize(size)
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedPoint {
            switch presentation {
            case .dashboard:
                dashboardDetail(selectedPoint)
            case .popover:
                popoverDetail(selectedPoint)
            }
        } else {
            Text("悬停查看明细，单击可固定日期")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func dashboardDetail(_ point: StatisticsDailyPoint) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(formattedDate(point.dayStart))
                    .font(.headline)
                if pinnedDay == point.dayStart {
                    Text("已固定")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Text("总计 \(exact(point.usage.totalTokens))")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }

            Grid(horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow {
                    detailValue("输入", point.usage.inputTokens)
                    detailValue("缓存输入", point.usage.cachedInputTokens)
                    detailValue("输出", point.usage.outputTokens)
                    detailValue("推理输出", point.usage.reasoningOutputTokens)
                }
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func popoverDetail(_ point: StatisticsDailyPoint) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(formattedDate(point.dayStart))
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("总计 \(compact(point.usage.totalTokens))")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            HStack {
                compactDetail("输入", point.usage.inputTokens)
                Spacer()
                compactDetail("缓存", point.usage.cachedInputTokens)
            }
            HStack {
                compactDetail("输出", point.usage.outputTokens)
                Spacer()
                compactDetail("推理", point.usage.reasoningOutputTokens)
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func detailValue(_ title: String, _ value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(exact(value))
                .font(.callout)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactDetail(_ title: String, _ value: Int64) -> some View {
        Text("\(title) \(compact(value))")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    private func point(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> StatisticsDailyPoint? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let plotRect = geometry[plotFrame]
        guard plotRect.contains(location) else { return nil }
        let plotX = location.x - plotRect.minX
        guard let selectedDate: Date = proxy.value(atX: plotX) else { return nil }
        return TokenTrendSelection.nearestPoint(
            to: Int64(selectedDate.timeIntervalSince1970.rounded()),
            in: points
        )
    }

    private func moveSelection(_ direction: TokenTrendSelectionDirection) {
        let point = TokenTrendSelection.adjacentPoint(
            from: selectedDay,
            direction: direction,
            in: points
        )
        pinnedDay = point?.dayStart
        hoveredDay = nil
    }

    private func accessibilityValue(_ point: StatisticsDailyPoint) -> String {
        "\(formattedDate(point.dayStart))，总 Token \(exact(point.usage.totalTokens))，"
            + "输入 \(exact(point.usage.inputTokens))，缓存输入 "
            + "\(exact(point.usage.cachedInputTokens))，输出 \(exact(point.usage.outputTokens))，"
            + "推理输出 \(exact(point.usage.reasoningOutputTokens))"
    }

    private func date(_ timestamp: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    private func formattedDate(_ timestamp: Int64) -> String {
        date(timestamp).formatted(
            .dateTime.year().month().day().locale(Locale(identifier: "zh-Hans-CN"))
        )
    }

    private func compact(_ value: Int64) -> String {
        value.formatted(
            .number.notation(.compactName).locale(Locale(identifier: "zh-Hans-CN"))
        )
    }

    private func exact(_ value: Int64) -> String {
        "\(value.formatted()) Token"
    }
}
