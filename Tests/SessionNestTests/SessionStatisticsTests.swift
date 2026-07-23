import Foundation
import Testing

@testable import SessionNest

@Suite("SessionStatisticsTests")
struct SessionStatisticsTests {
    @Test func persistedSnapshotInputKeyIsStableAndInvalidatesEveryStatisticInput() throws {
        let now: Int64 = 1_000
        let covered = thread("covered", activityTimestamp: 900)
        let originalUsage = daily(
            covered.id,
            day: 800,
            usage: usage(100, 80, 20, 5, 120)
        )
        func key(
            threads: [CodexThread]? = nil,
            coveredThreadIDs: Set<String>? = nil,
            dailyUsage: [ThreadTokenDailyUsage]? = nil,
            projectPath: String = "/work/project",
            usageAttributionThreadIDs: [String: String]? = nil,
            dayStart: Int64 = 0,
            timeZoneIdentifier: String = "UTC"
        ) -> String? {
            let threads = threads ?? [covered]
            return StatisticsSnapshotPersistence.inputKey(
                threads: threads,
                coveredThreadIDs: coveredThreadIDs ?? [covered.id],
                dailyUsage: dailyUsage ?? [originalUsage],
                projectAssignments: threads.map {
                    StatisticsSnapshotProjectAssignment(
                        threadID: $0.id,
                        projectPath: projectPath
                    )
                },
                usageAttributionThreadIDs: usageAttributionThreadIDs
                    ?? [covered.id: covered.id],
                dayStart: dayStart,
                timeZoneIdentifier: timeZoneIdentifier,
                now: now
            )
        }

        let original = try #require(key())
        #expect(original == key())
        #expect(
            original
                != key(
                    dailyUsage: [
                        daily(
                            covered.id,
                            day: 800,
                            usage: usage(101, 80, 20, 5, 121)
                        )
                    ])
        )
        #expect(original != key(projectPath: "/work/other"))
        #expect(original != key(coveredThreadIDs: []))
        #expect(original != key(usageAttributionThreadIDs: [covered.id: "other"]))
        #expect(original != key(dayStart: 1))
        #expect(original != key(timeZoneIdentifier: "Asia/Shanghai"))
        #expect(
            original
                != key(
                    threads: [
                        thread(
                            covered.id,
                            title: "Changed",
                            activityTimestamp: covered.activityTimestamp
                        )
                    ])
        )
        #expect(
            key(
                threads: [thread("future", activityTimestamp: now + 1)],
                coveredThreadIDs: [],
                dailyUsage: [],
                usageAttributionThreadIDs: [:]
            ) == nil
        )
    }

    @Test func tokenUsageAnomalyDetectsMaterialDoubleAndZeroForStableTargets() {
        let targetIDs: Set<String> = ["parent", "child"]
        let previous = TokenUsageScanSnapshot(
            targetIDs: targetIDs,
            totalTokens: 100_000
        )

        #expect(
            TokenUsageAnomalyDetector.detect(
                previous: previous,
                current: TokenUsageScanSnapshot(targetIDs: targetIDs, totalTokens: 200_000)
            ) == .doubled(previous: 100_000, current: 200_000)
        )
        #expect(
            TokenUsageAnomalyDetector.detect(
                previous: previous,
                current: TokenUsageScanSnapshot(targetIDs: targetIDs, totalTokens: 0)
            ) == .droppedToZero(previous: 100_000)
        )
    }

    @Test func tokenUsageAnomalyIgnoresFirstChangedScopeAndNormalGrowth() {
        let targetIDs: Set<String> = ["parent"]
        let previous = TokenUsageScanSnapshot(targetIDs: targetIDs, totalTokens: 100_000)

        #expect(
            TokenUsageAnomalyDetector.detect(
                previous: nil,
                current: TokenUsageScanSnapshot(targetIDs: targetIDs, totalTokens: 0)
            ) == nil
        )
        #expect(
            TokenUsageAnomalyDetector.detect(
                previous: previous,
                current: TokenUsageScanSnapshot(targetIDs: ["new-parent"], totalTokens: 0)
            ) == nil
        )
        #expect(
            TokenUsageAnomalyDetector.detect(
                previous: previous,
                current: TokenUsageScanSnapshot(targetIDs: targetIDs, totalTokens: 199_999)
            ) == nil
        )
        #expect(
            TokenUsageAnomalyDetector.detect(
                previous: TokenUsageScanSnapshot(targetIDs: targetIDs, totalTokens: 10),
                current: TokenUsageScanSnapshot(targetIDs: targetIDs, totalTokens: 20)
            ) == nil
        )
    }

    @Test func tokenUsageScanSnapshotCountsOnlyCoveredTargetsAndSaturatesOverflow() {
        let snapshot = TokenUsageScanSnapshot.build(
            dailyUsage: [
                daily("covered", day: 100, usage: usage(0, 0, 0, 0, .max)),
                daily("covered", day: 200, usage: usage(0, 0, 0, 0, 1)),
                daily("uncovered", day: 100, usage: usage(0, 0, 0, 0, 500)),
            ],
            coveredTargetIDs: ["covered"],
            targetIDs: ["covered", "uncovered"]
        )

        #expect(snapshot.totalTokens == .max)
        #expect(snapshot.targetIDs == ["covered", "uncovered"])
    }

    @Test func coverageReasonsCountSessionsInsteadOfChildLogs() {
        let breakdown = TokenCoverageBreakdown.build(
            eligibleSessionIDs: ["measured", "missing", "empty", "stale", "failed"],
            measuredSessionIDs: ["measured"],
            usageAttributionThreadIDs: [
                "measured-child": "measured",
                "empty-parent": "empty",
                "stale-child": "stale",
                "failed-parent": "failed",
                "failed-child": "failed",
            ],
            health: TokenScanHealth(
                freshTargetIDs: ["empty-parent"],
                staleTargetIDs: ["measured-child", "stale-child"],
                failedTargetIDs: ["failed-parent", "failed-child"]
            )
        )

        #expect(breakdown.totalSessionCount == 5)
        #expect(breakdown.measuredSessionCount == 1)
        #expect(breakdown.unmeasuredSessionCount == 4)
        #expect(breakdown.missingLogSessionCount == 1)
        #expect(breakdown.emptyLogSessionCount == 1)
        #expect(breakdown.staleLogSessionCount == 1)
        #expect(breakdown.failedLogSessionCount == 1)
    }

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

    @Test func exactRangeGroupsOnlyPostBoundaryTimedUsageIntoLocalDay() {
        let calendar = calendar(timeZone: "Asia/Shanghai")
        let dayStart = timestamp(2026, 7, 18, calendar: calendar)
        let boundary = timestamp(2026, 7, 18, hour: 11, calendar: calendar) + 24 * 60 + 52
        let now = boundary + 60
        let covered = thread("covered", activityTimestamp: now)

        let snapshot = SessionStatistics.build(
            threads: [covered],
            coveredThreadIDs: [covered.id],
            timedUsage: [
                ThreadTokenTimedUsage(
                    threadID: covered.id,
                    eventAt: boundary - 1,
                    usage: usage(90, 80, 10, 5, 100)
                ),
                ThreadTokenTimedUsage(
                    threadID: covered.id,
                    eventAt: boundary,
                    usage: usage(10, 5, 2, 1, 12)
                ),
                ThreadTokenTimedUsage(
                    threadID: covered.id,
                    eventAt: now,
                    usage: usage(20, 10, 4, 2, 24)
                ),
                ThreadTokenTimedUsage(
                    threadID: covered.id,
                    eventAt: now + 1,
                    usage: usage(70, 60, 8, 4, 80)
                ),
            ],
            threadProjects: [:],
            startingAt: boundary,
            calendar: calendar,
            now: now
        )

        #expect(snapshot.totalUsage == usage(30, 15, 6, 3, 36))
        #expect(snapshot.dailyPoints.map(\.dayStart) == [dayStart])
        #expect(snapshot.sessionRows.map(\.usage) == [usage(30, 15, 6, 3, 36)])
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
        #expect(snapshot.eligibleSessionIDs == [included.id])
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

    @Test func ninetyDayRangeUsesInclusiveLocalDayBoundary() {
        let calendar = calendar(timeZone: "Asia/Shanghai")
        let now = timestamp(2026, 7, 23, hour: 12, calendar: calendar)
        let cutoff = timestamp(2026, 4, 25, calendar: calendar)
        let included = thread("included", activityTimestamp: cutoff)
        let excluded = thread("excluded", activityTimestamp: cutoff - 1)

        let snapshot = SessionStatistics.build(
            threads: [included, excluded],
            coveredThreadIDs: [included.id, excluded.id],
            dailyUsage: [
                daily(included.id, day: cutoff, usage: usage(40, 20, 8, 4, 48)),
                daily(
                    excluded.id,
                    day: cutoff - 86_400,
                    usage: usage(90, 80, 10, 8, 100)
                ),
            ],
            threadProjects: [:],
            timeFilter: .ninetyDays,
            calendar: calendar,
            now: now
        )

        #expect(snapshot.eligibleSessionIDs == [included.id])
        #expect(snapshot.totalUsage == usage(40, 20, 8, 4, 48))
        #expect(snapshot.dailyPoints.map(\.dayStart) == [cutoff])
    }

    @Test func customDateRangeIsInclusiveAndKeepsUsageFromLaterUpdatedSession() throws {
        let calendar = calendar(timeZone: "America/New_York")
        let start = timestamp(2026, 3, 7, calendar: calendar)
        let end = timestamp(2026, 3, 9, calendar: calendar)
        let now = timestamp(2026, 3, 20, hour: 12, calendar: calendar)
        let laterUpdated = thread("later", activityTimestamp: now)
        let missingInRange = thread(
            "missing",
            activityTimestamp: timestamp(2026, 3, 8, hour: 12, calendar: calendar)
        )
        let range = try #require(
            StatisticsDateRange(
                from: Date(timeIntervalSince1970: TimeInterval(start)),
                through: Date(timeIntervalSince1970: TimeInterval(end)),
                calendar: calendar
            )
        )

        let snapshot = SessionStatistics.build(
            threads: [laterUpdated, missingInRange],
            coveredThreadIDs: [laterUpdated.id],
            dailyUsage: [
                daily(
                    laterUpdated.id,
                    day: timestamp(2026, 3, 6, calendar: calendar),
                    usage: usage(100, 50, 20, 10, 120)
                ),
                daily(laterUpdated.id, day: start, usage: usage(10, 5, 2, 1, 12)),
                daily(laterUpdated.id, day: end, usage: usage(20, 10, 4, 2, 24)),
                daily(
                    laterUpdated.id,
                    day: timestamp(2026, 3, 10, calendar: calendar),
                    usage: usage(200, 100, 40, 20, 240)
                ),
            ],
            threadProjects: [:],
            dateRange: range,
            calendar: calendar,
            now: now
        )

        #expect(snapshot.eligibleSessionIDs == [laterUpdated.id, missingInRange.id])
        #expect(snapshot.measuredSessionCount == 1)
        #expect(snapshot.totalUsage == usage(30, 15, 6, 3, 36))
        #expect(snapshot.dailyPoints.map(\.dayStart) == [start, end])
        #expect(snapshot.sessionRows.map(\.threadID) == [laterUpdated.id])

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let resolvedDates = try #require(range.resolvedDates(calendar: utcCalendar))
        #expect(
            Int64(resolvedDates.start.timeIntervalSince1970)
                == timestamp(2026, 3, 7, calendar: utcCalendar)
        )
        #expect(
            Int64(resolvedDates.end.timeIntervalSince1970)
                == timestamp(2026, 3, 9, calendar: utcCalendar)
        )
        #expect(
            StatisticsDateRange(
                from: Date(timeIntervalSince1970: TimeInterval(end)),
                through: Date(timeIntervalSince1970: TimeInterval(start)),
                calendar: calendar
            ) == nil
        )
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
                classifierVersion: ThreadProjectClassification.classifierVersion
            ),
            beta.id: ThreadProjectCache(
                threadID: beta.id,
                resolution: .project(path: "/work/projects/Alpha"),
                analyzedUpdatedAt: now,
                classifierVersion: ThreadProjectClassification.classifierVersion
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

    @Test func aggregatesMainAndLinkedWorktreeUsageIntoOneProject() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: root) }

        let main = root.appendingPathComponent("DBBridge")
        let commonGitDirectory = main.appendingPathComponent(".git")
        let linked = root.appendingPathComponent(".codex/worktrees/abcd/DBBridge")
        let linkedGitDirectory = commonGitDirectory.appendingPathComponent("worktrees/DBBridge2")
        try fileManager.createDirectory(at: linkedGitDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: linked, withIntermediateDirectories: true)
        try Data("../..\n".utf8).write(to: linkedGitDirectory.appendingPathComponent("commondir"))
        try Data("gitdir: \(linkedGitDirectory.path)\n".utf8).write(
            to: linked.appendingPathComponent(".git")
        )
        let mainThread = thread("main", cwd: main.path, activityTimestamp: 100)
        let linkedThread = thread("linked", cwd: linked.path, activityTimestamp: 100)
        let threads = [mainThread, linkedThread]
        let identityIndex = ThreadProjectIdentityIndex.build(
            threads: threads,
            fileManager: fileManager
        )

        let snapshot = SessionStatistics.build(
            threads: threads,
            coveredThreadIDs: Set(threads.map(\.id)),
            dailyUsage: [
                daily(mainThread.id, day: 100, usage: usage(80, 50, 20, 10, 100)),
                daily(linkedThread.id, day: 100, usage: usage(40, 20, 10, 5, 50)),
            ],
            threadProjects: [:],
            projectIdentityIndex: identityIndex,
            timeFilter: .all,
            calendar: calendar(timeZone: "UTC"),
            now: 1_000
        )

        #expect(snapshot.projectRows.map(\.projectPath) == [main.path])
        #expect(snapshot.projectRows.map(\.usage.totalTokens) == [150])
        #expect(Set(snapshot.sessionRows.compactMap(\.projectPath)) == Set([main.path]))
    }

    @Test func noProjectUsageStaysInTotalsButIsExcludedFromProjectRanking() {
        let projectThread = thread(
            "project",
            title: "Project",
            cwd: "/work/project",
            activityTimestamp: 100
        )
        let noProjectThread = thread(
            "no-project",
            title: "No Project",
            cwd: "/Users/me/Documents/Codex/2026-07-18/session",
            activityTimestamp: 100
        )
        let projects = [
            projectThread.id: ThreadProjectCache(
                threadID: projectThread.id,
                resolution: .project(path: "/work/project"),
                analyzedUpdatedAt: 100,
                classifierVersion: ThreadProjectClassification.classifierVersion
            ),
            noProjectThread.id: ThreadProjectCache(
                threadID: noProjectThread.id,
                resolution: .noProject,
                analyzedUpdatedAt: 100,
                classifierVersion: ThreadProjectClassification.classifierVersion
            ),
        ]

        let snapshot = SessionStatistics.build(
            threads: [projectThread, noProjectThread],
            coveredThreadIDs: [projectThread.id, noProjectThread.id],
            dailyUsage: [
                daily(projectThread.id, day: 100, usage: usage(80, 50, 20, 10, 100)),
                daily(noProjectThread.id, day: 100, usage: usage(40, 20, 10, 5, 50)),
            ],
            threadProjects: projects,
            timeFilter: .all,
            calendar: calendar(timeZone: "UTC"),
            now: 1_000
        )

        #expect(snapshot.totalUsage == usage(120, 70, 30, 15, 150))
        #expect(snapshot.sessionRows.count == 2)
        #expect(snapshot.projectRows.map(\.projectPath) == ["/work/project"])
        let noProjectRow = snapshot.sessionRows.first { $0.threadID == noProjectThread.id }
        #expect(noProjectRow?.projectPath == nil)
        #expect(noProjectRow?.projectName == "无项目")
        #expect(noProjectRow?.usage.totalTokens == 50)
    }

    @Test func projectDrilldownFiltersSessionsByExactPath() {
        let first = StatisticsSessionRow(
            threadID: "first",
            title: "First",
            projectPath: "/work/first/app",
            projectName: "app",
            workingDirectory: "/work/first/app",
            usage: usage(80, 50, 20, 10, 100)
        )
        let second = StatisticsSessionRow(
            threadID: "second",
            title: "Second",
            projectPath: "/work/second/app",
            projectName: "app",
            workingDirectory: "/work/second/app",
            usage: usage(40, 20, 10, 5, 50)
        )
        let noProject = StatisticsSessionRow(
            threadID: "no-project",
            title: "No Project",
            projectPath: nil,
            projectName: "无项目",
            workingDirectory: "/tmp/session",
            usage: usage(20, 10, 5, 2, 25)
        )
        let snapshot = StatisticsSnapshot(
            totalUsage: usage(140, 80, 35, 17, 175),
            totalSessionCount: 3,
            measuredSessionCount: 3,
            averageTokensPerMeasuredSession: 58,
            dailyPoints: [],
            projectRows: [],
            sessionRows: [first, second, noProject]
        )

        #expect(
            snapshot.sessionRows(forProjectPath: nil).map(\.threadID) == [
                "first", "second", "no-project",
            ])
        #expect(snapshot.sessionRows(forProjectPath: "/work/first/app") == [first])
        #expect(snapshot.sessionRows(forProjectPath: "/work/second/app") == [second])
        #expect(snapshot.sessionRows(forProjectPath: "/work/missing/app").isEmpty)
    }

    @Test func childOnlyUsageIsMeasuredAndAttributedToItsVisibleParent() {
        let parent = thread(
            "parent",
            title: "Parent",
            cwd: "/work/parent",
            activityTimestamp: 100
        )
        let childUsage = usage(60, 40, 10, 5, 70)

        let snapshot = SessionStatistics.build(
            threads: [parent],
            coveredThreadIDs: ["child"],
            dailyUsage: [daily("child", day: 100, usage: childUsage)],
            threadProjects: [:],
            usageAttributionThreadIDs: ["child": parent.id],
            timeFilter: .all,
            calendar: calendar(timeZone: "UTC"),
            now: 1_000
        )

        #expect(snapshot.totalSessionCount == 1)
        #expect(snapshot.measuredSessionCount == 1)
        #expect(snapshot.averageTokensPerMeasuredSession == 70)
        #expect(snapshot.totalUsage == childUsage)
        #expect(snapshot.dailyPoints.map(\.usage) == [childUsage])
        #expect(snapshot.sessionRows.map(\.threadID) == [parent.id])
        #expect(snapshot.sessionRows.map(\.usage) == [childUsage])
        #expect(snapshot.projectRows.map(\.projectPath) == [parent.cwd])
        #expect(snapshot.projectRows.map(\.usage) == [childUsage])
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
