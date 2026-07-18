import Foundation
import Testing

@testable import SessionNest

@Suite("SessionStatisticsTests")
struct SessionStatisticsTests {
    @Test func explicitCutoffExcludesEarlierSessionsAndUsage() {
        let calendar = calendar(timeZone: "UTC")
        let cutoff = timestamp(2026, 7, 15, calendar: calendar)
        let now = timestamp(2026, 7, 16, hour: 12, calendar: calendar)
        let included = thread("included", activityTimestamp: cutoff)
        let excluded = thread("excluded", activityTimestamp: cutoff - 1)

        let snapshot = SessionStatistics.build(
            threads: [included, excluded],
            coveredThreadIDs: [included.id, excluded.id],
            dailyUsage: [
                daily(included.id, day: cutoff, usage: usage(10, 5, 2, 1, 12)),
                daily(
                    excluded.id,
                    day: cutoff - 86_400,
                    usage: usage(99, 90, 9, 8, 108)
                ),
            ],
            threadProjects: [:],
            startingAt: cutoff,
            calendar: calendar,
            now: now
        )

        #expect(snapshot.totalSessionCount == 1)
        #expect(snapshot.totalUsage == usage(10, 5, 2, 1, 12))
        #expect(snapshot.sessionRows.map(\.threadID) == [included.id])
    }

    @Test func sevenDayRangeUsesInclusiveLocalBoundaryAcrossSpringDST() {
        let calendar = calendar(timeZone: "America/Los_Angeles")
        let now = timestamp(2026, 3, 10, hour: 12, calendar: calendar)
        let cutoff = timestamp(2026, 3, 4, calendar: calendar)
        let included = thread("included", activityTimestamp: cutoff)
        let excluded = thread("excluded", activityTimestamp: cutoff - 1)

        let snapshot = SessionStatistics.build(
            threads: [included, excluded],
            coveredThreadIDs: [included.id, excluded.id],
            dailyUsage: [
                daily("included", day: cutoff, usage: usage(10, 5, 2, 1, 12)),
                daily(
                    "included",
                    day: timestamp(2026, 3, 3, calendar: calendar),
                    usage: usage(99, 90, 9, 8, 108)
                ),
            ],
            threadProjects: [:],
            timeFilter: .sevenDays,
            calendar: calendar,
            now: now
        )

        #expect(snapshot.totalSessionCount == 1)
        #expect(snapshot.measuredSessionCount == 1)
        #expect(snapshot.totalUsage == usage(10, 5, 2, 1, 12))
        #expect(snapshot.dailyPoints.map(\.dayStart) == [cutoff])
    }

    @Test func thirtyDayRangeUsesInclusiveLocalBoundaryAcrossFallDST() {
        let calendar = calendar(timeZone: "America/New_York")
        let now = timestamp(2026, 11, 5, hour: 12, calendar: calendar)
        let cutoff = timestamp(2026, 10, 7, calendar: calendar)
        let included = thread("included", activityTimestamp: cutoff)
        let excluded = thread("excluded", activityTimestamp: cutoff - 1)

        let snapshot = SessionStatistics.build(
            threads: [included, excluded],
            coveredThreadIDs: [included.id, excluded.id],
            dailyUsage: [
                daily("included", day: cutoff, usage: usage(30, 10, 5, 2, 35)),
                daily(
                    "included",
                    day: timestamp(2026, 10, 6, calendar: calendar),
                    usage: usage(90, 80, 10, 8, 100)
                ),
            ],
            threadProjects: [:],
            timeFilter: .thirtyDays,
            calendar: calendar,
            now: now
        )

        #expect(snapshot.totalSessionCount == 1)
        #expect(snapshot.measuredSessionCount == 1)
        #expect(snapshot.totalUsage == usage(30, 10, 5, 2, 35))
        #expect(snapshot.dailyPoints.map(\.dayStart) == [cutoff])
    }

    @Test func rangeUsageExcludesThreadsWithActivityBeforeCutoff() {
        let calendar = calendar(timeZone: "UTC")
        let now = timestamp(2026, 7, 14, hour: 12, calendar: calendar)
        let cutoff = timestamp(2026, 7, 8, calendar: calendar)
        let today = timestamp(2026, 7, 14, calendar: calendar)
        let eligible = thread(
            "eligible",
            cwd: "/work/eligible",
            activityTimestamp: cutoff
        )
        let tooOld = thread(
            "too-old",
            cwd: "/work/too-old",
            activityTimestamp: cutoff - 1
        )

        let snapshot = SessionStatistics.build(
            threads: [tooOld, eligible],
            coveredThreadIDs: [tooOld.id, eligible.id],
            dailyUsage: [
                daily(eligible.id, day: today, usage: usage(10, 5, 2, 1, 12)),
                daily(tooOld.id, day: today, usage: usage(100, 50, 20, 10, 120)),
            ],
            threadProjects: [:],
            timeFilter: .sevenDays,
            calendar: calendar,
            now: now
        )

        #expect(snapshot.totalSessionCount == 1)
        #expect(snapshot.measuredSessionCount == 1)
        #expect(snapshot.totalUsage == usage(10, 5, 2, 1, 12))
        #expect(snapshot.dailyPoints.map(\.usage) == [usage(10, 5, 2, 1, 12)])
        #expect(snapshot.projectRows.map(\.projectPath) == ["/work/eligible"])
        #expect(snapshot.sessionRows.map(\.threadID) == [eligible.id])
    }

