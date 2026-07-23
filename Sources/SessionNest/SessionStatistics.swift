import CryptoKit
import Foundation

struct StatisticsDailyPoint: Codable, Identifiable, Equatable, Sendable {
    let dayStart: Int64
    let usage: TokenUsageBreakdown

    var id: Int64 { dayStart }
}

struct StatisticsDateRange: Equatable, Hashable, Sendable {
    let startDay: Int64
    let endDay: Int64
    let timeZoneIdentifier: String

    init?(from startDate: Date, through endDate: Date, calendar: Calendar = .current) {
        let startDay = Int64(calendar.startOfDay(for: startDate).timeIntervalSince1970)
        let endDay = Int64(calendar.startOfDay(for: endDate).timeIntervalSince1970)
        guard startDay <= endDay else { return nil }
        self.startDay = startDay
        self.endDay = endDay
        timeZoneIdentifier = calendar.timeZone.identifier
    }

    func resolvedDates(calendar: Calendar) -> (start: Date, end: Date)? {
        var sourceCalendar = calendar
        guard let sourceTimeZone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        sourceCalendar.timeZone = sourceTimeZone
        let components: Set<Calendar.Component> = [.era, .year, .month, .day]
        let startComponents = sourceCalendar.dateComponents(
            components,
            from: Date(timeIntervalSince1970: TimeInterval(startDay))
        )
        let endComponents = sourceCalendar.dateComponents(
            components,
            from: Date(timeIntervalSince1970: TimeInterval(endDay))
        )
        guard let start = calendar.date(from: startComponents),
            let end = calendar.date(from: endComponents)
        else { return nil }
        return (start, end)
    }

    func resolvedBounds(
        calendar: Calendar,
        now: Int64
    ) -> (startDay: Int64, endDay: Int64, endingTimestamp: Int64)? {
        guard let dates = resolvedDates(calendar: calendar),
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dates.end)
        else { return nil }
        let startDay = Int64(dates.start.timeIntervalSince1970)
        let endDay = Int64(dates.end.timeIntervalSince1970)
        guard startDay <= endDay else { return nil }
        return (
            startDay,
            endDay,
            min(Int64(nextDay.timeIntervalSince1970) - 1, now)
        )
    }
}

struct StatisticsProjectRow: Codable, Identifiable, Equatable, Sendable {
    let projectPath: String
    let projectName: String
    let usage: TokenUsageBreakdown

    var id: String { projectPath }
}

struct StatisticsSessionRow: Codable, Identifiable, Equatable, Sendable {
    let threadID: String
    let title: String
    let projectPath: String?
    let projectName: String
    let workingDirectory: String
    let usage: TokenUsageBreakdown

    var id: String { threadID }
}

struct StatisticsSnapshot: Codable, Equatable, Sendable {
    let totalUsage: TokenUsageBreakdown
    let totalSessionCount: Int
    let measuredSessionCount: Int
    let averageTokensPerMeasuredSession: Int64
    let dailyPoints: [StatisticsDailyPoint]
    let projectRows: [StatisticsProjectRow]
    let sessionRows: [StatisticsSessionRow]
    // 保留当前统计范围的会话集合，供覆盖原因按会话而不是按子代理日志计数。
    let eligibleSessionIDs: Set<String>

    init(
        totalUsage: TokenUsageBreakdown,
        totalSessionCount: Int,
        measuredSessionCount: Int,
        averageTokensPerMeasuredSession: Int64,
        dailyPoints: [StatisticsDailyPoint],
        projectRows: [StatisticsProjectRow],
        sessionRows: [StatisticsSessionRow],
        eligibleSessionIDs: Set<String> = []
    ) {
        self.totalUsage = totalUsage
        self.totalSessionCount = totalSessionCount
        self.measuredSessionCount = measuredSessionCount
        self.averageTokensPerMeasuredSession = averageTokensPerMeasuredSession
        self.dailyPoints = dailyPoints
        self.projectRows = projectRows
        self.sessionRows = sessionRows
        self.eligibleSessionIDs = eligibleSessionIDs
    }

