import AppKit
import Foundation
import Testing

@testable import SessionNest

@Test func publicLinksUseApprovedDestinationsAndSymbols() {
    #expect(SessionNestPublicLink.website.url.absoluteString == "https://www.nemoob.cn/")
    #expect(SessionNestPublicLink.website.icon == .system("safari"))
    #expect(
        SessionNestPublicLink.repository.url.absoluteString
            == "https://github.com/nemoob/sessionnest"
    )
    #expect(SessionNestPublicLink.repository.icon == .github)
    #expect(SessionNestStatusPopoverHeaderLayout.buttonDiameter == 30)
    #expect(SessionNestStatusPopoverHeaderLayout.iconSize == 16)
    #expect(SessionNestStatusPopoverHeaderLayout.dividerHeight == 18)
}

@Test func refreshButtonStaysVisuallyEnabledWhileAnimating() {
    let idle = RefreshButtonVisualState(isRefreshing: false)
    let refreshing = RefreshButtonVisualState(isRefreshing: true)
    let hidden = RefreshButtonVisualState(isRefreshing: true, isVisible: false)

    #expect(idle.isVisuallyEnabled)
    #expect(!idle.isAnimating)
    #expect(refreshing.isVisuallyEnabled)
    #expect(refreshing.isAnimating)
    #expect(hidden.isVisuallyEnabled)
    #expect(!hidden.isAnimating)
}

@Test func screenshotFeedbackUsesClearClipboardMessagesAndSymbols() {
    #expect(StatusPopoverScreenshotFeedback.idle.systemImage == "camera")
    #expect(
        StatusPopoverScreenshotFeedback.idle.title
            == "复制安全截图（已隐藏账号；右键可复制完整截图）"
    )
    #expect(StatusPopoverScreenshotFeedback.safeCopied.systemImage == "checkmark")
    #expect(
        StatusPopoverScreenshotFeedback.safeCopied.title
            == "安全截图已复制，账号信息已隐藏"
    )
    #expect(
        StatusPopoverScreenshotFeedback.safeCopied.feedbackText
            == "安全截图已复制，账号信息已隐藏"
    )
    #expect(StatusPopoverScreenshotFeedback.fullCopied.systemImage == "checkmark")
    #expect(
        StatusPopoverScreenshotFeedback.fullCopied.title
            == "完整截图已复制，包含账号信息"
    )
    #expect(
        StatusPopoverScreenshotFeedback.failed.systemImage
            == "exclamationmark.triangle"
    )
    #expect(StatusPopoverScreenshotFeedback.failed.errorText == "截图失败，请重试")
    #expect(StatusPopoverScreenshotFeedback.idle.feedbackText == nil)
}

@Test func safeScreenshotHidesAccountWithoutChangingThePopoverAccountText() {
    let email = "person@example.com"

    #expect(StatusPopoverScreenshotPrivacy.safe.emailText(email) == "账号已隐藏")
    #expect(StatusPopoverScreenshotPrivacy.full.emailText(email) == email)
    #expect(StatusPopoverScreenshotPrivacy.safe.emailText("--") == "--")
}

