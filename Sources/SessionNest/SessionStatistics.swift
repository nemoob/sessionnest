import Foundation

struct StatisticsDailyPoint: Identifiable, Equatable, Sendable {
    let dayStart: Int64
    let usage: TokenUsageBreakdown

    var id: Int64 { dayStart }
}

struct StatisticsProjectRow: Identifiable, Equatable, Sendable {
    let projectPath: String
    let projectName: String
    let usage: TokenUsageBreakdown

    var id: String { projectPath }
}

struct StatisticsSessionRow: Identifiable, Equatable, Sendable {
    let threadID: String
    let title: String
    let projectPath: String?
    let projectName: String
    let workingDirectory: String
    let usage: TokenUsageBreakdown

    var id: String { threadID }
}

struct StatisticsSnapshot: Equatable, Sendable {
    let totalUsage: TokenUsageBreakdown
    let totalSessionCount: Int
    let measuredSessionCount: Int
    let averageTokensPerMeasuredSession: Int64
    let dailyPoints: [StatisticsDailyPoint]
    let projectRows: [StatisticsProjectRow]
    let sessionRows: [StatisticsSessionRow]
}

enum SessionStatistics {
    static func build(
        threads: [CodexThread],
        coveredThreadIDs: Set<String>,
        dailyUsage: [ThreadTokenDailyUsage],
        threadProjects: [String: ThreadProjectCache],
        projectIdentityIndex: ThreadProjectIdentityIndex = .empty,
        timeFilter: SessionTimeFilter,
        calendar: Calendar,
        now: Int64
    ) -> StatisticsSnapshot {
        build(
            threads: threads,
            coveredThreadIDs: coveredThreadIDs,
            dailyUsage: dailyUsage,
            threadProjects: threadProjects,
            projectIdentityIndex: projectIdentityIndex,
            cutoff: cutoff(for: timeFilter, calendar: calendar, now: now),
            calendar: calendar,
            now: now
        )
    }

    static func build(
        threads: [CodexThread],
        coveredThreadIDs: Set<String>,
        timedUsage: [ThreadTokenTimedUsage],
        threadProjects: [String: ThreadProjectCache],
        projectIdentityIndex: ThreadProjectIdentityIndex = .empty,
        startingAt cutoff: Int64,
        calendar: Calendar,
        now: Int64
    ) -> StatisticsSnapshot {
        let eligibleThreads = threads.filter {
            $0.activityTimestamp >= cutoff && $0.activityTimestamp <= now
        }
        var usageByThreadAndDay: [String: [Int64: TokenUsageBreakdown]] = [:]
        for row in timedUsage where row.eventAt >= cutoff && row.eventAt <= now {
            let dayStart = Int64(
                calendar.startOfDay(
                    for: Date(timeIntervalSince1970: TimeInterval(row.eventAt))
                ).timeIntervalSince1970
            )
            usageByThreadAndDay[row.threadID, default: [:]][dayStart] =
                (usageByThreadAndDay[row.threadID]?[dayStart] ?? .zero) + row.usage
        }
        let dailyUsage = usageByThreadAndDay.flatMap { threadID, usageByDay in
            usageByDay.map { dayStart, usage in
                ThreadTokenDailyUsage(
                    threadID: threadID,
                    dayStart: dayStart,
                    usage: usage
                )
            }
        }
        let startDay = Int64(
            calendar.startOfDay(
                for: Date(timeIntervalSince1970: TimeInterval(cutoff))
            ).timeIntervalSince1970
        )

        return build(
            threads: eligibleThreads,
            coveredThreadIDs: coveredThreadIDs,
            dailyUsage: dailyUsage,
            threadProjects: threadProjects,
            projectIdentityIndex: projectIdentityIndex,
            cutoff: startDay,
            calendar: calendar,
            now: now
        )
    }

    static func build(
        threads: [CodexThread],
        coveredThreadIDs: Set<String>,
        dailyUsage: [ThreadTokenDailyUsage],
        threadProjects: [String: ThreadProjectCache],
        projectIdentityIndex: ThreadProjectIdentityIndex = .empty,
        startingAt cutoff: Int64,
        calendar: Calendar,
        now: Int64
    ) -> StatisticsSnapshot {
        build(
            threads: threads,
            coveredThreadIDs: coveredThreadIDs,
            dailyUsage: dailyUsage,
            threadProjects: threadProjects,
            projectIdentityIndex: projectIdentityIndex,
            cutoff: cutoff,
            calendar: calendar,
            now: now
        )
    }

