import Foundation
import Testing

@testable import SessionNest

@Test func tokenScanHealthStatusDistinguishesProgressFreshAndIncompleteData() {
    let health = TokenScanHealth(
        freshTargetIDs: ["fresh"],
        staleTargetIDs: ["stale"],
        failedTargetIDs: ["failed"]
    )

    #expect(
        TokenScanHealthStatus(health: health, isScanning: true).text
            == "正在追平 Token 日志 · 1 / 3 当前可用"
    )
    #expect(TokenScanHealthStatus(health: health, isScanning: true).isWarning == false)
    #expect(
        TokenScanHealthStatus(health: health, isScanning: false).text
            == "1 个日志待更新，1 个扫描失败；当前统计可能偏低"
    )
    #expect(TokenScanHealthStatus(health: health, isScanning: false).isWarning)

    let fresh = TokenScanHealth(
        freshTargetIDs: ["parent", "child"],
        staleTargetIDs: [],
        failedTargetIDs: []
    )
    #expect(
        TokenScanHealthStatus(health: fresh, isScanning: false).text
            == "Token 日志已追平 2 / 2（含子代理）"
    )
    #expect(TokenScanHealthStatus(health: fresh, isScanning: false).isWarning == false)
}

@Test func tokenCoverageStatusShowsPercentAndExactUnmeasuredReasons() {
    let breakdown = TokenCoverageBreakdown(
        totalSessionCount: 10,
        measuredSessionCount: 6,
        missingLogSessionCount: 1,
        emptyLogSessionCount: 1,
        staleLogSessionCount: 1,
        failedLogSessionCount: 1
    )
    let health = TokenScanHealth(
        freshTargetIDs: ["fresh"],
        staleTargetIDs: ["stale"],
        failedTargetIDs: ["failed"]
    )
    let status = TokenCoverageStatus(
        breakdown: breakdown,
        health: health,
        isScanning: false
    )

    #expect(status.metricDetailText == "已统计 6 / 10（60%）")
    #expect(
        status.noticeText
            == "未统计 4 个会话：未发现日志 1、无 Token 事件 1、日志待更新 1、扫描失败 1"
    )
    #expect(status.isWarning)
    #expect(
        TokenCoverageStatus(
            breakdown: breakdown,
            health: health,
            isScanning: true
        ).noticeText == "正在追平 Token 日志 · 1 / 3 当前可用"
    )
}

@Test func menuBarStatusFormatsQuotaCycleTokenUsage() {
    let measured = MenuBarStatus(
        totalSessions: 1,
        measuredSessions: 1,
        quotaCycleTokens: 1_200_000_000,
        rateLimits: nil,
        account: nil,
        isLoading: false,
        isRefreshing: false
    )
    let missing = MenuBarStatus(
        totalSessions: 1,
        measuredSessions: 0,
        quotaCycleTokens: nil,
        rateLimits: nil,
        account: nil,
        isLoading: false,
        isRefreshing: false
    )

    #expect(measured.compactTokenText == "本期 12亿")
    #expect(measured.quotaCycleTokenDetailText == "本额度周期本地 Token 1,200,000,000")
    #expect(missing.compactTokenText == "本期 --")
    #expect(missing.quotaCycleTokenDetailText == "本额度周期本地 Token --")
}

@Test func resetCreditsStatusSortsAvailableCardsAndFormatsLocalExpiration() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let now: Int64 = 1_784_329_200
    let summary = CodexRateLimitResetCreditsSummary(
        availableCount: 3,
        credits: [
            resetCredit(id: "internal-later", status: "available", expiresAt: 1_786_555_921),
            resetCredit(id: "internal-used", status: "consumed", expiresAt: 1_785_109_319),
            resetCredit(id: "internal-first", status: "available", expiresAt: 1_785_109_319),
            resetCredit(id: "internal-second", status: "available", expiresAt: 1_785_527_481),
        ]
    )

    let status = MenuBarResetCreditsStatus(
        summary: summary,
        now: now,
        calendar: calendar
    )

    #expect(status.summaryText == "重置卡 可用 3 次")
    #expect(status.expirationText == "最近于 7月27日 07:41 到期")
    #expect(
        status.availableCredits.map(\.id) == [
            "internal-first", "internal-second", "internal-later",
        ])
    #expect(status.expirationText.contains("internal") == false)
}