@Test func redactedDiagnosticReportContainsOnlyShareableCountsAndEnvironment() {
    let coverage = TokenCoverageBreakdown(
        totalSessionCount: 10,
        measuredSessionCount: 6,
        missingLogSessionCount: 1,
        emptyLogSessionCount: 1,
        staleLogSessionCount: 1,
        failedLogSessionCount: 1
    )
    let diagnostics = TokenScanDiagnostics(
        completedAt: Date(timeIntervalSince1970: 1_720_000_001),
        duration: 0.125,
        discoveryEnumeratedFileCount: 12,
        discoveryCacheHitCount: 9,
        discoveryReadFileCount: 3,
        discoveryReadBytes: 4_096,
        discoveryFailedReadCount: 1,
        discoveryCacheStoreFailed: false,
        targetCount: 8,
        tokenCacheReuseCount: 6,
        tokenReadFileCount: 2,
        tokenReadBytes: 8_192,
        duplicateTokenCheckpointCount: 4,
        tokenReconciliationCount: 1,
        failedTargetCount: 1,
        prunedTimedRowCount: 7
    )
    let report = SessionNestDiagnosticReport(
        generatedAt: Date(timeIntervalSince1970: 1_720_000_000),
        appVersion: "0.2.28",
        appBuild: "28",
        operatingSystemVersion: "macOS 15.5 (Build 24F74)",
        timeZoneIdentifier: "Asia/Shanghai",
        coverage: coverage,
        diagnostics: diagnostics,
        anomaly: .doubled(previous: 100_000, current: 200_000)
    ).text

    #expect(report.contains("app_version=0.2.28"))
    #expect(report.contains("time_zone=Asia/Shanghai"))
    #expect(report.contains("coverage.measured_sessions=6"))
    #expect(report.contains("coverage.failed_log_sessions=1"))
    #expect(report.contains("scan.duration_ms=125"))
    #expect(report.contains("scan.token.duplicate_checkpoints=4"))
    #expect(
        report.contains(
            "anomaly=doubled previous_total_tokens=100000 current_total_tokens=200000"
        )
    )
    #expect(
        report.contains(
            "privacy=excludes account, session title, session id, directory path, and log content"
        )
    )
    #expect(!report.contains("/Users/"))
    #expect(!report.contains("@example.com"))
    #expect(!report.contains("thread_id"))
}

@Test func redactedDiagnosticReportExplainsMissingScanWithoutInventingCounts() {
    let report = SessionNestDiagnosticReport(
        generatedAt: Date(timeIntervalSince1970: 1_720_000_000),
        appVersion: "0.2.28",
        appBuild: "28",
        operatingSystemVersion: "macOS 15.5",
        timeZoneIdentifier: "UTC",
        coverage: TokenCoverageBreakdown(
            totalSessionCount: 0,
            measuredSessionCount: 0,
            missingLogSessionCount: 0,
            emptyLogSessionCount: 0,
            staleLogSessionCount: 0,
            failedLogSessionCount: 0
        ),
        diagnostics: nil,
        anomaly: nil
    ).text

    #expect(report.contains("scan.status=unavailable"))
    #expect(report.contains("anomaly=none"))
    #expect(!report.contains("scan.token.targets="))
}

@MainActor
@Test func diagnosticReportCopierWritesExactTextAndReportsFailure() {
    let copier = SessionNestDiagnosticReportCopier()
    var copiedText: String?

    #expect(
        copier.copy(
            "safe report",
            writeString: { text in
                copiedText = text
                return true
            })
    )
    #expect(copiedText == "safe report")
    #expect(!copier.copy("safe report", writeString: { _ in false }))
    #expect(SessionNestDiagnosticCopyFeedback.idle.title == "复制脱敏诊断")
    #expect(SessionNestDiagnosticCopyFeedback.copied.title == "脱敏诊断已复制")
    #expect(SessionNestDiagnosticCopyFeedback.failed.title == "复制失败，请重试")
}

@MainActor
@Test func diagnosticReportCopierReplacesClipboardAfterPreservingReadableTypes() {
    let pasteboard = NSPasteboard(name: .init("cn.nemoob.sessionnest.diagnostic-copy-test"))
    pasteboard.clearContents()
    let previousItem = NSPasteboardItem()
    let customType = NSPasteboard.PasteboardType("cn.nemoob.sessionnest.test")
    #expect(previousItem.setString("旧文本", forType: .string))
    #expect(previousItem.setData(Data([0x01, 0x02]), forType: customType))
    #expect(pasteboard.writeObjects([previousItem]))

    #expect(
        SessionNestDiagnosticReportCopier().copy(
            "safe report",
            pasteboard: pasteboard
        )
    )
    #expect(pasteboard.string(forType: .string) == "safe report")
    #expect(pasteboard.data(forType: customType) == nil)
}