    private static func build(
        threads: [CodexThread],
        coveredThreadIDs: Set<String>,
        dailyUsage: [ThreadTokenDailyUsage],
        threadProjects: [String: ThreadProjectCache],
        projectIdentityIndex: ThreadProjectIdentityIndex,
        cutoff: Int64?,
        calendar: Calendar,
        now: Int64
    ) -> StatisticsSnapshot {
        let todayStart = Int64(
            calendar.startOfDay(
                for: Date(timeIntervalSince1970: TimeInterval(now))
            ).timeIntervalSince1970)
        let eligibleThreadByID = threads.filter { thread in
            guard let cutoff else { return true }
            return thread.activityTimestamp >= cutoff && thread.activityTimestamp <= now
        }.reduce(into: [String: CodexThread]()) {
            $0[$1.id] = $1
        }
        let rangeUsage = dailyUsage.filter { row in
            guard eligibleThreadByID[row.threadID] != nil,
                coveredThreadIDs.contains(row.threadID),
                !row.usage.isZero
            else { return false }
            guard let cutoff else { return true }
            return row.dayStart >= cutoff && row.dayStart <= todayStart
        }

        var usageByDay: [Int64: TokenUsageBreakdown] = [:]
        var usageByThread: [String: TokenUsageBreakdown] = [:]
        for row in rangeUsage {
            usageByDay[row.dayStart] = (usageByDay[row.dayStart] ?? .zero) + row.usage
            usageByThread[row.threadID] = (usageByThread[row.threadID] ?? .zero) + row.usage
        }

        let measuredThreadByID = eligibleThreadByID.filter {
            coveredThreadIDs.contains($0.key)
        }
        let sessionRows = measuredThreadByID.map { threadID, thread in
            let resolution = ThreadProjectClassification.effectiveResolution(
                for: thread,
                cached: threadProjects[threadID],
                projectIdentityIndex: projectIdentityIndex
            )
            let projectPath = resolution.projectPath
            return StatisticsSessionRow(
                threadID: threadID,
                title: thread.displayTitle,
                projectPath: projectPath,
                projectName: projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? "无项目",
                workingDirectory: thread.cwd,
                usage: usageByThread[threadID] ?? .zero
            )
        }.sorted(by: sessionSort)

        var usageByProject: [String: TokenUsageBreakdown] = [:]
        for row in sessionRows where !row.usage.isZero {
            guard let projectPath = row.projectPath else { continue }
            usageByProject[projectPath] = (usageByProject[projectPath] ?? .zero) + row.usage
        }
        let projectRows = usageByProject.map { path, usage in
            StatisticsProjectRow(
                projectPath: path,
                projectName: URL(fileURLWithPath: path).lastPathComponent,
                usage: usage
            )
        }.sorted(by: projectSort)

        let totalUsage = usageByDay.values.reduce(.zero, +)
        let measuredSessionCount = measuredThreadByID.count
        return StatisticsSnapshot(
            totalUsage: totalUsage,
            totalSessionCount: eligibleThreadByID.count,
            measuredSessionCount: measuredSessionCount,
            averageTokensPerMeasuredSession: measuredSessionCount == 0
                ? 0
                : totalUsage.totalTokens / Int64(measuredSessionCount),
            dailyPoints: usageByDay.map {
                StatisticsDailyPoint(dayStart: $0.key, usage: $0.value)
            }.sorted { $0.dayStart < $1.dayStart },
            projectRows: projectRows,
            sessionRows: sessionRows
        )
    }

    private static func cutoff(
        for timeFilter: SessionTimeFilter,
        calendar: Calendar,
        now: Int64
    ) -> Int64? {
        let dayCount: Int
        switch timeFilter {
        case .all:
            return nil
        case .sevenDays:
            dayCount = 7
        case .thirtyDays:
            dayCount = 30
        }
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(now)))
        let firstDay = calendar.date(byAdding: .day, value: 1 - dayCount, to: today) ?? today
        return Int64(firstDay.timeIntervalSince1970)
    }

    private static func projectSort(_ lhs: StatisticsProjectRow, _ rhs: StatisticsProjectRow)
        -> Bool
    {
        if lhs.usage.totalTokens != rhs.usage.totalTokens {
            return lhs.usage.totalTokens > rhs.usage.totalTokens
        }
        let comparison = lhs.projectName.localizedCaseInsensitiveCompare(rhs.projectName)
        return comparison == .orderedSame
            ? lhs.projectPath < rhs.projectPath
            : comparison == .orderedAscending
    }

    private static func sessionSort(_ lhs: StatisticsSessionRow, _ rhs: StatisticsSessionRow)
        -> Bool
    {
        if lhs.usage.totalTokens != rhs.usage.totalTokens {
            return lhs.usage.totalTokens > rhs.usage.totalTokens
        }
        let comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        return comparison == .orderedSame
            ? lhs.threadID < rhs.threadID
            : comparison == .orderedAscending
    }
}