@Test func resetCreditsStatusDistinguishesMissingAndZeroAvailability() {
    let missing = MenuBarResetCreditsStatus(summary: nil, now: 1_000)
    let zero = MenuBarResetCreditsStatus(
        summary: CodexRateLimitResetCreditsSummary(availableCount: 0, credits: []),
        now: 1_000
    )

    #expect(missing.summaryText == "重置卡信息暂不可用")
    #expect(missing.expirationText == "Codex 当前未提供重置卡信息")
    #expect(missing.availableCredits.isEmpty)
    #expect(zero.summaryText == "暂无可用重置卡")
    #expect(zero.expirationText == "当前账户没有可用次数")
    #expect(zero.availableCredits.isEmpty)
}

@Test func menuBarStatisticsFormatsDashboardSummary() {
    let projects = (1...6).map { index in
        StatisticsProjectRow(
            projectPath: "/project-\(index)",
            projectName: "project-\(index)",
            usage: TokenUsageBreakdown(
                inputTokens: 0,
                cachedInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0,
                totalTokens: Int64(700 - index * 100)
            )
        )
    }
    let snapshot = StatisticsSnapshot(
        totalUsage: TokenUsageBreakdown(
            inputTokens: 5_600_000_000,
            cachedInputTokens: 5_200_000_000,
            outputTokens: 51_000_000,
            reasoningOutputTokens: 10_000_000,
            totalTokens: 5_700_000_000
        ),
        totalSessionCount: 378,
        measuredSessionCount: 374,
        averageTokensPerMeasuredSession: 15_110_000,
        dailyPoints: [],
        projectRows: projects,
        sessionRows: []
    )

    let status = MenuBarStatisticsStatus(snapshot: snapshot)

    #expect(status.sessionValueText == "378")
    #expect(status.sessionDetailText == "已统计 374 / 378")
    #expect(status.totalTokenValueText == "57亿")
    #expect(status.totalTokenDetailText == "5,700,000,000 Token")
    #expect(status.averageValueText == "1511万")
    #expect(status.nonCachedTokenValueText == "5亿")
    #expect(status.nonCachedTokenDetailText == "500,000,000 Token")
    #expect(status.topProjects.count == 5)
    #expect(status.projectFraction(status.topProjects[0]) == 1)
}

@Test func menuBarStatisticsHandlesZeroProjectUsage() {
    let zeroProject = StatisticsProjectRow(
        projectPath: "/zero",
        projectName: "zero",
        usage: .zero
    )
    let snapshot = StatisticsSnapshot(
        totalUsage: .zero,
        totalSessionCount: 0,
        measuredSessionCount: 0,
        averageTokensPerMeasuredSession: 0,
        dailyPoints: [],
        projectRows: [zeroProject],
        sessionRows: []
    )

    let status = MenuBarStatisticsStatus(snapshot: snapshot)

    #expect(status.projectFraction(zeroProject) == 0)
}

@Test func menuBarStatisticsFormatsTokenAxisLabelsInChinese() {
    let status = MenuBarStatisticsStatus(
        snapshot: StatisticsSnapshot(
            totalUsage: .zero,
            totalSessionCount: 0,
            measuredSessionCount: 0,
            averageTokensPerMeasuredSession: 0,
            dailyPoints: [],
            projectRows: [],
            sessionRows: []
        )
    )

    #expect(status.tokenAxisLabel(600_000_000) == "6亿")
    #expect(status.tokenAxisLabel(40_000_000) == "4000万")
    #expect(status.tokenAxisLabel(0) == "0")
}

