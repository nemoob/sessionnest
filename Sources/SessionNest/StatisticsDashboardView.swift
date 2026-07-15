import Charts
import SwiftUI

struct StatisticsDashboardView: View {
    @ObservedObject var model: SessionListModel

    var body: some View {
        let snapshot = model.statisticsSnapshot

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metricGrid(snapshot: snapshot)

                if snapshot.measuredSessionCount < snapshot.totalSessionCount {
                    coverageNotice
                }

                if snapshot.measuredSessionCount == 0 {
                    emptyState
                } else {
                    dailyTrend(snapshot: snapshot)
                    projectRanking(snapshot: snapshot)
                    sessionUsage(snapshot: snapshot)
                }

                Text(
                    "Token 数据只从本机 Codex 会话文件读取并缓存在此 App 中，不会修改会话内容。缓存输入属于输入 Token，推理 Token 属于输出 Token，均不会重复计入总量。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .navigationTitle("统计概览")
        .toolbar { toolbarContent }
    }

    private func metricGrid(snapshot: StatisticsSnapshot) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 250), spacing: 12)],
            spacing: 12
        ) {
            metricCard(
                title: "会话",
                value: snapshot.totalSessionCount.formatted(),
                detail: "已统计 \(snapshot.measuredSessionCount) / \(snapshot.totalSessionCount)"
            )
            metricCard(
                title: "总 Token",
                value: compact(snapshot.totalUsage.totalTokens),
                detail: exact(snapshot.totalUsage.totalTokens)
            )
            metricCard(
                title: "平均 / 会话",
                value: compact(snapshot.averageTokensPerMeasuredSession),
                detail: snapshot.measuredSessionCount == 0
                    ? "暂无已统计会话"
                    : "按已统计会话计算"
            )
            metricCard(
                title: "缓存输入",
                value: compact(snapshot.totalUsage.cachedInputTokens),
                detail: exact(snapshot.totalUsage.cachedInputTokens)
            )
        }
    }

    private var coverageNotice: some View {
        HStack(spacing: 8) {
            if model.isLoading || model.isScanningTokenUsage {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            Text(
                model.isScanningTokenUsage
                    ? "正在后台统计剩余会话，当前结果会在扫描完成后更新。"
                    : "部分会话没有可读取的 Token 记录，因此不会按 0 计入平均值。"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var emptyState: some View {
        Group {
            if model.isLoading || model.isScanningTokenUsage {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在统计 Token…")
                        .font(.headline)
                    Text("首次读取本机会话历史需要一点时间，其他会话管理功能仍可正常使用。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                ContentUnavailableView(
                    "没有可用 Token 数据",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("当前时间范围内没有可读取的 Token 记录。")
                )
                .frame(maxWidth: .infinity, minHeight: 260)
            }
        }
        .dashboardCard()
    }

    private func dailyTrend(snapshot: StatisticsSnapshot) -> some View {
        dashboardSection(title: "Token 趋势", subtitle: "按本地自然日统计实际新增用量") {
            Chart(snapshot.dailyPoints) { point in
                LineMark(
                    x: .value("日期", date(for: point.dayStart)),
                    y: .value("Token", point.usage.totalTokens),
                    series: .value("类型", "总 Token")
                )
                .foregroundStyle(by: .value("类型", "总 Token"))
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("日期", date(for: point.dayStart)),
                    y: .value("Token", point.usage.cachedInputTokens),
                    series: .value("类型", "缓存输入")
                )
                .foregroundStyle(by: .value("类型", "缓存输入"))
                .interpolationMethod(.monotone)
            }
            .chartForegroundStyleScale([
                "总 Token": Color.accentColor,
                "缓存输入": Color.orange,
            ])
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Int64.self) {
                            Text(compact(amount))
                        }
                    }
                }
            }
            .frame(height: 230)
            .accessibilityLabel("每日 Token 趋势")
        }
    }

    private func projectRanking(snapshot: StatisticsSnapshot) -> some View {
        let topProjects = Array(snapshot.projectRows.prefix(10))

        return dashboardSection(title: "项目 Token 排行", subtitle: "当前时间范围内总 Token 最高的前 10 个项目") {
            Chart(topProjects) { project in
                BarMark(
                    x: .value("Token", project.usage.totalTokens),
                    y: .value("项目目录", project.projectPath)
                )
                .foregroundStyle(Color.accentColor.gradient)
                .annotation(position: .trailing, alignment: .leading) {
                    Text(compact(project.usage.totalTokens))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(values: topProjects.map(\.projectPath)) { value in
                    AxisValueLabel {
                        if let path = value.as(String.self),
                            let project = topProjects.first(where: { $0.projectPath == path })
                        {
                            Text(project.projectName)
                                .lineLimit(1)
                                .help(project.projectPath)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Int64.self) {
                            Text(compact(amount))
                        }
                    }
                }
            }
            .frame(height: max(220, CGFloat(topProjects.count) * 30))
            .accessibilityLabel("项目 Token 排行")
        }
    }

    private func sessionUsage(snapshot: StatisticsSnapshot) -> some View {
        dashboardSection(title: "会话用量", subtitle: "双击会话行任意位置可在 Codex 中打开") {
            Table(snapshot.sessionRows) {
                TableColumn("会话") { row in
                    Text(row.title)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            model.open(threadID: row.threadID)
                        }
                        .accessibilityAction(named: "在 Codex 中打开") {
                            model.open(threadID: row.threadID)
                        }
                        .help("双击在 Codex 中打开")
                }
                .width(min: 170, ideal: 260)

                TableColumn("项目") { row in
                    Text(row.projectName)
                        .lineLimit(1)
                        .help(row.projectPath)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            model.open(threadID: row.threadID)
                        }
                }
                .width(min: 90, ideal: 140)

                TableColumn("输入") { row in
                    tokenCell(
                        primary: row.usage.inputTokens,
                        secondaryLabel: "缓存",
                        secondary: row.usage.cachedInputTokens
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        model.open(threadID: row.threadID)
                    }
                }
                .width(min: 90, ideal: 110)

                TableColumn("输出") { row in
                    tokenCell(
                        primary: row.usage.outputTokens,
                        secondaryLabel: "推理",
                        secondary: row.usage.reasoningOutputTokens
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        model.open(threadID: row.threadID)
                    }
                }
                .width(min: 90, ideal: 110)

                TableColumn("总量") { row in
                    Text(compact(row.usage.totalTokens))
                        .monospacedDigit()
                        .help(exact(row.usage.totalTokens))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            model.open(threadID: row.threadID)
                        }
                }
                .width(min: 80, ideal: 100)
            }
            .frame(minHeight: 320)
            .accessibilityLabel("会话 Token 用量")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Picker("时间", selection: $model.timeFilter) {
                ForEach(SessionTimeFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .labelsHidden()
            .frame(width: 120)
            .help("选择统计时间范围")

            if model.isLoading || model.isScanningTokenUsage {
                ProgressView()
                    .controlSize(.small)
                    .help(model.isLoading ? "正在加载会话" : "正在统计 Token")
            }

            Button {
                Task { await model.reload() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .help("刷新会话与 Token 统计")
            .disabled(model.isLoading)
        }
    }

    private func metricCard(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        .padding(16)
        .dashboardCard()
    }

    private func dashboardSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(16)
        .dashboardCard()
    }

    private func tokenCell(
        primary: Int64,
        secondaryLabel: String,
        secondary: Int64
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(compact(primary))
                .monospacedDigit()
                .help(exact(primary))
            Text("\(secondaryLabel) \(compact(secondary))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .help(exact(secondary))
        }
    }

    private func compact(_ value: Int64) -> String {
        value.formatted(.number.notation(.compactName))
    }

    private func exact(_ value: Int64) -> String {
        "\(value.formatted()) Token"
    }

    private func date(for timestamp: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
}

extension View {
    fileprivate func dashboardCard() -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.separator.opacity(0.45), lineWidth: 1)
            }
    }
}