@Test func updateNoticeAppearsOnlyForAvailableRelease() {
    let update = AppUpdate(
        version: AppVersion(tag: "0.2.4")!,
        tagName: "v0.2.4",
        releaseURL: URL(
            string: "https://github.com/nemoob/sessionnest/releases/tag/v0.2.4"
        )!,
        summary: "每天自动检查更新"
    )

    #expect(AppUpdateNotice.resolve(.available(update))?.title == "发现新版本 v0.2.4")
    #expect(AppUpdateNotice.resolve(.available(update))?.summary == "每天自动检查更新")
    #expect(AppUpdateNotice.resolve(.upToDate) == nil)
    #expect(AppUpdateNotice.resolve(.idle) == nil)
}

@Test func updateSettingsStatusExplainsManualCheckResults() {
    let update = AppUpdate(
        version: AppVersion(tag: "0.2.4")!,
        tagName: "v0.2.4",
        releaseURL: URL(
            string: "https://github.com/nemoob/sessionnest/releases/tag/v0.2.4"
        )!,
        summary: nil
    )

    #expect(AppUpdateSettingsStatus.resolve(.idle) == nil)
    #expect(AppUpdateSettingsStatus.resolve(.checking)?.text == "正在检查更新…")
    #expect(AppUpdateSettingsStatus.resolve(.upToDate)?.text == "已是最新版本")
    #expect(AppUpdateSettingsStatus.resolve(.available(update))?.text == "可更新至 v0.2.4")
    #expect(AppUpdateSettingsStatus.resolve(.failed("网络不可用"))?.text == "网络不可用")
    #expect(AppUpdateSettingsStatus.resolve(.failed("网络不可用"))?.isError == true)
}

@Test func statusItemClickRoutesLeftAndRightMouseButtons() {
    #expect(StatusItemClickAction.resolve(eventType: .leftMouseUp) == .togglePopover)
    #expect(StatusItemClickAction.resolve(eventType: .rightMouseUp) == .showMenu)
    #expect(StatusItemClickAction.resolve(eventType: nil) == .togglePopover)
}

@Test func statusPopoverClickPolicyClosesOnlyOutsideTargets() {
    let popoverWindowNumber = 11
    let statusItemWindowNumber = 22

    #expect(
        !StatusPopoverClickPolicy.shouldClose(
            eventWindowNumber: popoverWindowNumber,
            popoverWindowNumber: popoverWindowNumber,
            statusItemWindowNumber: statusItemWindowNumber
        )
    )
    #expect(
        !StatusPopoverClickPolicy.shouldClose(
            eventWindowNumber: statusItemWindowNumber,
            popoverWindowNumber: popoverWindowNumber,
            statusItemWindowNumber: statusItemWindowNumber
        )
    )
    #expect(
        StatusPopoverClickPolicy.shouldClose(
            eventWindowNumber: 33,
            popoverWindowNumber: popoverWindowNumber,
            statusItemWindowNumber: statusItemWindowNumber
        )
    )
    #expect(
        StatusPopoverClickPolicy.shouldClose(
            eventWindowNumber: nil,
            popoverWindowNumber: popoverWindowNumber,
            statusItemWindowNumber: statusItemWindowNumber
        )
    )
}

@MainActor
@Test func statusItemViewStateTracksPopoverSelection() {
    let state = StatusItemRefreshState()

    #expect(!state.isPopoverShown)

    state.prepareForPopoverPresentation()

    #expect(state.isPopoverShown)
    #expect(SessionNestStatusLabelLayout.selectedBackgroundWhiteLevel == 0.23)
    #expect(SessionNestStatusLabelLayout.selectedBackgroundCornerRadius == 6)
}

@Test func statusPopoverUsesComfortableSharedDimensions() {
    #expect(SessionNestStatusPopoverLayout.width == 440)
    #expect(SessionNestStatusPopoverLayout.height == 620)
    #expect(SessionNestStatusPopoverLayout.scrollContentTrailingGutter == 8)
    #expect(SessionNestStatusPopoverLayout.scrollViewTrailingExtension == 8)
    #expect(
        SessionNestStatusPopoverLayout.scrollViewTrailingExtension
            == SessionNestStatusPopoverLayout.scrollContentTrailingGutter
    )
}