@Test func menuBarStatisticsPassesThroughDailyPointsAndClampsProjectFractions() {
    let dailyPoints = [
        StatisticsDailyPoint(
            dayStart: 1_000,
            usage: TokenUsageBreakdown(
                inputTokens: 8,
                cachedInputTokens: 3,
                outputTokens: 2,
                reasoningOutputTokens: 1,
                totalTokens: 10
            )
        )
    ]
    let projects = [
        StatisticsProjectRow(
            projectPath: "/largest",
            projectName: "largest",
            usage: TokenUsageBreakdown(
                inputTokens: 0,
                cachedInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0,
                totalTokens: 100
            )
        ),
        StatisticsProjectRow(
            projectPath: "/smaller",
            projectName: "smaller",
            usage: TokenUsageBreakdown(
                inputTokens: 0,
                cachedInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0,
                totalTokens: 25
            )
        ),
        StatisticsProjectRow(
            projectPath: "/invalid",
            projectName: "invalid",
            usage: TokenUsageBreakdown(
                inputTokens: 0,
                cachedInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0,
                totalTokens: -10
            )
        ),
    ]
    let snapshot = StatisticsSnapshot(
        totalUsage: .zero,
        totalSessionCount: 3,
        measuredSessionCount: 3,
        averageTokensPerMeasuredSession: 0,
        dailyPoints: dailyPoints,
        projectRows: projects,
        sessionRows: []
    )

    let status = MenuBarStatisticsStatus(snapshot: snapshot)

    #expect(status.dailyPoints == dailyPoints)
    #expect(status.projectFraction(projects[1]) == 0.25)
    #expect(status.projectFraction(projects[2]) == 0)
}

@Test func menuBarStatisticsShowsMarkerForSingleDayTrend() {
    let point = StatisticsDailyPoint(
        dayStart: 100,
        usage: TokenUsageBreakdown(
            inputTokens: 10,
            cachedInputTokens: 5,
            outputTokens: 2,
            reasoningOutputTokens: 1,
            totalTokens: 12
        )
    )
    let snapshot = StatisticsSnapshot(
        totalUsage: point.usage,
        totalSessionCount: 1,
        measuredSessionCount: 1,
        averageTokensPerMeasuredSession: 12,
        dailyPoints: [point],
        projectRows: [],
        sessionRows: []
    )

    let status = MenuBarStatisticsStatus(snapshot: snapshot)

    #expect(status.showsSingleDayTrendMarker)
}

@Test func menuBarStatisticsDistinguishesTokenScanFromEmptyData() {
    let snapshot = StatisticsSnapshot(
        totalUsage: .zero,
        totalSessionCount: 2,
        measuredSessionCount: 0,
        averageTokensPerMeasuredSession: 0,
        dailyPoints: [],
        projectRows: [],
        sessionRows: []
    )

    let scanning = MenuBarStatisticsStatus(snapshot: snapshot, isScanningTokenUsage: true)
    let empty = MenuBarStatisticsStatus(snapshot: snapshot, isScanningTokenUsage: false)

    #expect(scanning.showsTokenScanProgress)
    #expect(scanning.tokenTrendEmptyText == "正在统计 Token…")
    #expect(scanning.projectTokenEmptyText == "正在统计 Token…")
    #expect(!empty.showsTokenScanProgress)
    #expect(empty.tokenTrendEmptyText == "暂无 Token 趋势")
    #expect(empty.projectTokenEmptyText == "暂无项目统计")
}

@Test func menuBarAccountStatusFormatsKnownAndMissingAccounts() {
    let pro = MenuBarAccountStatus(
        account: CodexAccountSnapshot(
            type: "chatgpt",
            email: "person@example.com",
            planType: "pro"
        )
    )
    let business = MenuBarAccountStatus(
        account: CodexAccountSnapshot(
            type: "chatgpt",
            email: "team@example.com",
            planType: "self_serve_business_usage_based"
        )
    )
    let missing = MenuBarAccountStatus(account: nil)

    #expect(pro.planText == "Pro")
    #expect(pro.emailText == "person@example.com")
    #expect(business.planText == "Business")
    #expect(missing.planText == "--")
    #expect(missing.emailText == "--")
}

@Test func menuBarStatusPrefersRateLimitEntitlementPlan() throws {
    let rateLimits = try JSONDecoder().decode(
        CodexRateLimitSnapshot.self,
        from: Data(
            #"{"primary":{"usedPercent":58,"windowDurationMins":10080,"resetsAt":1784508043},"secondary":null,"planType":"pro"}"#
                .utf8
        )
    )
    let status = MenuBarStatus(
        totalSessions: 1,
        measuredSessions: 1,
        rateLimits: rateLimits,
        account: CodexAccountSnapshot(
            type: "chatgpt",
            email: "person@example.com",
            planType: "plus"
        ),
        isLoading: false,
        isRefreshing: false
    )

    #expect(status.account.planText == "Pro")
    #expect(status.account.emailText == "person@example.com")
}

