import AppKit
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

    init(isRefreshing: Bool, isVisible: Bool = true) {
        // 弹框隐藏后停止刷新图标动画，避免保留的 hosting view 持续唤醒主线程。
        isAnimating = isRefreshing && isVisible
    }
}

enum StatusPopoverScreenshotFeedback: Equatable {
    case idle
    case safeCopied
    case fullCopied
    case failed

    var systemImage: String {
        switch self {
        case .idle: "camera"
        case .safeCopied, .fullCopied: "checkmark"
        case .failed: "exclamationmark.triangle"
        }
    }

    var title: String {
        switch self {
        case .idle: "复制安全截图（已隐藏账号；右键可复制完整截图）"
        case .safeCopied: "安全截图已复制，账号信息已隐藏"
        case .fullCopied: "完整截图已复制，包含账号信息"
        case .failed: "截图失败，请重试"
        }
    }

    var errorText: String? {
        self == .failed ? title : nil
    }

    var feedbackText: String? {
        self == .idle ? nil : title
    }
}

enum StatusPopoverScreenshotPrivacy: Equatable {
    case safe
    case full

    func emailText(_ email: String) -> String {
        switch self {
        case .safe:
            email == "--" ? email : "账号已隐藏"
        case .full:
            email
        }
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

enum SessionNestDiagnosticCopyFeedback: Equatable {
    case idle
    case copied
    case failed

    var title: String {
        switch self {
        case .idle: "复制脱敏诊断"
        case .copied: "脱敏诊断已复制"
        case .failed: "复制失败，请重试"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "doc.on.doc"
        case .copied: "checkmark"
        case .failed: "exclamationmark.triangle"
        }
    }
}

struct SessionNestDiagnosticReport: Equatable {
    let text: String

    init(
        generatedAt: Date,
        appVersion: String,
        appBuild: String,
        operatingSystemVersion: String,
        timeZoneIdentifier: String,
        coverage: TokenCoverageBreakdown,
        diagnostics: TokenScanDiagnostics?,
        anomaly: TokenUsageAnomaly?
    ) {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "SessionNest redacted diagnostics",
            "generated_at=\(formatter.string(from: generatedAt))",
            "app_version=\(appVersion)",
            "app_build=\(appBuild)",
            "operating_system=\(operatingSystemVersion)",
            "time_zone=\(timeZoneIdentifier)",
            "privacy=excludes account, session title, session id, directory path, and log content",
            "",
            "[token_statistics]",
            "coverage.total_sessions=\(coverage.totalSessionCount)",
            "coverage.measured_sessions=\(coverage.measuredSessionCount)",
            "coverage.missing_log_sessions=\(coverage.missingLogSessionCount)",
            "coverage.empty_log_sessions=\(coverage.emptyLogSessionCount)",
            "coverage.stale_log_sessions=\(coverage.staleLogSessionCount)",
            "coverage.failed_log_sessions=\(coverage.failedLogSessionCount)",
            "anomaly=\(Self.anomalyText(anomaly))",
            "",
            "[latest_scan]",
        ]

        if let diagnostics {
            lines += [
                "scan.status=available",
                "scan.completed_at=\(formatter.string(from: diagnostics.completedAt))",
                "scan.duration_ms=\(Int((max(0, diagnostics.duration) * 1_000).rounded()))",
                "scan.discovery.enumerated_files=\(diagnostics.discoveryEnumeratedFileCount)",
                "scan.discovery.cache_hits=\(diagnostics.discoveryCacheHitCount)",
                "scan.discovery.read_files=\(diagnostics.discoveryReadFileCount)",
                "scan.discovery.read_bytes=\(diagnostics.discoveryReadBytes)",
                "scan.discovery.failed_reads=\(diagnostics.discoveryFailedReadCount)",
                "scan.discovery.cache_store_failed=\(diagnostics.discoveryCacheStoreFailed)",
                "scan.token.targets=\(diagnostics.targetCount)",
                "scan.token.cache_reuses=\(diagnostics.tokenCacheReuseCount)",
                "scan.token.read_files=\(diagnostics.tokenReadFileCount)",
                "scan.token.read_bytes=\(diagnostics.tokenReadBytes)",
                "scan.token.duplicate_checkpoints=\(diagnostics.duplicateTokenCheckpointCount)",
                "scan.token.reconciliations=\(diagnostics.tokenReconciliationCount)",
                "scan.token.failed_targets=\(diagnostics.failedTargetCount)",
                "scan.token.pruned_timed_rows=\(diagnostics.prunedTimedRowCount)",
            ]
        } else {
            lines.append("scan.status=unavailable")
        }
        text = lines.joined(separator: "\n")
    }

    private static func anomalyText(_ anomaly: TokenUsageAnomaly?) -> String {
        switch anomaly {
        case .none:
            "none"
        case .some(.droppedToZero(let previous)):
            "dropped_to_zero previous_total_tokens=\(previous)"
        case .some(.doubled(let previous, let current)):
            "doubled previous_total_tokens=\(previous) current_total_tokens=\(current)"
        }
    }
}

@MainActor
struct SessionNestDiagnosticReportCopier {
    func copy(
        _ report: String,
        pasteboard: NSPasteboard = .general
    ) -> Bool {
        // 复用截图的事务式剪贴板替换，失败时恢复原有的全部项目与类型。
        StatusPopoverScreenshotCopier.replaceClipboard(
            with: report,
            pasteboard: pasteboard
        )
    }