@Test func compactQuotaRingKeepsSmallRemainingGapVisible() {
    #expect(SessionNestStatusLabelLayout.ringLineWidth == 4)
    #expect(SessionNestStatusLabelLayout.ringLineCap == .butt)
}

@Test func quotaRefreshScheduleAdaptsToForegroundAndPowerState() {
    let foreground = SessionNestQuotaRefreshSchedule.interval(
        isForeground: true,
        isLowPowerModeEnabled: false
    )
    let foregroundLowPower = SessionNestQuotaRefreshSchedule.interval(
        isForeground: true,
        isLowPowerModeEnabled: true
    )
    let background = SessionNestQuotaRefreshSchedule.interval(
        isForeground: false,
        isLowPowerModeEnabled: false
    )
    let backgroundLowPower = SessionNestQuotaRefreshSchedule.interval(
        isForeground: false,
        isLowPowerModeEnabled: true
    )

    #expect(foreground == 10 * 60)
    #expect(foregroundLowPower == 30 * 60)
    #expect(background == 30 * 60)
    #expect(backgroundLowPower == 60 * 60)
    #expect(SessionNestQuotaRefreshSchedule.tolerance(for: foreground) == 60)
    #expect(SessionNestQuotaRefreshSchedule.tolerance(for: backgroundLowPower) == 6 * 60)
}

@Test func quotaRefreshScheduleKeepsDeadlineAcrossEnvironmentChanges() {
    let now = Date(timeIntervalSinceReferenceDate: 10_000)
    let lastRefresh = now.addingTimeInterval(-5 * 60)

    #expect(
        SessionNestQuotaRefreshSchedule.nextFireDate(
            now: now,
            freshnessReference: lastRefresh,
            interval: 10 * 60
        ) == lastRefresh.addingTimeInterval(10 * 60)
    )
    #expect(
        SessionNestQuotaRefreshSchedule.nextFireDate(
            now: now,
            freshnessReference: now.addingTimeInterval(-31 * 60),
            interval: 30 * 60
        ) == now
    )
    #expect(
        SessionNestQuotaRefreshSchedule.nextFireDate(
            now: now,
            freshnessReference: nil,
            interval: 30 * 60
        ) == now.addingTimeInterval(30 * 60)
    )
    #expect(
        SessionNestQuotaRefreshSchedule.nextFireDate(
            now: now,
            freshnessReference: now.addingTimeInterval(60),
            interval: 30 * 60
        ) == now.addingTimeInterval(30 * 60)
    )
}

@Test func quotaRefreshScheduleTreatsOnlyVisibleForegroundInterfaceAsForeground() {
    #expect(
        SessionNestQuotaRefreshSchedule.isForeground(
            isApplicationActive: true,
            isMainWindowVisible: true,
            isPopoverVisible: false
        ))
    #expect(
        SessionNestQuotaRefreshSchedule.isForeground(
            isApplicationActive: false,
            isMainWindowVisible: false,
            isPopoverVisible: true
        ))
    #expect(
        !SessionNestQuotaRefreshSchedule.isForeground(
            isApplicationActive: false,
            isMainWindowVisible: true,
            isPopoverVisible: false
        ))
    #expect(
        !SessionNestQuotaRefreshSchedule.isForeground(
            isApplicationActive: true,
            isMainWindowVisible: false,
            isPopoverVisible: false
        ))
}

@Test func automaticQuotaRefreshPolicyExtendsMaximumAgeOnlyInLowPowerMode() {
    // 正常供电时保持既有十分钟额度有效期，不提高后台请求频率。
    #expect(
        SessionNestAutomaticQuotaRefreshPolicy.maximumAge(isLowPowerModeEnabled: false)
            == 10 * 60
    )
    // 低电量模式把实际额度请求间隔放宽到三十分钟。
    #expect(
        SessionNestAutomaticQuotaRefreshPolicy.maximumAge(isLowPowerModeEnabled: true)
            == 30 * 60
    )
}