@Test func menuBarStatusShowsPopoverMetrics() throws {
    let rateLimits = try JSONDecoder().decode(
        CodexRateLimitSnapshot.self,
        from: Data(
            #"{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":11800},"secondary":{"usedPercent":52,"windowDurationMins":10080,"resetsAt":101800}}"#
                .utf8
        )
    )
    let status = MenuBarStatus(
        totalSessions: 400,
        measuredSessions: 376,
        rateLimits: rateLimits,
        account: nil,
        isLoading: false,
        isRefreshing: false,
        now: 1_000
    )

    #expect(status.compactQuotaText == "周剩 48%")
    #expect(
        status.coreDetailTexts == [
            "Codex 周配额剩余 48%",
            "本额度周期本地 Token --",
            "会话总数 400",
        ]
    )
    #expect(status.account.planText == "--")
    #expect(status.weeklyQuota.remainingText == "48% 剩余")
    #expect(status.weeklyQuota.fraction == 0.48)
    #expect(status.weeklyQuota.resetText == "1 天 4 小时后重置")
    #expect(status.tokenCoverageText == "Token 覆盖 376 / 400")
    #expect(status.tokenCoveragePercentText == "94%")
    #expect(status.tokenCoverageFraction == 0.94)
}

@Test func menuBarQuotaColorFollowsRemainingThresholds() throws {
    func status(usedPercent: Int) throws -> MenuBarStatus {
        let rateLimits = try JSONDecoder().decode(
            CodexRateLimitSnapshot.self,
            from: Data(
                """
                {"primary":{"usedPercent":\(usedPercent),"windowDurationMins":10080}}
                """.utf8
            )
        )
        return MenuBarStatus(
            totalSessions: 1,
            measuredSessions: 1,
            rateLimits: rateLimits,
            account: nil,
            isLoading: false,
            isRefreshing: false,
            now: 1_000
        )
    }

    let missing = MenuBarStatus(
        totalSessions: 1,
        measuredSessions: 1,
        rateLimits: nil,
        account: nil,
        isLoading: false,
        isRefreshing: false,
        now: 1_000
    )

    #expect(missing.quotaColor == .gray)
    #expect(try status(usedPercent: 81).quotaColor == .red)
    #expect(try status(usedPercent: 80).quotaColor == .yellow)
    #expect(try status(usedPercent: 50).quotaColor == .yellow)
    #expect(try status(usedPercent: 49).quotaColor == .green)
    #expect(try status(usedPercent: 49).weeklyQuota.color == .green)
}

@Test func menuBarStatusUsesFilteredStatisticsSnapshotForSessionCoverage() {
    let snapshot = StatisticsSnapshot(
        totalUsage: .zero,
        totalSessionCount: 7,
        measuredSessionCount: 3,
        averageTokensPerMeasuredSession: 0,
        dailyPoints: [],
        projectRows: [],
        sessionRows: []
    )

    let status = MenuBarStatus(
        snapshot: snapshot,
        rateLimits: nil,
        account: nil,
        isLoading: false,
        isRefreshing: false,
        now: 1_000
    )

    #expect(status.sessionTotalText == "会话总数 7")
    #expect(status.tokenCoverageText == "Token 覆盖 3 / 7")
    #expect(status.tokenCoveragePercentText == "43%")
    #expect(status.tokenCoverageFraction == 0.43)
}

@Test func menuBarStatusShowsInitialLoadingState() {
    let status = MenuBarStatus(
        totalSessions: 0,
        measuredSessions: 0,
        rateLimits: nil,
        account: nil,
        isLoading: true,
        isRefreshing: false,
        now: 1_000
    )

    #expect(status.sessionTotalText == "会话 …")
    #expect(status.showsProgress)
}