    func copy(
        _ report: String,
        writeString: (String) -> Bool
    ) -> Bool {
        writeString(report)
    }
}

struct SessionNestStatusPopover: View {
    @ObservedObject var model: SessionListModel
    @ObservedObject var refreshState: StatusItemRefreshState
    @ObservedObject var updateChecker: AppUpdateChecker
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var page = StatusPopoverPage.overview
    @State private var screenshotFeedback = StatusPopoverScreenshotFeedback.idle
    @State private var diagnosticCopyFeedback = SessionNestDiagnosticCopyFeedback.idle
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
        ScrollView(.vertical) {
            overviewContent(includesScreenshotAction: true, screenshotPrivacy: nil)
                .padding(.trailing, SessionNestStatusPopoverLayout.scrollContentTrailingGutter)
        }
        .scrollIndicators(.visible)
        .padding(.trailing, -SessionNestStatusPopoverLayout.scrollViewTrailingExtension)
    }

    private func overviewContent(
        includesScreenshotAction: Bool,
        screenshotPrivacy: StatusPopoverScreenshotPrivacy?
    ) -> some View {
        let now = Int64(Date().timeIntervalSince1970)
        let calendar = Calendar.current
        let statisticsScope = StatusPopoverStatisticsScope.resolve(
            cycleSnapshot: model.quotaCycleStatisticsSnapshot,
            fallbackSnapshot: model.statisticsSnapshot(for: .sevenDays)
        )
        let dailyTokenStartingAt = model.quotaCycleStatisticsSnapshot.flatMap { _ in
            QuotaCycleWindow.startTimestamp(window: model.rateLimitSnapshot?.weeklyWindow)
        }
        let snapshot = statisticsScope.snapshot
        let status = MenuBarStatus(
            snapshot: snapshot,
            quotaCycleTokens: model.quotaCycleTokenUsage,
            rateLimits: model.rateLimitSnapshot,
            account: model.accountSnapshot,
            isLoading: model.isLoading,
            isRefreshing: refreshState.isRefreshing || model.isRefreshingUsage
                || model.isScanningTokenUsage,
            now: now
        )
        let statistics = MenuBarStatisticsStatus(
            snapshot: snapshot,
            isScanningTokenUsage: model.isScanningTokenUsage
        )
        let tokenCoverage = TokenCoverageStatus(
            breakdown: model.tokenCoverageBreakdown(for: snapshot),
            health: model.tokenScanHealth,
            isScanning: model.isScanningTokenUsage
        )
        let resetCredits = MenuBarResetCreditsStatus(summary: model.resetCreditsSnapshot)
        let refreshButtonState = RefreshButtonVisualState(
            isRefreshing: status.showsProgress,
            isVisible: refreshState.isPopoverShown
        )

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SessionNest")
                        .font(.headline)
                    HStack(spacing: 4) {
                        Text(status.account.planText)
                        Text(
                            screenshotPrivacy?.emailText(status.account.emailText)
                                ?? status.account.emailText
                        )
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

                    if includesScreenshotAction {
                        StatusPopoverHeaderButton(
                            title: screenshotFeedback.title,
                            action: { copyOverview(privacy: .safe) }
                        ) {
                            Image(systemName: screenshotFeedback.systemImage)
                        }
                        .contextMenu {
                            Button("复制完整截图（包含账号信息）") {
                                copyOverview(privacy: .full)
                            }
                        }
                    }
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

            if includesScreenshotAction, let feedbackText = screenshotFeedback.feedbackText {
                Text(feedbackText)
                    .font(.caption)
                    .foregroundStyle(screenshotFeedback == .failed ? Color.red : Color.secondary)
            }

            if let notice = AppUpdateNotice.resolve(updateChecker.state) {
                updateNoticeBanner(notice)
            }

            Text("配额")
                .font(.subheadline.weight(.semibold))
            quotaRow(
                title: "每周",
                quota: status.weeklyQuota,
                usesPlatformProgress: includesScreenshotAction
            )

            Text(statisticsScope.title)
                .font(.subheadline.weight(.semibold))
            if statistics.showsTokenScanProgress {
                HStack(spacing: 6) {
                    if includesScreenshotAction {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                    Text("正在统计 Token…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    metricCard(
                        title: "总 Token",
                        value: statistics.totalTokenValueText,
                        detail: statistics.totalTokenDetailText
                    )
                    metricCard(
                        title: "非缓存 Token",
                        value: statistics.nonCachedTokenValueText,
                        detail: statistics.nonCachedTokenDetailText
                    )
                }
                HStack(spacing: 10) {
                    metricCard(
                        title: "会话",
                        value: statistics.sessionValueText,
                        detail: statistics.sessionDetailText
                    )
                    metricCard(
                        title: "平均 / 会话",
                        value: statistics.averageValueText,
                        detail: statistics.averageDetailText
                    )
                }
            }

            Text(statisticsScope.dailyTokenTitle)
                .font(.subheadline.weight(.semibold))
            DailyTokenUsageChart(
                points: statistics.dailyPoints,
                startingAt: dailyTokenStartingAt,
                now: now,
                calendar: calendar
            )
            resetCreditsRow(resetCredits)

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
                            overviewProgressBar(
                                value: statistics.projectFraction(project),
                                tint: .accentColor,
                                usesPlatformProgress: includesScreenshotAction
                            )
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
            overviewProgressBar(
                value: status.tokenCoverageFraction,
                tint: .accentColor,
                usesPlatformProgress: includesScreenshotAction
            )
            Text(status.tokenCoverageText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(tokenCoverage.noticeText)
                .font(.caption)
                .foregroundStyle(tokenCoverage.isWarning ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let anomaly = model.tokenUsageAnomaly {
                Label(anomaly.noticeText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Button("设置") {
                    page = .settings
                }
                Spacer()
                Button("退出", action: quit)
            }
        }
    }

    private func screenshotOverview(privacy: StatusPopoverScreenshotPrivacy) -> some View {
        let theme = AppTheme(storedValue: storedTheme)
        let colorScheme = StatusPopoverScreenshotBackground.colorScheme(
            for: theme,
            systemColorScheme: systemColorScheme
        )

        return overviewContent(
            includesScreenshotAction: false,
            screenshotPrivacy: privacy
        )
        .padding(.trailing, SessionNestStatusPopoverLayout.scrollContentTrailingGutter)
        .padding(16)
        .frame(width: SessionNestStatusPopoverLayout.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(StatusPopoverScreenshotBackground.color(for: colorScheme))
        .environment(\.colorScheme, colorScheme)
    }

    @MainActor
    private func copyOverview(privacy: StatusPopoverScreenshotPrivacy) {
        do {
            try StatusPopoverScreenshotCopier().copy(
                content: screenshotOverview(privacy: privacy)
            )
            screenshotFeedback = privacy == .safe ? .safeCopied : .fullCopied
        } catch {
            screenshotFeedback = .failed
        }
        let feedback = screenshotFeedback
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if screenshotFeedback == feedback {
                screenshotFeedback = .idle
            }
        }
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
        VStack(alignment: .leading, spacing: 12) {
            Button {
                // 返回概览时沿用同一弹框，不额外创建窗口。
                page = .overview
            } label: {
                Label("返回", systemImage: "chevron.left")
            }

            // 仅设置内容滚动，让返回入口始终固定在弹框顶部。
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {

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
                                // 保存用户选择，让下次启动继续采用相同更新策略。
                                updateChecker.setAutomaticChecksEnabled(isEnabled)
                            }
                        )
                    )

                    HStack(spacing: 10) {
                        Button("立即检查") {
                            // 手动检查不等待其他设置交互，异步更新现有状态提示。
                            Task { await updateChecker.check(.manual) }
                        }
                        .disabled(updateChecker.state.isChecking)

                        if let status = AppUpdateSettingsStatus.resolve(updateChecker.state) {
                            Text(status.text)
                                .font(.caption)
                                .foregroundStyle(status.isError ? Color.red : Color.secondary)
                        }
                    }

                    Divider()

                    scanDiagnosticsSection
                }
                // 为滚动条保留与概览页相同的尾部间距，避免文字被遮挡。
                .padding(.trailing, SessionNestStatusPopoverLayout.scrollContentTrailingGutter)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.visible)
            // 把滚动条移到弹框边缘，同时保留内容自身的安全间距。
            .padding(.trailing, -SessionNestStatusPopoverLayout.scrollViewTrailingExtension)
        }
    }