    func sessionRows(forProjectPath projectPath: String?) -> [StatisticsSessionRow] {
        guard let projectPath else { return sessionRows }
        return sessionRows.filter { $0.projectPath == projectPath }
    }
}

struct StatisticsSnapshotProjectAssignment: Codable, Equatable, Sendable {
    let threadID: String
    let projectPath: String?
}

enum StatisticsSnapshotPersistence {
    private static let schemaVersion = 1

    static func inputKey(
        threads: [CodexThread],
        coveredThreadIDs: Set<String>,
        dailyUsage: [ThreadTokenDailyUsage],
        projectAssignments: [StatisticsSnapshotProjectAssignment],
        usageAttributionThreadIDs: [String: String],
        dayStart: Int64,
        timeZoneIdentifier: String,
        now: Int64,
        applicationVersion: String? = nil
    ) -> String? {
        // 未来活动时间会随时钟推进改变范围归属，遇到该异常时禁用跨启动复用。
        guard threads.allSatisfy({ $0.activityTimestamp <= now }) else { return nil }
        let input = Input(
            schemaVersion: schemaVersion,
            applicationVersion: applicationVersion
                ?? Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String
                ?? "development",
            dayStart: dayStart,
            timeZoneIdentifier: timeZoneIdentifier,
            threads: threads.map {
                ThreadInput(
                    id: $0.id,
                    title: $0.displayTitle,
                    workingDirectory: $0.cwd,
                    activityTimestamp: $0.activityTimestamp
                )
            },
            coveredThreadIDs: coveredThreadIDs.sorted(),
            dailyUsage: dailyUsage.sorted(by: dailyUsageSort),
            projectAssignments: projectAssignments,
            usageAttributions: usageAttributionThreadIDs.map {
                UsageAttribution(targetThreadID: $0.key, visibleThreadID: $0.value)
            }.sorted {
                $0.targetThreadID == $1.targetThreadID
                    ? $0.visibleThreadID < $1.visibleThreadID
                    : $0.targetThreadID < $1.targetThreadID
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(input) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func dailyUsageSort(
        _ lhs: ThreadTokenDailyUsage,
        _ rhs: ThreadTokenDailyUsage
    ) -> Bool {
        if lhs.threadID != rhs.threadID { return lhs.threadID < rhs.threadID }
        if lhs.dayStart != rhs.dayStart { return lhs.dayStart < rhs.dayStart }
        let left = lhs.usage
        let right = rhs.usage
        if left.inputTokens != right.inputTokens {
            return left.inputTokens < right.inputTokens
        }
        if left.cachedInputTokens != right.cachedInputTokens {
            return left.cachedInputTokens < right.cachedInputTokens
        }
        if left.outputTokens != right.outputTokens {
            return left.outputTokens < right.outputTokens
        }
        if left.reasoningOutputTokens != right.reasoningOutputTokens {
            return left.reasoningOutputTokens < right.reasoningOutputTokens
        }
        return left.totalTokens < right.totalTokens
    }

    private struct Input: Encodable {
        let schemaVersion: Int
        let applicationVersion: String
        let dayStart: Int64
        let timeZoneIdentifier: String
        let threads: [ThreadInput]
        let coveredThreadIDs: [String]
        let dailyUsage: [ThreadTokenDailyUsage]
        let projectAssignments: [StatisticsSnapshotProjectAssignment]
        let usageAttributions: [UsageAttribution]
    }

    private struct ThreadInput: Encodable {
        let id: String
        let title: String
        let workingDirectory: String
        let activityTimestamp: Int64
    }

    private struct UsageAttribution: Encodable {
        let targetThreadID: String
        let visibleThreadID: String
    }
}

struct TokenCoverageBreakdown: Equatable, Sendable {
    let totalSessionCount: Int
    let measuredSessionCount: Int
    let missingLogSessionCount: Int
    let emptyLogSessionCount: Int
    let staleLogSessionCount: Int
    let failedLogSessionCount: Int

    var unmeasuredSessionCount: Int {
        missingLogSessionCount + emptyLogSessionCount + staleLogSessionCount
            + failedLogSessionCount
    }

    static func build(
        eligibleSessionIDs: Set<String>,
        measuredSessionIDs: Set<String>,
        usageAttributionThreadIDs: [String: String],
        health: TokenScanHealth
    ) -> Self {
        let measuredSessionIDs = measuredSessionIDs.intersection(eligibleSessionIDs)
        let targetIDsBySession = Dictionary(
            grouping: usageAttributionThreadIDs.keys,
            by: { usageAttributionThreadIDs[$0] ?? $0 }
        )
        var missingLogSessionCount = 0
        var emptyLogSessionCount = 0
        var staleLogSessionCount = 0
        var failedLogSessionCount = 0

        for sessionID in eligibleSessionIDs.subtracting(measuredSessionIDs) {
            let targetIDs = Set(targetIDsBySession[sessionID] ?? [])
            guard !targetIDs.isEmpty else {
                missingLogSessionCount += 1
                continue
            }
            // 一个子代理日志失败就会撤下整场会话覆盖，因此失败优先于待更新。
            if !health.failedTargetIDs.isDisjoint(with: targetIDs) {
                failedLogSessionCount += 1
            } else if !health.staleTargetIDs.isDisjoint(with: targetIDs) {
                staleLogSessionCount += 1
            } else {
                // 目标均已追平但仍未覆盖，表示日志中没有可统计的 Token 事件。
                emptyLogSessionCount += 1
            }
        }

        return Self(
            totalSessionCount: eligibleSessionIDs.count,
            measuredSessionCount: measuredSessionIDs.count,
            missingLogSessionCount: missingLogSessionCount,
            emptyLogSessionCount: emptyLogSessionCount,
            staleLogSessionCount: staleLogSessionCount,
            failedLogSessionCount: failedLogSessionCount
        )
    }
}

struct TokenUsageScanSnapshot: Equatable, Sendable {
    let targetIDs: Set<String>
    let totalTokens: Int64

    static func build(
        dailyUsage: [ThreadTokenDailyUsage],
        coveredTargetIDs: Set<String>,
        targetIDs: Set<String>
    ) -> Self {
        let measuredTargetIDs = coveredTargetIDs.intersection(targetIDs)
        let totalTokens = dailyUsage.lazy
            .filter { measuredTargetIDs.contains($0.threadID) }
            .reduce(Int64.zero) { total, row in
                let (sum, overflow) = total.addingReportingOverflow(
                    max(0, row.usage.totalTokens)
                )
                return overflow ? .max : sum
            }
        return Self(targetIDs: targetIDs, totalTokens: totalTokens)
    }
}

enum TokenUsageAnomaly: Equatable, Sendable {
    case droppedToZero(previous: Int64)
    case doubled(previous: Int64, current: Int64)

    var noticeText: String {
        switch self {
        case .droppedToZero(let previous):
            "全量 Token 从 \(previous.formatted()) 降为 0，可能存在日志或扫描异常，请刷新后查看扫描诊断。"
        case .doubled(let previous, let current):
            "全量 Token 从 \(previous.formatted()) 增至 \(current.formatted())（至少 2 倍），"
                + "请核对日志变更与扫描诊断。"
        }
    }
}

enum TokenUsageAnomalyDetector {
    // 小额会话在早期自然翻倍很常见，只提示绝对增量达到 10 万的物质性跳变。
    static let minimumSpikeIncreaseTokens: Int64 = 100_000

    static func detect(
        previous: TokenUsageScanSnapshot?,
        current: TokenUsageScanSnapshot
    ) -> TokenUsageAnomaly? {
        guard let previous,
            !current.targetIDs.isEmpty,
            previous.targetIDs == current.targetIDs,
            previous.totalTokens > 0
        else { return nil }

        if current.totalTokens == 0 {
            return .droppedToZero(previous: previous.totalTokens)
        }
        guard current.totalTokens > previous.totalTokens else { return nil }
        let (increase, increaseOverflow) = current.totalTokens.subtractingReportingOverflow(
            previous.totalTokens
        )
        let (doubled, doubledOverflow) = previous.totalTokens.multipliedReportingOverflow(by: 2)
        guard !increaseOverflow,
            !doubledOverflow,
            increase >= minimumSpikeIncreaseTokens,
            current.totalTokens >= doubled
        else { return nil }
        return .doubled(previous: previous.totalTokens, current: current.totalTokens)
    }
}

enum SessionStatistics {
    static func build(
        threads: [CodexThread],
        coveredThreadIDs: Set<String>,
        dailyUsage: [ThreadTokenDailyUsage],
        threadProjects: [String: ThreadProjectCache],
        projectIdentityIndex: ThreadProjectIdentityIndex = .empty,
        usageAttributionThreadIDs: [String: String] = [:],
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
            usageAttributionThreadIDs: usageAttributionThreadIDs,
            cutoff: cutoff(for: timeFilter, calendar: calendar, now: now),
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
        usageAttributionThreadIDs: [String: String] = [:],
        dateRange: StatisticsDateRange,
        calendar: Calendar,
        now: Int64
    ) -> StatisticsSnapshot {
        guard let bounds = dateRange.resolvedBounds(calendar: calendar, now: now) else {
            return build(
                threads: [],
                coveredThreadIDs: coveredThreadIDs,
                dailyUsage: [],
                threadProjects: threadProjects,
                projectIdentityIndex: projectIdentityIndex,
                usageAttributionThreadIDs: usageAttributionThreadIDs,
                cutoff: now,
                calendar: calendar,
                now: now
            )
        }
        let effectiveEndDay = Int64(
            calendar.startOfDay(
                for: Date(timeIntervalSince1970: TimeInterval(bounds.endingTimestamp))
            ).timeIntervalSince1970
        )
        let rangeEndDay = min(bounds.endDay, effectiveEndDay)
        guard bounds.startDay <= rangeEndDay else {
            return build(
                threads: [],
                coveredThreadIDs: coveredThreadIDs,
                dailyUsage: [],
                threadProjects: threadProjects,
                projectIdentityIndex: projectIdentityIndex,
                usageAttributionThreadIDs: usageAttributionThreadIDs,
                cutoff: bounds.startDay,
                calendar: calendar,
                now: bounds.endingTimestamp
            )
        }

        // 历史区间内有 Token 的会话即使后来继续更新，也必须保留在统计结果中。
        let usageThreadIDs = Set(
            dailyUsage.compactMap { row -> String? in
                guard coveredThreadIDs.contains(row.threadID),
                    !row.usage.isZero,
                    row.dayStart >= bounds.startDay,
                    row.dayStart <= rangeEndDay
                else { return nil }
                return usageAttributionThreadIDs[row.threadID] ?? row.threadID
            }
        )
        return build(
            threads: threads,
            coveredThreadIDs: coveredThreadIDs,
            dailyUsage: dailyUsage,
            threadProjects: threadProjects,
            projectIdentityIndex: projectIdentityIndex,
            usageAttributionThreadIDs: usageAttributionThreadIDs,
            cutoff: bounds.startDay,
            additionalEligibleThreadIDs: usageThreadIDs,
            calendar: calendar,
            now: bounds.endingTimestamp
        )
    }

    static func build(
        threads: [CodexThread],
        coveredThreadIDs: Set<String>,
        timedUsage: [ThreadTokenTimedUsage],
        threadProjects: [String: ThreadProjectCache],
        projectIdentityIndex: ThreadProjectIdentityIndex = .empty,
        usageAttributionThreadIDs: [String: String] = [:],
        startingAt cutoff: Int64,
        calendar: Calendar,
        now: Int64
    ) -> StatisticsSnapshot {
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

        return build(
            threads: threads,
            coveredThreadIDs: coveredThreadIDs,
            timedDailyUsage: dailyUsage,
            threadProjects: threadProjects,
            projectIdentityIndex: projectIdentityIndex,
            usageAttributionThreadIDs: usageAttributionThreadIDs,
            startingAt: cutoff,
            calendar: calendar,
            now: now
        )
    }

    static func build(
        threads: [CodexThread],
        coveredThreadIDs: Set<String>,
        timedDailyUsage: [ThreadTokenDailyUsage],
        threadProjects: [String: ThreadProjectCache],
        projectIdentityIndex: ThreadProjectIdentityIndex = .empty,
        usageAttributionThreadIDs: [String: String] = [:],
        startingAt cutoff: Int64,
        calendar: Calendar,
        now: Int64
    ) -> StatisticsSnapshot {
        let eligibleThreads = threads.filter {
            $0.activityTimestamp >= cutoff && $0.activityTimestamp <= now
        }
        let startDay = Int64(
            calendar.startOfDay(
                for: Date(timeIntervalSince1970: TimeInterval(cutoff))
            ).timeIntervalSince1970
        )
        return build(
            threads: eligibleThreads,
            coveredThreadIDs: coveredThreadIDs,
            dailyUsage: timedDailyUsage,
            threadProjects: threadProjects,
            projectIdentityIndex: projectIdentityIndex,
            usageAttributionThreadIDs: usageAttributionThreadIDs,
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
        usageAttributionThreadIDs: [String: String] = [:],
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
            usageAttributionThreadIDs: usageAttributionThreadIDs,
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
        usageAttributionThreadIDs: [String: String],
        cutoff: Int64?,
        additionalEligibleThreadIDs: Set<String> = [],
        calendar: Calendar,
        now: Int64
    ) -> StatisticsSnapshot {
        let todayStart = Int64(
            calendar.startOfDay(
                for: Date(timeIntervalSince1970: TimeInterval(now))
            ).timeIntervalSince1970)
        let eligibleThreadByID = threads.filter { thread in
            guard let cutoff else { return true }
            return additionalEligibleThreadIDs.contains(thread.id)
                || (thread.activityTimestamp >= cutoff && thread.activityTimestamp <= now)
        }.reduce(into: [String: CodexThread]()) {
            $0[$1.id] = $1
        }
        let rangeUsage = dailyUsage.compactMap { row -> (ThreadTokenDailyUsage, String)? in
            let attributionThreadID = usageAttributionThreadIDs[row.threadID] ?? row.threadID
            guard eligibleThreadByID[attributionThreadID] != nil,
                coveredThreadIDs.contains(row.threadID),
                !row.usage.isZero
            else { return nil }
            guard let cutoff else { return (row, attributionThreadID) }
            return row.dayStart >= cutoff && row.dayStart <= todayStart
                ? (row, attributionThreadID) : nil
        }

        var usageByDay: [Int64: TokenUsageBreakdown] = [:]
        var usageByThread: [String: TokenUsageBreakdown] = [:]
        for (row, attributionThreadID) in rangeUsage {
            usageByDay[row.dayStart] = (usageByDay[row.dayStart] ?? .zero) + row.usage
            usageByThread[attributionThreadID] =
                (usageByThread[attributionThreadID] ?? .zero) + row.usage
        }

        let measuredThreadIDs = Set(
            coveredThreadIDs.map {
                usageAttributionThreadIDs[$0] ?? $0
            }
        )
        let measuredThreadByID = eligibleThreadByID.filter {
            measuredThreadIDs.contains($0.key)
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
            sessionRows: sessionRows,
            eligibleSessionIDs: Set(eligibleThreadByID.keys)
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
        case .ninetyDays:
            dayCount = 90
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
