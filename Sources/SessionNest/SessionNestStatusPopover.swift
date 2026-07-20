import Charts
import SwiftUI

enum SessionNestPublicLinkIcon: Equatable {
    case system(String)
    case github
}

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

    var icon: SessionNestPublicLinkIcon {
        switch self {
        case .website: .system("safari")
        case .repository: .github
        }
    }
}

enum SessionNestStatusPopoverHeaderLayout {
    static let buttonDiameter: CGFloat = 30
    static let iconSize: CGFloat = 16
    static let dividerHeight: CGFloat = 18
}

struct RefreshButtonVisualState: Equatable {
    let isVisuallyEnabled = true
    let isAnimating: Bool

    init(isRefreshing: Bool) {
        isAnimating = isRefreshing
    }
}

private struct RefreshHeaderSymbol: View {
    let isAnimating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isAnimating)) { context in
            Image(systemName: "arrow.triangle.2.circlepath")
                .rotationEffect(.degrees(rotationAngle(at: context.date)))
        }
    }

    private func rotationAngle(at date: Date) -> Double {
        guard isAnimating else { return 0 }
        let duration = 0.8
        return date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: duration) / duration * 360
    }
}

private struct StatusPopoverHeaderButton<Label: View>: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void
    let label: Label
    @State private var isHovered = false

    init(
        title: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.title = title
        self.isEnabled = isEnabled
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .frame(
                    width: SessionNestStatusPopoverHeaderLayout.iconSize,
                    height: SessionNestStatusPopoverHeaderLayout.iconSize
                )
        }
        .buttonStyle(StatusPopoverHeaderButtonStyle(isHovered: isHovered))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct StatusPopoverHeaderButtonStyle: ButtonStyle {
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(
                width: SessionNestStatusPopoverHeaderLayout.buttonDiameter,
                height: SessionNestStatusPopoverHeaderLayout.buttonDiameter
            )
            .background {
                Circle()
                    .fill(
                        Color.primary.opacity(
                            configuration.isPressed ? 0.16 : isHovered ? 0.08 : 0
                        )
                    )
            }
            .contentShape(Circle())
    }
}

private struct GitHubMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 98, rect.height / 96)
        let origin = CGPoint(
            x: rect.midX - 49 * scale,
            y: rect.midY - 48 * scale
        )
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }

        var path = Path()
        path.move(to: point(41.4395, 69.3848))
        path.addCurve(
            to: point(19.9062, 46.9902),
            control1: point(28.8066, 67.8535),
            control2: point(19.9062, 58.7617)
        )
        path.addCurve(
            to: point(24.5, 33.5918),
            control1: point(19.9062, 42.2051),
            control2: point(21.6289, 37.0371)
        )
        path.addCurve(
            to: point(24.8828, 20.959),
            control1: point(23.2559, 30.4336),
            control2: point(23.4473, 23.7344)
        )
        path.addCurve(
            to: point(36.9414, 25.2656),
            control1: point(28.7109, 20.4805),
            control2: point(33.8789, 22.4902)
        )
        path.addCurve(
            to: point(49.0957, 23.543),
            control1: point(40.5781, 24.1172),
            control2: point(44.4062, 23.543)
        )
        path.addCurve(
            to: point(61.0586, 25.1699),
            control1: point(53.7852, 23.543),
            control2: point(57.6133, 24.1172)
        )
        path.addCurve(
            to: point(73.1172, 20.959),
            control1: point(64.0254, 22.4902),
            control2: point(69.2891, 20.4805)
        )
        path.addCurve(
            to: point(73.4043, 33.4961),
            control1: point(74.457, 23.543),
            control2: point(74.6484, 30.2422)
        )
        path.addCurve(
            to: point(78.0937, 46.9902),
            control1: point(76.4668, 37.1328),
            control2: point(78.0937, 42.0137)
        )
        path.addCurve(
            to: point(56.3691, 69.2891),
            control1: point(78.0937, 58.7617),
            control2: point(69.1934, 67.6621)
        )
        path.addCurve(
            to: point(61.8242, 81.252),
            control1: point(59.623, 71.3945),
            control2: point(61.8242, 75.9883)
        )
        path.addLine(to: point(61.8242, 91.2051))
        path.addCurve(
            to: point(67.0879, 94.5547),
            control1: point(61.8242, 94.0762),
            control2: point(64.2168, 95.7031)
        )
        path.addCurve(
            to: point(98, 49.1914),
            control1: point(84.4102, 87.9512),
            control2: point(98, 70.6289)
        )
        path.addCurve(
            to: point(48.9043, 0),
            control1: point(98, 22.1074),
            control2: point(75.9883, 0)
        )
        path.addCurve(
            to: point(0, 49.1914),
            control1: point(21.8203, 0),
            control2: point(0, 22.1074)
        )
        path.addCurve(
            to: point(31.6777, 94.6504),
            control1: point(0, 70.4375),
            control2: point(13.4941, 88.0469)
        )
        path.addCurve(
            to: point(36.75, 91.3008),
            control1: point(34.2617, 95.6074),
            control2: point(36.75, 93.8848)
        )
        path.addLine(to: point(36.75, 83.6445))
        path.addCurve(
            to: point(32.1562, 84.6016),
            control1: point(35.4102, 84.2188),
            control2: point(33.6875, 84.6016)
        )
        path.addCurve(
            to: point(19.4277, 74.7441),
            control1: point(25.8398, 84.6016),
            control2: point(22.1074, 81.1563)
        )
        path.addCurve(
            to: point(15.0254, 70.3418),
            control1: point(18.375, 72.1602),
            control2: point(17.2266, 70.6289)
        )
        path.addCurve(
            to: point(13.4941, 69.1934),
            control1: point(13.877, 70.2461),
            control2: point(13.4941, 69.7676)
        )
        path.addCurve(
            to: point(17.3223, 67.1836),
            control1: point(13.4941, 68.0449),
            control2: point(15.4082, 67.1836)
        )
        path.addCurve(
            to: point(24.9785, 72.4473),
            control1: point(20.0977, 67.1836),
            control2: point(22.4902, 68.9063)
        )
        path.addCurve(
            to: point(31.2949, 76.4668),
            control1: point(26.8926, 75.2227),
            control2: point(28.9023, 76.4668)
        )
        path.addCurve(
            to: point(37.4199, 73.4043),
            control1: point(33.6875, 76.4668),
            control2: point(35.2187, 75.6055)
        )
        path.addCurve(
            to: point(41.4395, 69.3848),
            control1: point(39.0469, 71.7773),
            control2: point(40.291, 70.3418)
        )
        path.closeSubpath()
        return path
    }
}