    @Test func limitedRangesIncludeNowAndTodayButExcludeFutureActivityAndDay() {
        let calendar = calendar(timeZone: "Asia/Shanghai")
        let today = timestamp(2026, 7, 14, calendar: calendar)
        let now = timestamp(2026, 7, 14, hour: 12, calendar: calendar)
        let tomorrow = timestamp(2026, 7, 15, calendar: calendar)
        let included = thread(
            "included",
            cwd: "/work/included",
            activityTimestamp: now
        )
        let futureActivity = thread(
            "future-activity",
            cwd: "/work/future",
            activityTimestamp: now + 1
        )

        for timeFilter in [SessionTimeFilter.sevenDays, .thirtyDays] {
            let snapshot = SessionStatistics.build(
                threads: [futureActivity, included],
                coveredThreadIDs: [futureActivity.id, included.id],
                dailyUsage: [
                    daily(included.id, day: today, usage: usage(10, 5, 2, 1, 12)),
                    daily(included.id, day: tomorrow, usage: usage(30, 20, 10, 5, 40)),
                    daily(futureActivity.id, day: today, usage: usage(20, 10, 5, 2, 25)),
                ],
                threadProjects: [:],
                timeFilter: timeFilter,
                calendar: calendar,
                now: now
            )

            #expect(snapshot.totalSessionCount == 1)
            #expect(snapshot.measuredSessionCount == 1)
            #expect(snapshot.totalUsage == usage(10, 5, 2, 1, 12))
            #expect(snapshot.dailyPoints.map(\.dayStart) == [today])
            #expect(snapshot.projectRows.map(\.projectPath) == ["/work/included"])
            #expect(snapshot.sessionRows.map(\.threadID) == [included.id])
        }
    }

    @Test func allTimeIncludesSuppliedArchivedAndExcludesUncoveredFromAverage() {
        let threads = [
            thread("active", title: "Active", activityTimestamp: 30),
            thread("archived", title: "Archived", activityTimestamp: 20),
            thread("missing", title: "Missing", activityTimestamp: 10),
        ]

        let snapshot = SessionStatistics.build(
            threads: threads,
            coveredThreadIDs: ["active", "archived"],
            dailyUsage: [
                daily("active", day: 100, usage: usage(80, 50, 20, 10, 100)),
                daily("archived", day: 200, usage: usage(40, 20, 10, 5, 50)),
                daily("missing", day: 200, usage: usage(400, 300, 100, 50, 500)),
                daily("not-supplied", day: 200, usage: usage(900, 800, 99, 88, 999)),
            ],
            threadProjects: [:],
            timeFilter: .all,
            calendar: calendar(timeZone: "UTC"),
            now: 1_000
        )

        #expect(snapshot.totalSessionCount == 3)
        #expect(snapshot.measuredSessionCount == 2)
        #expect(snapshot.averageTokensPerMeasuredSession == 75)
        #expect(snapshot.totalUsage == usage(120, 70, 30, 15, 150))
        #expect(snapshot.sessionRows.map(\.threadID) == ["active", "archived"])
    }