    private var scanDiagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("扫描诊断")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    copyDiagnosticReport()
                } label: {
                    Label(
                        diagnosticCopyFeedback.title,
                        systemImage: diagnosticCopyFeedback.systemImage
                    )
                }
            }

            if let diagnostics = model.tokenScanDiagnostics {
                LabeledContent("最近完成") {
                    Text(
                        diagnostics.completedAt,
                        format: .dateTime
                            .year().month().day()
                            .hour().minute().second()
                    )
                    .monospacedDigit()
                }
                diagnosticRow(
                    title: "扫描耗时",
                    value: diagnosticDuration(diagnostics.duration)
                )
                diagnosticRow(
                    title: "发现索引命中",
                    value:
                        "\(diagnostics.discoveryCacheHitCount) / "
                        + "\(diagnostics.discoveryEnumeratedFileCount)"
                )
                diagnosticRow(
                    title: "发现实际读取",
                    value:
                        "\(diagnostics.discoveryReadFileCount) 个 · "
                        + diagnosticByteCount(diagnostics.discoveryReadBytes)
                )
                diagnosticRow(
                    title: "发现读取失败",
                    value: "\(diagnostics.discoveryFailedReadCount) 个"
                )
                diagnosticRow(
                    title: "索引存储",
                    value: diagnostics.discoveryCacheStoreFailed ? "失败，将在下次重试" : "正常"
                )
                diagnosticRow(
                    title: "Token 缓存复用",
                    value:
                        "\(diagnostics.tokenCacheReuseCount) / "
                        + "\(diagnostics.targetCount) 个目标"
                )
                diagnosticRow(
                    title: "Token 实际读取",
                    value:
                        "\(diagnostics.tokenReadFileCount) 个 · "
                        + diagnosticByteCount(diagnostics.tokenReadBytes)
                )
                diagnosticRow(
                    title: "重复检查点去重",
                    value: "\(diagnostics.duplicateTokenCheckpointCount) 个"
                )
                diagnosticRow(
                    title: "原始日志对账",
                    value: "\(diagnostics.tokenReconciliationCount) 个"
                )
                diagnosticRow(
                    title: "扫描失败",
                    value: "\(diagnostics.failedTargetCount) 个"
                )
                diagnosticRow(
                    title: "清理细粒度明细",
                    value: "\(diagnostics.prunedTimedRowCount) 行"
                )
            } else {
                Text("尚无完整扫描记录")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("复制内容不含账号、会话标题、会话 ID、目录路径或日志内容")
                Text("细粒度明细保留最近 30 天，日汇总长期保留")
                Text("低电量模式自动会话扫描最多每小时一次，手动刷新不受影响")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    @MainActor
    private func copyDiagnosticReport() {
        let bundle = Bundle.main
        let snapshot = model.statisticsSnapshot(for: .all)
        let report = SessionNestDiagnosticReport(
            generatedAt: Date(),
            appVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "unknown",
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            timeZoneIdentifier: Calendar.current.timeZone.identifier,
            coverage: model.tokenCoverageBreakdown(for: snapshot),
            diagnostics: model.tokenScanDiagnostics,
            anomaly: model.tokenUsageAnomaly
        )
        diagnosticCopyFeedback =
            SessionNestDiagnosticReportCopier().copy(report.text) ? .copied : .failed

        let feedback = diagnosticCopyFeedback
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if diagnosticCopyFeedback == feedback {
                diagnosticCopyFeedback = .idle
            }
        }
    }

    private func diagnosticRow(title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func diagnosticDuration(_ duration: TimeInterval) -> String {
        // 防御异常负值，避免诊断界面出现无意义的负耗时。
        let duration = max(0, duration)
        if duration < 1 {
            // 小于一秒时用毫秒显示，方便观察缓存命中后的短扫描。
            return "\(Int((duration * 1_000).rounded())) 毫秒"
        }
        // 较长扫描保留一位小数，在紧凑弹框内兼顾精度和可读性。
        let seconds = duration.formatted(.number.precision(.fractionLength(1)))
        return "\(seconds) 秒"
    }

    private func diagnosticByteCount(_ bytes: Int64) -> String {
        // 防御异常负值，并用系统文件大小格式适配 KB、MB 与 GB。
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
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
                ScrollView(.vertical) {
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
                    .padding(.trailing, SessionNestStatusPopoverLayout.scrollContentTrailingGutter)
                }
                .scrollIndicators(.visible)
                .padding(.trailing, -SessionNestStatusPopoverLayout.scrollViewTrailingExtension)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func quotaRow(
        title: String,
        quota: MenuBarQuotaStatus,
        usesPlatformProgress: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Text(quota.remainingText)
                Spacer()
                Text(quota.resetText)
                    .foregroundStyle(.secondary)
            }
            overviewProgressBar(
                value: quota.fraction,
                tint: quota.color.swiftUIColor,
                usesPlatformProgress: usesPlatformProgress
            )
        }
    }

    @ViewBuilder
    private func overviewProgressBar(
        value: Double,
        tint: Color,
        usesPlatformProgress: Bool
    ) -> some View {
        if usesPlatformProgress {
            ProgressView(value: value)
                .tint(tint)
        } else {
            StatusPopoverScreenshotProgressBar(value: value, tint: tint)
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