@Test func menuBarStatusShowsMissingQuota() {
    let status = MenuBarStatus(
        totalSessions: 3,
        measuredSessions: 2,
        rateLimits: nil,
        account: nil,
        isLoading: false,
        isRefreshing: false,
        now: 1_000
    )

    #expect(status.weeklyQuota.remainingText == "-- 剩余")
    #expect(status.weeklyQuota.fraction == 0)
    #expect(status.weeklyQuota.resetText == "重置时间 --")
    #expect(status.weeklyQuota.resetAtText == "重置时间 --")
}

@Test func dailyTokenUsagePresentationBuildsOrderedSevenDayFallbackDomain() {
    let calendar = quotaChartCalendar()
    let now = quotaChartTimestamp(2026, 7, 21, hour: 12, calendar: calendar)
    let expected = (15...21).map {
        quotaChartTimestamp(2026, 7, $0, calendar: calendar)
    }

    #expect(
        DailyTokenUsagePresentation.dayDomain(
            startingAt: nil,
            now: now,
            calendar: calendar
        ) == expected
    )
}

@Test func dailyTokenUsagePresentationIncludesQuotaCyclesFirstPartialDay() {
    let calendar = quotaChartCalendar()
    let startingAt = quotaChartTimestamp(
        2026,
        7,
        14,
        hour: 14,
        calendar: calendar
    )
    let now = quotaChartTimestamp(2026, 7, 21, hour: 12, calendar: calendar)
    let expected = (14...21).map {
        quotaChartTimestamp(2026, 7, $0, calendar: calendar)
    }

    #expect(
        DailyTokenUsagePresentation.dayDomain(
            startingAt: startingAt,
            now: now,
            calendar: calendar
        ) == expected
    )
}

@Test func dailyTokenUsagePresentationAdvancesQuotaCycleByLocalDayAcrossDST() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let startingAt = quotaChartTimestamp(
        2026,
        3,
        7,
        hour: 14,
        calendar: calendar
    )
    let now = quotaChartTimestamp(2026, 3, 10, hour: 12, calendar: calendar)
    let expected = (7...10).map {
        quotaChartTimestamp(2026, 3, $0, calendar: calendar)
    }

    #expect(
        DailyTokenUsagePresentation.dayDomain(
            startingAt: startingAt,
            now: now,
            calendar: calendar
        ) == expected
    )
}

@Test func dailyTokenUsagePresentationFormatsChineseDayLabels() {
    let calendar = quotaChartCalendar()
    let now = quotaChartTimestamp(2026, 7, 21, hour: 12, calendar: calendar)
    let today = quotaChartTimestamp(2026, 7, 21, calendar: calendar)
    let yesterday = quotaChartTimestamp(2026, 7, 20, calendar: calendar)
    let monday = quotaChartTimestamp(2026, 7, 20, calendar: calendar)

    #expect(
        DailyTokenUsagePresentation.dayLabel(today, now: now, calendar: calendar) == "今天"
    )
    #expect(
        DailyTokenUsagePresentation.dayLabel(yesterday, now: now, calendar: calendar)
            == "昨天"
    )
    #expect(DailyTokenUsagePresentation.weekdayLabel(monday, calendar: calendar) == "周一")
}

@Test func dailyTokenUsagePresentationFormatsCompactAndExactTokens() {
    #expect(DailyTokenUsagePresentation.compactTokenText(10_000) == "1万")
    #expect(DailyTokenUsagePresentation.exactTokenText(12_345) == "12,345 Token")
    #expect(DailyTokenUsagePresentation.emptyText == "暂无每日 Token 记录")
    #expect(
        DailyTokenUsagePresentation.observationCaption == TokenUsageDefinition.explanation
    )
}

@Test func dailyTokenUsageSelectionReconcilesSelectedPoint() {
    let points = [
        dailyTokenPoint(dayStart: 100, totalTokens: 1),
        dailyTokenPoint(dayStart: 200, totalTokens: 2),
    ]

    #expect(DailyTokenUsageSelection.defaultDay(in: points) == 200)
    #expect(DailyTokenUsageSelection.defaultDay(in: []) == nil)
    #expect(DailyTokenUsageSelection.reconcile(selectedDay: nil, in: points) == nil)
    #expect(DailyTokenUsageSelection.reconcile(selectedDay: 100, in: points) == 100)
    #expect(DailyTokenUsageSelection.reconcile(selectedDay: 300, in: points) == nil)
}