    @Test func aggregatesRangeRowsWithEffectiveProjectsAndStableTieSorting() {
        let calendar = calendar(timeZone: "UTC")
        let now = timestamp(2026, 7, 14, hour: 12, calendar: calendar)
        let firstDay = timestamp(2026, 7, 10, calendar: calendar)
        let secondDay = timestamp(2026, 7, 11, calendar: calendar)
        let alpha = thread(
            "alpha-id",
            title: "Alpha",
            cwd: "/work/original-alpha",
            activityTimestamp: now
        )
        let beta = thread(
            "beta-id",
            title: "Beta",
            cwd: "/work/original-beta",
            activityTimestamp: now
        )
        let projects = [
            alpha.id: ThreadProjectCache(
                threadID: alpha.id,
                resolution: .project(path: "/work/projects/Zeta"),
                analyzedUpdatedAt: now,
                classifierVersion: 1
            ),
            beta.id: ThreadProjectCache(
                threadID: beta.id,
                resolution: .project(path: "/work/projects/Alpha"),
                analyzedUpdatedAt: now,
                classifierVersion: 1
            ),
        ]

        let snapshot = SessionStatistics.build(
            threads: [beta, alpha],
            coveredThreadIDs: [alpha.id, beta.id],
            dailyUsage: [
                daily(alpha.id, day: firstDay, usage: usage(100, 80, 20, 10, 120)),
                daily(beta.id, day: firstDay, usage: usage(50, 40, 10, 5, 60)),
                daily(beta.id, day: secondDay, usage: usage(50, 40, 10, 5, 60)),
            ],
            threadProjects: projects,
            timeFilter: .sevenDays,
            calendar: calendar,
            now: now
        )

        #expect(snapshot.totalUsage == usage(200, 160, 40, 20, 240))
        #expect(snapshot.dailyPoints.map(\.dayStart) == [firstDay, secondDay])
        #expect(
            snapshot.dailyPoints.map(\.usage) == [
                usage(150, 120, 30, 15, 180),
                usage(50, 40, 10, 5, 60),
            ])
        #expect(
            snapshot.projectRows.map(\.projectPath) == [
                "/work/projects/Alpha",
                "/work/projects/Zeta",
            ])
        #expect(snapshot.projectRows.map(\.usage.totalTokens) == [120, 120])
        #expect(snapshot.sessionRows.map(\.threadID) == [alpha.id, beta.id])
        #expect(
            snapshot.sessionRows.map(\.projectPath) == [
                "/work/projects/Zeta",
                "/work/projects/Alpha",
            ])
        #expect(snapshot.sessionRows.map(\.usage.totalTokens) == [120, 120])
    }

    @Test func emptyInputBuildsEmptySnapshot() {
        let snapshot = SessionStatistics.build(
            threads: [],
            coveredThreadIDs: [],
            dailyUsage: [],
            threadProjects: [:],
            timeFilter: .all,
            calendar: calendar(timeZone: "UTC"),
            now: 0
        )

        #expect(snapshot.totalUsage == .zero)
        #expect(snapshot.totalSessionCount == 0)
        #expect(snapshot.measuredSessionCount == 0)
        #expect(snapshot.averageTokensPerMeasuredSession == 0)
        #expect(snapshot.dailyPoints.isEmpty)
        #expect(snapshot.projectRows.isEmpty)
        #expect(snapshot.sessionRows.isEmpty)
    }

    @Test func retainsComponentOnlyDailyUsageWhenTotalDoesNotIncrease() {
        let covered = thread("covered", activityTimestamp: 100)
        let componentOnly = usage(0, 7, 0, 3, 0)

        let snapshot = SessionStatistics.build(
            threads: [covered],
            coveredThreadIDs: [covered.id],
            dailyUsage: [daily(covered.id, day: 100, usage: componentOnly)],
            threadProjects: [:],
            timeFilter: .all,
            calendar: calendar(timeZone: "UTC"),
            now: 1_000
        )

        #expect(snapshot.totalUsage == componentOnly)
        #expect(snapshot.dailyPoints.map(\.usage) == [componentOnly])
        #expect(snapshot.projectRows.map(\.usage) == [componentOnly])
        #expect(snapshot.sessionRows.map(\.usage) == [componentOnly])
    }

    @Test func coveredSessionRemainsMeasuredWhenItsUsageIsOutsideRange() {
        let calendar = calendar(timeZone: "UTC")
        let now = timestamp(2026, 7, 14, hour: 12, calendar: calendar)
        let outsideRange = timestamp(2026, 7, 1, calendar: calendar)
        let covered = thread("covered", activityTimestamp: now)
        let missing = thread("missing", activityTimestamp: now)

        let snapshot = SessionStatistics.build(
            threads: [covered, missing],
            coveredThreadIDs: [covered.id],
            dailyUsage: [
                daily(covered.id, day: outsideRange, usage: usage(10, 5, 2, 1, 12))
            ],
            threadProjects: [:],
            timeFilter: .sevenDays,
            calendar: calendar,
            now: now
        )

        #expect(snapshot.totalSessionCount == 2)
        #expect(snapshot.measuredSessionCount == 1)
        #expect(snapshot.averageTokensPerMeasuredSession == 0)
        #expect(snapshot.sessionRows.map(\.threadID) == [covered.id])
        #expect(snapshot.sessionRows.map(\.usage) == [.zero])
    }

    private func thread(
        _ id: String,
        title: String? = nil,
        cwd: String = "/work/default",
        activityTimestamp: Int64
    ) -> CodexThread {
        CodexThread(
            id: id,
            name: title,
            preview: id,
            cwd: cwd,
            createdAt: activityTimestamp,
            updatedAt: activityTimestamp,
            recencyAt: nil,
            gitInfo: nil
        )
    }

    private func daily(
        _ threadID: String,
        day: Int64,
        usage: TokenUsageBreakdown
    ) -> ThreadTokenDailyUsage {
        ThreadTokenDailyUsage(threadID: threadID, dayStart: day, usage: usage)
    }

    private func usage(
        _ input: Int64,
        _ cachedInput: Int64,
        _ output: Int64,
        _ reasoningOutput: Int64,
        _ total: Int64
    ) -> TokenUsageBreakdown {
        TokenUsageBreakdown(
            inputTokens: input,
            cachedInputTokens: cachedInput,
            outputTokens: output,
            reasoningOutputTokens: reasoningOutput,
            totalTokens: total
        )
    }

    private func calendar(timeZone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }

    private func timestamp(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 0,
        calendar: Calendar
    ) -> Int64 {
        Int64(
            calendar.date(
                from: DateComponents(
                    calendar: calendar,
                    timeZone: calendar.timeZone,
                    year: year,
                    month: month,
                    day: day,
                    hour: hour
                ))!.timeIntervalSince1970)
    }
}
