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