@Test func dailyTokenUsageChartKeepsCompactHeightAndReadableAccessibility() {
    let calendar = quotaChartCalendar()
    let now = quotaChartTimestamp(2026, 7, 21, hour: 12, calendar: calendar)
    let today = quotaChartTimestamp(2026, 7, 21, calendar: calendar)
    let earlierDay = quotaChartTimestamp(2026, 7, 19, calendar: calendar)

    #expect(DailyTokenUsagePresentation.chartHeight == 110)
    #expect(
        DailyTokenUsagePresentation.accessibilityLabel(
            dayStart: today,
            tokens: 12_345,
            now: now,
            calendar: calendar
        ) == "今天，2026年7月21日，12,345 Token"
    )
    #expect(
        DailyTokenUsagePresentation.accessibilityLabel(
            dayStart: earlierDay,
            tokens: 8_765,
            now: now,
            calendar: calendar
        ) == "2026年7月19日，8,765 Token"
    )
}

@Test func dailyTokenUsageChartScalesPlainSwiftUIBarsWithoutInventingUsage() {
    #expect(DailyTokenUsagePresentation.barHeight(tokens: 0, maximum: 10) == 0)
    #expect(DailyTokenUsagePresentation.barHeight(tokens: 2, maximum: 0) == 0)
    #expect(DailyTokenUsagePresentation.barHeight(tokens: 2, maximum: 10) == 12.4)
    #expect(
        DailyTokenUsagePresentation.barHeight(tokens: 20, maximum: 10)
            == DailyTokenUsagePresentation.barAreaHeight
    )
}

@Test func quotaStatusFormatsAbsoluteResetInProvidedCalendar() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let resetDate = calendar.date(
        from: DateComponents(year: 2026, month: 7, day: 20, hour: 1, minute: 2)
    )!
    let window = CodexRateLimitWindow(
        usedPercent: 42,
        windowDurationMins: 10_080,
        resetsAt: Int64(resetDate.timeIntervalSince1970)
    )

    let status = MenuBarQuotaStatus(window: window, now: 1_000, calendar: calendar)

    #expect(status.resetAtText == "2026年7月20日 01:02 重置")
}

@Test func menuBarStatusClampsInvalidInputs() throws {
    let rateLimits = try JSONDecoder().decode(
        CodexRateLimitSnapshot.self,
        from: Data(
            #"{"primary":{"usedPercent":-20,"windowDurationMins":300,"resetsAt":1000},"secondary":{"usedPercent":140,"windowDurationMins":10080,"resetsAt":999}}"#
                .utf8
        )
    )
    let status = MenuBarStatus(
        totalSessions: -4,
        measuredSessions: 10,
        rateLimits: rateLimits,
        account: nil,
        isLoading: false,
        isRefreshing: true,
        now: 1_000
    )

    #expect(status.weeklyQuota.fraction == 0)
    #expect(status.weeklyQuota.resetText == "即将重置")
    #expect(status.tokenCoverageText == "Token 覆盖 0 / 0")
    #expect(status.tokenCoveragePercentText == "0%")
    #expect(status.tokenCoverageFraction == 0)
    #expect(status.showsProgress)
}

private func resetCredit(
    id: String,
    status: String,
    expiresAt: Int64
) -> CodexRateLimitResetCredit {
    CodexRateLimitResetCredit(
        id: id,
        resetType: "codexRateLimits",
        status: status,
        grantedAt: expiresAt - 2_592_000,
        expiresAt: expiresAt,
        title: "Full reset",
        description: "Granted"
    )
}

private func dailyTokenPoint(dayStart: Int64, totalTokens: Int64) -> StatisticsDailyPoint {
    StatisticsDailyPoint(
        dayStart: dayStart,
        usage: TokenUsageBreakdown(
            inputTokens: totalTokens,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            totalTokens: totalTokens
        )
    )
}

private func quotaChartCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}

private func quotaChartTimestamp(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    hour: Int = 0,
    calendar: Calendar
) -> Int64 {
    Int64(
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour)
        )!.timeIntervalSince1970
    )
}