private enum StatusPopoverPage {
    case overview
    case resetCredits
    case settings
}

struct AppUpdateNotice: Equatable {
    let update: AppUpdate
    let title: String
    let summary: String?

    static func resolve(_ state: AppUpdateCheckState) -> Self? {
        guard case .available(let update) = state else { return nil }
        return Self(
            update: update,
            title: "发现新版本 \(update.tagName)",
            summary: update.summary
        )
    }
}

struct AppUpdateSettingsStatus: Equatable {
    let text: String
    let isError: Bool

    static func resolve(_ state: AppUpdateCheckState) -> Self? {
        switch state {
        case .idle:
            nil
        case .checking:
            Self(text: "正在检查更新…", isError: false)
        case .upToDate:
            Self(text: "已是最新版本", isError: false)
        case .available(let update):
            Self(text: "可更新至 \(update.tagName)", isError: false)
        case .failed(let message):
            Self(text: message, isError: true)
        }
    }
}

struct SessionNestStatusPopover: View {
    @ObservedObject var model: SessionListModel
    @ObservedObject var refreshState: StatusItemRefreshState
    @ObservedObject var updateChecker: AppUpdateChecker
    @Environment(\.openURL) private var openURL
    @State private var page = StatusPopoverPage.overview
    @AppStorage("sessionnest.theme") private var storedTheme = AppTheme.system.rawValue
    @AppStorage(SessionNestLaunchPreference.opensMainWindowKey)
    private var opensMainWindowOnLaunch = false
    let refresh: () -> Void
    let openMainWindow: () -> Void
    let quit: () -> Void