@Test func automaticQuotaRefreshPolicySkipsOnlyWhileFullLoadIsRunning() {
    // 完整加载期间应由 reload 统一读取额度，定时器不得重复请求。
    #expect(!SessionNestAutomaticQuotaRefreshPolicy.shouldRefresh(isLoading: true))
    // 加载完成后允许既有定时器按快照有效期决定是否刷新。
    #expect(SessionNestAutomaticQuotaRefreshPolicy.shouldRefresh(isLoading: false))
}

@Test func statusPopoverStatisticsScopePrefersQuotaCycleAndLabelsFallback() {
    let cycle = StatisticsSnapshot(
        totalUsage: .zero,
        totalSessionCount: 1,
        measuredSessionCount: 0,
        averageTokensPerMeasuredSession: 0,
        dailyPoints: [],
        projectRows: [],
        sessionRows: []
    )
    let fallback = StatisticsSnapshot(
        totalUsage: .zero,
        totalSessionCount: 7,
        measuredSessionCount: 0,
        averageTokensPerMeasuredSession: 0,
        dailyPoints: [],
        projectRows: [],
        sessionRows: []
    )

    let current = StatusPopoverStatisticsScope.resolve(
        cycleSnapshot: cycle,
        fallbackSnapshot: fallback
    )
    let missing = StatusPopoverStatisticsScope.resolve(
        cycleSnapshot: nil,
        fallbackSnapshot: fallback
    )

    #expect(current.snapshot == cycle)
    #expect(current.title == "统计概览 · 本额度周期")
    #expect(current.dailyTokenTitle == "本周期每日 Token")
    #expect(missing.snapshot == fallback)
    #expect(missing.title == "统计概览 · 最近 7 天")
    #expect(missing.dailyTokenTitle == "最近 7 天每日 Token")
}

@Test func compactStatusLayoutFitsOneHundredPercentQuota() {
    let font = NSFont.monospacedDigitSystemFont(
        ofSize: SessionNestStatusLabelLayout.fontSize,
        weight: .semibold
    )
    let textWidth = ceil(
        ("周剩 100%" as NSString).size(withAttributes: [.font: font]).width
    )
    let requiredWidth =
        SessionNestStatusLabelLayout.ringDiameter
        + SessionNestStatusLabelLayout.spacing
        + textWidth

    #expect(requiredWidth <= SessionNestStatusLabelLayout.contentWidth)
}

@Test func compactStatusLayoutFitsQuotaCycleTokenUsage() {
    let font = NSFont.monospacedDigitSystemFont(
        ofSize: SessionNestStatusLabelLayout.tokenFontSize,
        weight: .medium
    )
    let textWidth = ceil(
        ("本期 9999亿" as NSString).size(withAttributes: [.font: font]).width
    )
    let requiredWidth =
        SessionNestStatusLabelLayout.ringDiameter
        + SessionNestStatusLabelLayout.spacing
        + textWidth

    #expect(requiredWidth <= SessionNestStatusLabelLayout.contentWidth)
}

@Test func compactStatusTwoLineHeightFitsExistingStatusItem() {
    let quotaFont = NSFont.monospacedDigitSystemFont(
        ofSize: SessionNestStatusLabelLayout.fontSize,
        weight: .semibold
    )
    let tokenFont = NSFont.monospacedDigitSystemFont(
        ofSize: SessionNestStatusLabelLayout.tokenFontSize,
        weight: .medium
    )
    let requiredHeight =
        ceil(quotaFont.boundingRectForFont.height)
        + ceil(tokenFont.boundingRectForFont.height)
        + SessionNestStatusLabelLayout.verticalSpacing

    #expect(SessionNestStatusLabelLayout.statusItemLength == 72)
    #expect(
        SessionNestStatusLabelLayout.fontSize
            > SessionNestStatusLabelLayout.tokenFontSize
    )
    #expect(requiredHeight <= SessionNestStatusLabelLayout.hostedHeight)
}
