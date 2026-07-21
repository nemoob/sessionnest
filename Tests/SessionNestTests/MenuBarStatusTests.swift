import Foundation
import Testing

@testable import SessionNest

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

    #expect(measured.compactTokenText == "已用 12亿")
    #expect(missing.compactTokenText == "已用 --")
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
    #expect(status.cachedInputValueText == "52亿")
    #expect(status.cachedInputDetailText == "5,200,000,000 Token")
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

@Test func quotaDailyUsagePresentationBuildsOrderedSevenDayDomain() {
    let calendar = quotaChartCalendar()
    let now = quotaChartTimestamp(2026, 7, 21, hour: 12, calendar: calendar)
    let expected = (15...21).map {
        quotaChartTimestamp(2026, 7, $0, calendar: calendar)
    }

    #expect(
        QuotaDailyUsagePresentation.dayDomain(now: now, calendar: calendar) == expected
    )
}

@Test func quotaDailyUsagePresentationFormatsChineseDayLabels() {
    let calendar = quotaChartCalendar()
    let now = quotaChartTimestamp(2026, 7, 21, hour: 12, calendar: calendar)
    let today = quotaChartTimestamp(2026, 7, 21, calendar: calendar)
    let yesterday = quotaChartTimestamp(2026, 7, 20, calendar: calendar)
    let monday = quotaChartTimestamp(2026, 7, 20, calendar: calendar)

    #expect(
        QuotaDailyUsagePresentation.dayLabel(today, now: now, calendar: calendar) == "今天"
    )
    #expect(
        QuotaDailyUsagePresentation.dayLabel(yesterday, now: now, calendar: calendar)
            == "昨天"
    )
    #expect(QuotaDailyUsagePresentation.weekdayLabel(monday, calendar: calendar) == "周一")
}

@Test func quotaDailyUsagePresentationFormatsPercentagesWithoutInventingUnknownValues() {
    #expect(QuotaDailyUsagePresentation.percentage(3.24) == "3.2%")
    #expect(QuotaDailyUsagePresentation.percentage(3) == "3%")
    #expect(QuotaDailyUsagePresentation.percentage(nil) == "--")
    #expect(QuotaDailyUsagePresentation.emptyText == "从现在开始记录每日额度变化")
    #expect(
        QuotaDailyUsagePresentation.observationCaption
            == "仅统计本地观察到的 Codex 额度快照，无法回溯此前用量"
    )
}

@Test func quotaDailyUsagePresentationMatchesTokensWithoutUsingZeroForMissingData() {
    let known = StatisticsDailyPoint(
        dayStart: 200,
        usage: TokenUsageBreakdown(
            inputTokens: 8_000,
            cachedInputTokens: 3_000,
            outputTokens: 1_000,
            reasoningOutputTokens: 500,
            totalTokens: 10_000
        )
    )

    #expect(
        QuotaDailyUsagePresentation.tokenText(for: 200, in: [known]) == "1万 Token"
    )
    #expect(QuotaDailyUsagePresentation.tokenText(for: 300, in: [known]) == nil)
}

@Test func quotaDailyUsageSelectionClampsOutsideRangeAndChoosesEarlierTie() {
    let points = [
        QuotaDailyUsagePoint(dayStart: 100, usedPercent: 1),
        QuotaDailyUsagePoint(dayStart: 200, usedPercent: 2),
        QuotaDailyUsagePoint(dayStart: 300, usedPercent: 3),
    ]

    #expect(QuotaDailyUsageChartSelection.nearestPoint(to: 10, in: points)?.dayStart == 100)
    #expect(QuotaDailyUsageChartSelection.nearestPoint(to: 390, in: points)?.dayStart == 300)
    #expect(QuotaDailyUsageChartSelection.nearestPoint(to: 150, in: points)?.dayStart == 100)
    #expect(QuotaDailyUsageChartSelection.nearestPoint(to: 151, in: points)?.dayStart == 200)
}

@Test func quotaDailyUsageSelectionReconcilesSelectedPoint() {
    let points = [
        QuotaDailyUsagePoint(dayStart: 100, usedPercent: 1),
        QuotaDailyUsagePoint(dayStart: 200, usedPercent: 2),
    ]

    #expect(QuotaDailyUsageChartSelection.reconcile(selectedDay: nil, in: points) == nil)
    #expect(QuotaDailyUsageChartSelection.reconcile(selectedDay: 100, in: points) == 100)
    #expect(QuotaDailyUsageChartSelection.reconcile(selectedDay: 300, in: points) == nil)
}

@Test func quotaDailyUsageChartKeepsCompactHeightAndReadableAccessibility() {
    let calendar = quotaChartCalendar()
    let now = quotaChartTimestamp(2026, 7, 21, hour: 12, calendar: calendar)
    let today = quotaChartTimestamp(2026, 7, 21, calendar: calendar)
    let earlierDay = quotaChartTimestamp(2026, 7, 19, calendar: calendar)

    #expect(QuotaDailyUsagePresentation.chartHeight == 110)
    #expect(
        QuotaDailyUsagePresentation.accessibilityLabel(
            dayStart: today,
            usedPercent: 3.24,
            now: now,
            calendar: calendar
        ) == "今天，2026年7月21日，消耗 3.2%"
    )
    #expect(
        QuotaDailyUsagePresentation.accessibilityLabel(
            dayStart: earlierDay,
            usedPercent: 1,
            now: now,
            calendar: calendar
        ) == "2026年7月19日，消耗 1%"
    )
}

@Test func quotaDailyUsageChartScalesPlainSwiftUIBarsWithoutInventingUsage() {
    #expect(QuotaDailyUsagePresentation.barHeight(usedPercent: 0, maximum: 10) == 0)
    #expect(QuotaDailyUsagePresentation.barHeight(usedPercent: .nan, maximum: 10) == 0)
    #expect(QuotaDailyUsagePresentation.barHeight(usedPercent: 2, maximum: 10) == 12.4)
    #expect(
        QuotaDailyUsagePresentation.barHeight(usedPercent: 20, maximum: 10)
            == QuotaDailyUsagePresentation.barAreaHeight
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
