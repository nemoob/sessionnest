import Charts
import SwiftUI

enum SessionNestPublicLink: CaseIterable, Hashable {
    case website
    case repository

    var url: URL {
        switch self {
        case .website: URL(string: "https://www.nemoob.cn/")!
        case .repository: URL(string: "https://github.com/nemoob/sessionnest")!
        }
    }

    var title: String {
        switch self {
        case .website: "打开主站"
        case .repository: "打开 GitHub"
        }
    }

    var systemImage: String {
        switch self {
        case .website: "globe"
        case .repository: "chevron.left.forwardslash.chevron.right"
        }
    }
}

private enum StatusPopoverPage {
    case overview
    case settings
}

struct SessionNestStatusPopover: View {
    @ObservedObject var model: SessionListModel
    @ObservedObject var refreshState: StatusItemRefreshState
    @Environment(\.openURL) private var openURL
    @State private var page = StatusPopoverPage.overview
    @AppStorage("sessionnest.theme") private var storedTheme = AppTheme.system.rawValue
    let refresh: () -> Void
    let openMainWindow: () -> Void
    let quit: () -> Void

    var body: some View {
        Group {
            switch page {
            case .overview:
                overview
            case .settings:
                settings
            }
        }
        .padding(16)
        .frame(
            width: SessionNestStatusPopoverLayout.width,
            height: SessionNestStatusPopoverLayout.height
        )
        .preferredColorScheme(AppTheme(storedValue: storedTheme).colorScheme)
    }

    private var overview: some View {
        let statisticsScope = StatusPopoverStatisticsScope.resolve(
            cycleSnapshot: model.currentQuotaCycleStatisticsSnapshot(),
            fallbackSnapshot: model.statisticsSnapshot(for: .sevenDays)
        )
        let snapshot = statisticsScope.snapshot
        let status = MenuBarStatus(
            snapshot: snapshot,
            quotaCycleTokens: model.currentQuotaCycleTokenUsage(),
            rateLimits: model.rateLimitSnapshot,
            account: model.accountSnapshot,
            isLoading: model.isLoading,
            isRefreshing: refreshState.isRefreshing || model.isScanningTokenUsage
        )
        let statistics = MenuBarStatisticsStatus(
            snapshot: snapshot,
            isScanningTokenUsage: model.isScanningTokenUsage
        )

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SessionNest")
                            .font(.headline)
                        HStack(spacing: 4) {
                            Text(status.account.planText)
                            Text(status.account.emailText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.14), in: Capsule())
                    }
                    Spacer()
                    ForEach(SessionNestPublicLink.allCases, id: \.self) { link in
                        Button {
                            openURL(link.url)
                        } label: {
                            Label(link.title, systemImage: link.systemImage)
                                .labelStyle(.iconOnly)
                        }
                        .help(link.title)
                        .accessibilityLabel(link.title)
                    }
                    Button(action: refresh) {
                        Label("刷新", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(status.showsProgress)
                    Button(action: openMainWindow) {
                        Label("打开 SessionNest", systemImage: "macwindow")
                            .labelStyle(.iconOnly)
                    }
                }

                Text("配额")
                    .font(.subheadline.weight(.semibold))
                quotaRow(title: "每周", quota: status.weeklyQuota)

                Text(statisticsScope.title)
                    .font(.subheadline.weight(.semibold))
                if statistics.showsTokenScanProgress {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在统计 Token…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        metricCard(
                            title: "会话",
                            value: statistics.sessionValueText,
                            detail: statistics.sessionDetailText
                        )
                        metricCard(
                            title: "总 Token",
                            value: statistics.totalTokenValueText,
                            detail: statistics.totalTokenDetailText
                        )
                    }
                    HStack(spacing: 10) {
                        metricCard(
                            title: "平均 / 会话",
                            value: statistics.averageValueText,
                            detail: statistics.averageDetailText
                        )
                        metricCard(
                            title: "缓存输入",
                            value: statistics.cachedInputValueText,
                            detail: statistics.cachedInputDetailText
                        )
                    }
                }

                Text("Token 趋势")
                    .font(.subheadline.weight(.semibold))
                if statistics.dailyPoints.isEmpty {
                    Text(statistics.tokenTrendEmptyText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    tokenTrend(statistics)
                }

                Text("项目 Token")
                    .font(.subheadline.weight(.semibold))
                if statistics.topProjects.isEmpty {
                    Text(statistics.projectTokenEmptyText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(statistics.topProjects) { project in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(project.projectName)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(statistics.compact(project.usage.totalTokens))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                ProgressView(value: statistics.projectFraction(project))
                            }
                        }
                    }
                    .font(.caption)
                }

                Text("Token 覆盖")
                    .font(.subheadline.weight(.semibold))
                HStack {
                    Text("\(snapshot.totalSessionCount) 个会话")
                    Spacer()
                    Text(status.tokenCoveragePercentText)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: status.tokenCoverageFraction)
                Text(status.tokenCoverageText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()
                HStack {
                    Button("设置") {
                        page = .settings
                    }
                    Spacer()
                    Button("退出", action: quit)
                }
            }
            .padding(.trailing, SessionNestStatusPopoverLayout.scrollContentTrailingGutter)
        }
        .padding(.trailing, -SessionNestStatusPopoverLayout.scrollViewTrailingExtension)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                page = .overview
            } label: {
                Label("返回", systemImage: "chevron.left")
            }

            Text("主题")
                .font(.title2.weight(.semibold))
            Text("选择 SessionNest 的显示主题。")
                .foregroundStyle(.secondary)

            Picker("主题", selection: $storedTheme) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func quotaRow(title: String, quota: MenuBarQuotaStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Text(quota.remainingText)
                Spacer()
                Text(quota.resetText)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: quota.fraction)
                .tint(quota.color.swiftUIColor)
        }
    }

    private func metricCard(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func tokenTrend(_ statistics: MenuBarStatisticsStatus) -> some View {
        Chart(statistics.dailyPoints) { point in
            LineMark(
                x: .value(
                    "日期",
                    Date(timeIntervalSince1970: TimeInterval(point.dayStart))
                ),
                y: .value("Token", point.usage.totalTokens),
                series: .value("类型", "总 Token")
            )
            .foregroundStyle(Color.accentColor)
            .interpolationMethod(.monotone)

            LineMark(
                x: .value(
                    "日期",
                    Date(timeIntervalSince1970: TimeInterval(point.dayStart))
                ),
                y: .value("Token", point.usage.cachedInputTokens),
                series: .value("类型", "缓存输入")
            )
            .foregroundStyle(Color.orange)
            .interpolationMethod(.monotone)

            if statistics.showsSingleDayTrendMarker {
                PointMark(
                    x: .value(
                        "日期",
                        Date(timeIntervalSince1970: TimeInterval(point.dayStart))
                    ),
                    y: .value("Token", point.usage.totalTokens)
                )
                .foregroundStyle(Color.accentColor)
                .symbolSize(36)

                PointMark(
                    x: .value(
                        "日期",
                        Date(timeIntervalSince1970: TimeInterval(point.dayStart))
                    ),
                    y: .value("Token", point.usage.cachedInputTokens)
                )
                .foregroundStyle(Color.orange)
                .symbolSize(36)
            }
        }
        .chartXAxis(.hidden)
        .frame(height: 130)
        .accessibilityLabel("每日 Token 趋势")
    }

}
