import Charts
import SwiftUI

struct StatisticsDashboardView: View {
    @ObservedObject var model: SessionListModel
    @State private var customStatisticsRange: StatisticsDateRange?
    @State private var showsCustomStatisticsRange = false
    @State private var customStartDate =
        Calendar.current.date(byAdding: .day, value: -29, to: Date()) ?? Date()
    @State private var customEndDate = Date()
    @State private var showsTokenRecalculation = false
    @State private var recalculationStartDate =
        Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var recalculationEndDate = Date()
    @State private var selectedProjectPath: String?

    var body: some View {
        let snapshot =
            customStatisticsRange.map {
                model.statisticsSnapshot(for: $0)
            } ?? model.statisticsSnapshot
        let tokenCoverage = TokenCoverageStatus(
            breakdown: model.tokenCoverageBreakdown(for: snapshot),
            health: model.tokenScanHealth,
            isScanning: model.isScanningTokenUsage
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metricGrid(snapshot: snapshot, tokenCoverage: tokenCoverage)

                if let anomaly = model.tokenUsageAnomaly {
                    anomalyNotice(anomaly)
                }

                if model.isScanningTokenUsage || tokenCoverage.isWarning
                    || snapshot.measuredSessionCount < snapshot.totalSessionCount
                {
                    coverageNotice(tokenCoverage)
                }

                if snapshot.measuredSessionCount == 0 {
                    emptyState
                } else {
                    dailyTrend(snapshot: snapshot)
                    projectRanking(snapshot: snapshot)
                    sessionUsage(snapshot: snapshot)
                }

                Text(TokenUsageDefinition.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .onChange(of: snapshot.projectRows.map(\.projectPath)) { _, projectPaths in
            guard let selectedProjectPath, !projectPaths.contains(selectedProjectPath) else {
                return
            }
            self.selectedProjectPath = nil
        }
        .navigationTitle("统计概览")
        .toolbar { toolbarContent }
        .sheet(isPresented: $showsCustomStatisticsRange) {
            customStatisticsRangeSheet
        }
        .sheet(isPresented: $showsTokenRecalculation) {
            tokenRecalculationSheet
        }
    }

    private func metricGrid(
        snapshot: StatisticsSnapshot,
        tokenCoverage: TokenCoverageStatus
    ) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 250), spacing: 12)],
            spacing: 12
        ) {
            metricCard(
                title: "会话",
                value: snapshot.totalSessionCount.formatted(),
                detail: tokenCoverage.metricDetailText
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
                title: "非缓存 Token",
                value: compact(snapshot.totalUsage.nonCachedTokens),
                detail: exact(snapshot.totalUsage.nonCachedTokens)
            )
        }
    }

    private func anomalyNotice(_ anomaly: TokenUsageAnomaly) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(anomaly.noticeText)
                .font(.callout)
            Spacer()
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func coverageNotice(_ tokenCoverage: TokenCoverageStatus) -> some View {
        HStack(spacing: 8) {
            if model.isLoading || model.isScanningTokenUsage {
                ProgressView()
                    .controlSize(.small)
            } else if tokenCoverage.isWarning {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            Text(tokenCoverage.noticeText)
                .font(.callout)
                .foregroundStyle(tokenCoverage.isWarning ? Color.orange : Color.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            (tokenCoverage.isWarning ? Color.orange : Color.accentColor).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10)
        )
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
            TokenTrendChart(points: snapshot.dailyPoints, presentation: .dashboard)
        }
    }

    private func projectRanking(snapshot: StatisticsSnapshot) -> some View {
        let topProjects = Array(snapshot.projectRows.prefix(10))

        return dashboardSection(
            title: "项目 Token 排行",
            subtitle: "单击项目条形图可下钻会话；展示总 Token 最高的前 10 个项目"
        ) {
            Chart(topProjects) { project in
                BarMark(
                    x: .value("Token", project.usage.totalTokens),
                    y: .value("项目目录", project.projectPath)
                )
                .foregroundStyle(
                    Color.accentColor.opacity(
                        selectedProjectPath == nil || selectedProjectPath == project.projectPath
                            ? 1 : 0.25
                    ).gradient
                )
                .annotation(position: .trailing, alignment: .leading) {
                    HStack(spacing: 4) {
                        Text(compact(project.usage.totalTokens))
                        if selectedProjectPath == project.projectPath {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
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
            .chartYSelection(value: $selectedProjectPath)
            .accessibilityLabel("项目 Token 排行")
            .accessibilityHint("选择项目后，会话用量仅显示该项目")
        }
    }

    private func sessionUsage(snapshot: StatisticsSnapshot) -> some View {
        let selectedProject = selectedProjectPath.flatMap { projectPath in
            snapshot.projectRows.first { $0.projectPath == projectPath }
        }
        let rows = snapshot.sessionRows(forProjectPath: selectedProject?.projectPath)
        let subtitle =
            selectedProject.map {
                "已下钻到 \($0.projectName) 的 \(rows.count) 个会话；双击可在 Codex 中打开"
            } ?? "双击会话行任意位置可在 Codex 中打开"

        return dashboardSection(title: "会话用量", subtitle: subtitle) {
            if let selectedProject {
                HStack(spacing: 8) {
                    Label(selectedProject.projectName, systemImage: "folder.fill")
                        .font(.callout.weight(.semibold))
                    Text(selectedProject.projectPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(selectedProject.projectPath)
                    Spacer()
                    Button("显示全部会话") {
                        selectedProjectPath = nil
                    }
                }
            }

            Table(rows) {
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
                        .help(row.projectPath ?? row.workingDirectory)
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
            Menu {
                ForEach(SessionTimeFilter.allCases, id: \.self) { filter in
                    Button {
                        model.timeFilter = filter
                        customStatisticsRange = nil
                    } label: {
                        if customStatisticsRange == nil, model.timeFilter == filter {
                            Label(filter.rawValue, systemImage: "checkmark")
                        } else {
                            Text(filter.rawValue)
                        }
                    }
                }
                Divider()
                Button {
                    showsCustomStatisticsRange = true
                } label: {
                    Label(
                        "自定义…",
                        systemImage: customStatisticsRange == nil ? "calendar" : "checkmark"
                    )
                }
            } label: {
                Label(statisticsRangeTitle, systemImage: "calendar")
            }
            .help("选择统计时间范围")

            if model.isLoading || model.isScanningTokenUsage {
                ProgressView()
                    .controlSize(.small)
                    .help(model.isLoading ? "正在加载会话" : "正在统计 Token")
            }

            Button {
                showsTokenRecalculation = true
            } label: {
                Label("重新统计…", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("按本地日期范围从原始日志重新统计 Token")
            .disabled(model.isLoading || model.isScanningTokenUsage)

            Button {
                Task { await model.reload() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .help("刷新会话与 Token 统计")
            // Token 扫描尚未完成时禁止重新加载，避免取消并重启同一批日志工作。
            .disabled(model.isLoading || model.isScanningTokenUsage)
        }
    }

    private var statisticsRangeTitle: String {
        guard let customStatisticsRange else { return model.timeFilter.rawValue }
        guard let dates = customStatisticsRange.resolvedDates(calendar: .current) else {
            return "自定义范围"
        }
        return
            "\(dates.start.formatted(date: .numeric, time: .omitted)) – "
            + dates.end.formatted(date: .numeric, time: .omitted)
    }

    private var customStatisticsRangeSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("自定义统计范围")
                .font(.title3.weight(.semibold))
            Text("按本地自然日查看所选闭区间内的 Token、项目和会话统计，不重新读取原始日志。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DatePicker(
                "开始日期",
                selection: $customStartDate,
                in: ...Date(),
                displayedComponents: .date
            )
            DatePicker(
                "结束日期",
                selection: $customEndDate,
                in: ...Date(),
                displayedComponents: .date
            )

            if proposedCustomStatisticsRange == nil {
                Text("开始日期不能晚于结束日期。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) {
                    showsCustomStatisticsRange = false
                }
                Button("应用") {
                    guard let range = proposedCustomStatisticsRange else { return }
                    customStatisticsRange = range
                    showsCustomStatisticsRange = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(proposedCustomStatisticsRange == nil)
            }
        }
        .padding(20)
        .frame(width: 390)
    }

    private var proposedCustomStatisticsRange: StatisticsDateRange? {
        StatisticsDateRange(from: customStartDate, through: customEndDate)
    }

    private var tokenRecalculationSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重新统计 Token")
                .font(.title3.weight(.semibold))
            Text("重新读取原始 JSONL，并只替换所选本地自然日内的派生统计；日志本身有变化时仍会完整同步。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DatePicker(
                "开始日期",
                selection: $recalculationStartDate,
                in: ...Date(),
                displayedComponents: .date
            )
            DatePicker(
                "结束日期",
                selection: $recalculationEndDate,
                in: ...Date(),
                displayedComponents: .date
            )

            HStack {
                Spacer()
                Button("取消", role: .cancel) {
                    showsTokenRecalculation = false
                }
                Button("重新统计") {
                    let startDate = recalculationStartDate
                    let endDate = recalculationEndDate
                    showsTokenRecalculation = false
                    Task {
                        await model.recalculateTokenUsage(
                            from: startDate,
                            through: endDate
                        )
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(recalculationStartDate > recalculationEndDate)
            }
        }
        .padding(20)
        .frame(width: 390)
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