    var body: some View {
        Group {
            switch page {
            case .overview:
                overview
            case .resetCredits:
                resetCredits
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
            cycleSnapshot: model.quotaCycleStatisticsSnapshot,
            fallbackSnapshot: model.statisticsSnapshot(for: .sevenDays)
        )
        let snapshot = statisticsScope.snapshot
        let status = MenuBarStatus(
            snapshot: snapshot,
            quotaCycleTokens: model.quotaCycleTokenUsage,
            rateLimits: model.rateLimitSnapshot,
            account: model.accountSnapshot,
            isLoading: model.isLoading,
            isRefreshing: refreshState.isRefreshing || model.isRefreshingUsage
                || model.isScanningTokenUsage
        )
        let statistics = MenuBarStatisticsStatus(
            snapshot: snapshot,
            isScanningTokenUsage: model.isScanningTokenUsage
        )
        let resetCredits = MenuBarResetCreditsStatus(summary: model.resetCreditsSnapshot)
        let refreshButtonState = RefreshButtonVisualState(isRefreshing: status.showsProgress)

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
                    HStack(spacing: 4) {
                        ForEach(SessionNestPublicLink.allCases, id: \.self) { link in
                            StatusPopoverHeaderButton(title: link.title) {
                                openURL(link.url)
                            } label: {
                                publicLinkIcon(link.icon)
                            }
                        }

                        Rectangle()
                            .fill(Color.primary.opacity(0.14))
                            .frame(
                                width: 1,
                                height: SessionNestStatusPopoverHeaderLayout.dividerHeight
                            )
                            .padding(.horizontal, 2)

                        StatusPopoverHeaderButton(
                            title: "刷新",
                            isEnabled: refreshButtonState.isVisuallyEnabled,
                            action: refresh
                        ) {
                            RefreshHeaderSymbol(isAnimating: refreshButtonState.isAnimating)
                        }
                        StatusPopoverHeaderButton(
                            title: "打开 SessionNest",
                            action: openMainWindow
                        ) {
                            Image(systemName: "rectangle.split.2x1")
                        }
                    }
                }

                if let notice = AppUpdateNotice.resolve(updateChecker.state) {
                    updateNoticeBanner(notice)
                }

                Text("配额")
                    .font(.subheadline.weight(.semibold))
                quotaRow(title: "每周", quota: status.weeklyQuota)
                resetCreditsRow(resetCredits)

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

    @ViewBuilder
    private func publicLinkIcon(_ icon: SessionNestPublicLinkIcon) -> some View {
        switch icon {
        case .system(let systemName):
            Image(systemName: systemName)
        case .github:
            GitHubMarkShape()
                .fill(.primary)
        }
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

            Divider()

            Text("启动")
                .font(.title2.weight(.semibold))
            Text("选择启动 SessionNest 时是否显示主窗口。")
                .font(.callout)
                .foregroundStyle(.secondary)

            Toggle("启动时默认打开主窗口", isOn: $opensMainWindowOnLaunch)
            Text("下次启动时生效")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text("更新")
                .font(.title2.weight(.semibold))
            Text("每天最多连接 GitHub 检查一次，不会自动下载或安装应用。")
                .font(.callout)
                .foregroundStyle(.secondary)

            Toggle(
                "每天自动检查更新",
                isOn: Binding(
                    get: { updateChecker.automaticallyChecksForUpdates },
                    set: { isEnabled in
                        updateChecker.setAutomaticChecksEnabled(isEnabled)
                        if isEnabled {
                            Task { await updateChecker.check(.automatic) }
                        }
                    }
                )
            )

            HStack(spacing: 10) {
                Button("立即检查") {
                    Task { await updateChecker.check(.manual) }
                }
                .disabled(updateChecker.state.isChecking)

                if let status = AppUpdateSettingsStatus.resolve(updateChecker.state) {
                    Text(status.text)
                        .font(.caption)
                        .foregroundStyle(status.isError ? Color.red : Color.secondary)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func updateNoticeBanner(_ notice: AppUpdateNotice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(notice.title, systemImage: "arrow.down.circle.fill")
                .font(.subheadline.weight(.semibold))

            if let summary = notice.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                Button("查看更新") {
                    openURL(notice.update.releaseURL)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("忽略此版本") {
                    updateChecker.ignoreAvailableVersion()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            Color.accentColor.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    private var resetCredits: some View {
        let status = MenuBarResetCreditsStatus(summary: model.resetCreditsSnapshot)

        return VStack(alignment: .leading, spacing: 16) {
            Button {
                page = .overview
            } label: {
                Label("返回", systemImage: "chevron.left")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("额度重置卡")
                    .font(.title2.weight(.semibold))
                Text(status.summaryText)
                    .foregroundStyle(.secondary)
            }

            if status.availableCredits.isEmpty {
                ContentUnavailableView(
                    status.isKnown ? "暂无可用重置卡" : "重置卡信息暂不可用",
                    systemImage: "arrow.counterclockwise.circle",
                    description: Text(status.expirationText)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(status.availableCredits) { credit in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Label("完整重置", systemImage: "arrow.counterclockwise.circle.fill")
                                        .font(.headline)
                                    Spacer()
                                    Text("可用")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.green)
                                }
                                Text("\(status.fullExpirationText(for: credit)) 到期")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Text(credit.description)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(
                                Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                        }
                    }
                }
            }
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

    private func resetCreditsRow(_ status: MenuBarResetCreditsStatus) -> some View {
        Button {
            page = .resetCredits
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.counterclockwise.circle")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.summaryText)
                    Text(status.expirationText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(status.summaryText)，\(status.expirationText)")
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
        TokenTrendChart(points: statistics.dailyPoints, presentation: .popover)
    }

}
