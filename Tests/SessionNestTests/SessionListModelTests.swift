import Foundation
import Testing

@testable import SessionNest

@Test func sessionRefreshPolicyRefreshesOnlyWhenFifteenMinutesStale() {
    let now = Date(timeIntervalSinceReferenceDate: 10_000)

    #expect(
        SessionRefreshPolicy.shouldRefresh(
            lastSuccessfulReloadAt: nil,
            now: now,
            maximumAge: 900
        )
    )
    #expect(
        !SessionRefreshPolicy.shouldRefresh(
            lastSuccessfulReloadAt: now.addingTimeInterval(-899),
            now: now,
            maximumAge: 900
        )
    )
    #expect(
        SessionRefreshPolicy.shouldRefresh(
            lastSuccessfulReloadAt: now.addingTimeInterval(-900),
            now: now,
            maximumAge: 900
        )
    )
    #expect(
        !SessionRefreshPolicy.shouldRefresh(
            lastSuccessfulReloadAt: now.addingTimeInterval(60),
            now: now,
            maximumAge: 900
        )
    )
}

@Test func automaticSessionRefreshUsesHourlyMinimumOnlyInLowPowerMode() {
    // 正常供电保留默认 15 分钟完整刷新周期。
    #expect(
        SessionNestAutomaticSessionRefreshPolicy.maximumAge(
            requestedMaximumAge: 15 * 60,
            isLowPowerModeEnabled: false
        ) == 15 * 60
    )
    // 低电量把较短的自动周期放宽到一小时。
    #expect(
        SessionNestAutomaticSessionRefreshPolicy.maximumAge(
            requestedMaximumAge: 15 * 60,
            isLowPowerModeEnabled: true
        ) == 60 * 60
    )
    // 调用方本来要求更慢时不能被低电量策略反向加快。
    #expect(
        SessionNestAutomaticSessionRefreshPolicy.maximumAge(
            requestedMaximumAge: 2 * 60 * 60,
            isLowPowerModeEnabled: true
        ) == 2 * 60 * 60
    )
}

@Test func timedTokenRetentionUsesThirtyInclusiveLocalCalendarDays() throws {
    // 固定上海时区验证自然日边界，不依赖执行测试的机器设置。
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    // 7 月 23 日的 30 天含当天窗口应从 6 月 24 日零点开始。
    let now = try #require(
        calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 23, hour: 16, minute: 30)
        ))
    let expectedCutoff = try #require(
        calendar.date(from: DateComponents(year: 2026, month: 6, day: 24)))
    let cutoff = TokenTimedRetentionPolicy.cutoff(now: now, calendar: calendar)

    // 边界采用本地自然日并包含整整 30 天。
    #expect(cutoff == Int64(expectedCutoff.timeIntervalSince1970))
    // 边界内查询可准确表示，早一秒则必须拒绝部分统计。
    #expect(TokenTimedRetentionPolicy.canRepresentExactRange(startingAt: cutoff, cutoff: cutoff))
    #expect(
        !TokenTimedRetentionPolicy.canRepresentExactRange(
            startingAt: cutoff - 1,
            cutoff: cutoff
        ))
    // 清理首次执行，同一天跳过，下一自然日恢复执行。
    #expect(TokenTimedRetentionPolicy.shouldPrune(lastPrunedAt: nil, now: now, calendar: calendar))
    #expect(
        !TokenTimedRetentionPolicy.shouldPrune(
            lastPrunedAt: now.addingTimeInterval(-60),
            now: now,
            calendar: calendar
        ))
    let nextDay = try #require(calendar.date(byAdding: .day, value: 1, to: now))
    #expect(
        TokenTimedRetentionPolicy.shouldPrune(
            lastPrunedAt: now,
            now: nextDay,
            calendar: calendar
        ))
}

@MainActor
@Test func automaticReloadCoalescesWithManualReloadInFlight() async throws {
    let fixture = try SessionModelFixture(threadID: "reload-coalescing", createRollout: false)
    defer { fixture.remove() }
    let probe = DeferredReloadProbe()
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        threadReloadOperation: { await probe.load() }
    )

    let manualReload = Task { await model.reload() }
    try await waitForTokenCondition { await probe.callCount == 1 }
    let automaticReload = Task {
        await model.reloadIfStale(maximumAge: 0)
    }
    try await Task.sleep(for: .milliseconds(20))

    #expect(await probe.callCount == 1)
    await probe.release()
    await manualReload.value
    await automaticReload.value
}

@MainActor
@Test func lightweightRateLimitRefreshPublishesSuccessAndPreservesItOnFailure() async throws {
    let fixture = try SessionModelFixture(
        threadID: "lightweight-rate-limit",
        createRollout: false
    )
    defer { fixture.remove() }
    let snapshot = try weeklyRateLimitSnapshot(usedPercent: 6)
    let probe = RateLimitRefreshProbe(snapshot: snapshot)
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        rateLimitRefreshOperation: { try await probe.load() }
    )
    model.activeThreads = [directoryThread("untouched", cwd: "/work/untouched")]

    await model.refreshRateLimits()

    #expect(model.rateLimitSnapshot == snapshot)
    #expect(model.activeThreads.map(\.id) == ["untouched"])

    await probe.failSubsequentLoads()
    await model.refreshRateLimits()

    #expect(model.rateLimitSnapshot == snapshot)
}

@MainActor
@Test func staleFullReloadUsageResponseDoesNotOverwriteNewerRefresh() async throws {
    let fixture = try SessionModelFixture(
        threadID: "stale-full-reload-usage",
        createRollout: false
    )
    defer { fixture.remove() }
    let now = Date()
    let cycleResetsAt = Int64(now.timeIntervalSince1970) + 86_400
    let staleSnapshot = try weeklyRateLimitSnapshot(
        usedPercent: 80,
        resetsAt: cycleResetsAt
    )
    let currentSnapshot = try weeklyRateLimitSnapshot(
        usedPercent: 20,
        resetsAt: cycleResetsAt
    )
    let probe = InterleavedRateLimitRefreshProbe(
        snapshots: [staleSnapshot, currentSnapshot]
    )
    let reloadThread = directoryThread("from-reload", cwd: "/work/reload")
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        rateLimitRefreshOperation: { await probe.load() },
        threadReloadOperation: { ([reloadThread], []) }
    )

    let reload = Task { await model.reload() }
    try await waitForTokenCondition { await probe.callCount == 1 }
    let refresh = Task { await model.refreshRateLimits(now: now) }
    try await waitForTokenCondition { await probe.callCount == 2 }
    await probe.release(request: 1)
    await refresh.value
    await probe.release(request: 0)
    await reload.value

    #expect(model.rateLimitSnapshot == currentSnapshot)
    #expect(model.lastSuccessfulUsageRefreshAt == now)
    #expect(model.activeThreads.map(\.id) == ["from-reload"])
}

@Suite struct SessionNestQuotaRefreshScheduleTests {
    @Test func quotaRefreshKeepsEnergyBalancedInterval() {
        #expect(SessionNestQuotaRefreshSchedule.interval == 10 * 60)
        #expect(SessionNestQuotaRefreshSchedule.tolerance == 60)
    }
}

@MainActor
@Test func lightweightRateLimitRefreshPublishesProgressAndCompletionMetadata() async throws {
    let fixture = try SessionModelFixture(
        threadID: "lightweight-rate-limit-state",
        createRollout: false
    )
    defer { fixture.remove() }
    let probe = DeferredRateLimitRefreshProbe(
        snapshot: try weeklyRateLimitSnapshot(usedPercent: 6)
    )
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        rateLimitRefreshOperation: { try await probe.load() }
    )

    let refresh = Task { await model.refreshRateLimits() }
    try await waitForTokenCondition { await probe.callCount == 1 }

    #expect(model.isRefreshingUsage)
    #expect(model.lastSuccessfulUsageRefreshAt == nil)

    await probe.release()
    await refresh.value

    #expect(!model.isRefreshingUsage)
    #expect(model.lastSuccessfulUsageRefreshAt != nil)
    #expect(model.usageRefreshErrorMessage == nil)
}

@MainActor
@Test func lightweightRateLimitRefreshPublishesFailureWithoutDiscardingSuccess() async throws {
    let fixture = try SessionModelFixture(
        threadID: "lightweight-rate-limit-failure",
        createRollout: false
    )
    defer { fixture.remove() }
    let snapshot = try weeklyRateLimitSnapshot(usedPercent: 6)
    let probe = RateLimitRefreshProbe(snapshot: snapshot)
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        rateLimitRefreshOperation: { try await probe.load() }
    )

    await model.refreshRateLimits()
    let lastSuccess = try #require(model.lastSuccessfulUsageRefreshAt)
    await probe.failSubsequentLoads()
    await model.refreshRateLimits()

    #expect(model.rateLimitSnapshot == snapshot)
    #expect(model.lastSuccessfulUsageRefreshAt == lastSuccess)
    #expect(model.usageRefreshErrorMessage != nil)
    #expect(!model.isRefreshingUsage)
}

@MainActor
@Test func lightweightRateLimitRefreshSkipsFreshSnapshot() async throws {
    let fixture = try SessionModelFixture(
        threadID: "lightweight-rate-limit-stale-policy",
        createRollout: false
    )
    defer { fixture.remove() }
    let probe = RateLimitRefreshProbe(
        snapshot: try weeklyRateLimitSnapshot(usedPercent: 6)
    )
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        rateLimitRefreshOperation: { try await probe.load() }
    )
    let firstRefresh = Date(timeIntervalSinceReferenceDate: 10_000)

    await model.refreshRateLimits(now: firstRefresh)
    await model.refreshRateLimitsIfStale(
        now: firstRefresh.addingTimeInterval(599),
        maximumAge: 600,
        isLowPowerModeEnabled: false
    )
    #expect(await probe.callCount == 1)

    await model.refreshRateLimitsIfStale(
        now: firstRefresh.addingTimeInterval(600),
        maximumAge: 600,
        isLowPowerModeEnabled: false
    )
    #expect(await probe.callCount == 2)
}

@MainActor
@Test func automaticRateLimitRefreshBacksOffFromFailedAttempt() async throws {
    // 构造始终失败的额度请求，验证自动入口不会因没有成功时间而频繁重试。
    let fixture = try SessionModelFixture(
        threadID: "rate-limit-failure-backoff",
        createRollout: false
    )
    defer { fixture.remove() }
    let probe = RateLimitRefreshProbe(
        snapshot: try weeklyRateLimitSnapshot(usedPercent: 6)
    )
    await probe.failSubsequentLoads()
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        rateLimitRefreshOperation: { try await probe.load() }
    )
    let firstAttempt = Date(timeIntervalSinceReferenceDate: 20_000)

    // 首次没有成功或尝试记录，自动入口应发起请求并记录失败时间。
    await model.refreshRateLimitsIfStale(
        now: firstAttempt,
        maximumAge: 1_800,
        isLowPowerModeEnabled: true
    )
    #expect(await probe.callCount == 1)
    #expect(model.lastSuccessfulUsageRefreshAt == nil)
    #expect(model.lastUsageRefreshAttemptAt == firstAttempt)

    // 低电量 30 分钟窗口内再次打开界面应跳过重复请求。
    await model.refreshRateLimitsIfStale(
        now: firstAttempt.addingTimeInterval(1_799),
        maximumAge: 600,
        isLowPowerModeEnabled: true
    )
    #expect(await probe.callCount == 1)

    // 到达 30 分钟边界后允许下一次自动重试。
    await model.refreshRateLimitsIfStale(
        now: firstAttempt.addingTimeInterval(1_800),
        maximumAge: 600,
        isLowPowerModeEnabled: true
    )
    #expect(await probe.callCount == 2)
}

@MainActor
@Test func failedFullReloadDoesNotImmediatelyRetryUsageRequest() async throws {
    // 完整 reload 的额度读取失败后，状态栏紧接着的轻量自动入口必须共享退避记录。
    let fixture = try SessionModelFixture(
        threadID: "reload-rate-limit-backoff",
        createRollout: false
    )
    defer { fixture.remove() }
    let probe = RateLimitRefreshProbe(
        snapshot: try weeklyRateLimitSnapshot(usedPercent: 6)
    )
    await probe.failSubsequentLoads()
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        rateLimitRefreshOperation: { try await probe.load() },
        threadReloadOperation: { ([fixture.thread], []) }
    )

    // reload 已尝试一次额度请求，并保存该尝试时间。
    await model.reload()
    let attemptedAt = try #require(model.lastUsageRefreshAttemptAt)
    #expect(await probe.callCount == 1)

    // 模拟弹框随后执行的自动轻量刷新，十分钟内不能马上发出第二次请求。
    await model.refreshRateLimitsIfStale(
        now: attemptedAt.addingTimeInterval(1),
        maximumAge: 600,
        isLowPowerModeEnabled: false
    )
    #expect(await probe.callCount == 1)
}

@MainActor
@Test func lightweightUsageRefreshPublishesResetCreditsAtomically() async throws {
    let fixture = try SessionModelFixture(
        threadID: "lightweight-usage",
        createRollout: false
    )
    defer { fixture.remove() }
    let rateLimits = try weeklyRateLimitSnapshot(usedPercent: 8)
    let credits = CodexRateLimitResetCreditsSummary(
        availableCount: 1,
        credits: [
            CodexRateLimitResetCredit(
                id: "credit-1",
                resetType: "codexRateLimits",
                status: "available",
                grantedAt: 100,
                expiresAt: 200,
                title: "Full reset",
                description: "Granted"
            )
        ]
    )
    let usage = CodexUsageSnapshot(rateLimits: rateLimits, resetCredits: credits)
    let probe = UsageRefreshProbe(snapshot: usage)
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        usageRefreshOperation: { try await probe.load() }
    )

    await model.refreshRateLimits()

    #expect(model.rateLimitSnapshot == rateLimits)
    #expect(model.resetCreditsSnapshot == credits)

    await probe.failSubsequentLoads()
    await model.refreshRateLimits()

    #expect(model.rateLimitSnapshot == rateLimits)
    #expect(model.resetCreditsSnapshot == credits)
}

@MainActor
@Test func concurrentRateLimitRefreshCallsShareOneRequest() async throws {
    let fixture = try SessionModelFixture(
        threadID: "coalesced-rate-limit",
        createRollout: false
    )
    defer { fixture.remove() }
    let probe = DeferredRateLimitRefreshProbe(
        snapshot: try weeklyRateLimitSnapshot(usedPercent: 6)
    )
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        rateLimitRefreshOperation: { try await probe.load() }
    )

    let first = Task { await model.refreshRateLimits() }
    try await waitForTokenCondition { await probe.callCount == 1 }
    let second = Task { await model.refreshRateLimits() }
    try await Task.sleep(for: .milliseconds(20))

    #expect(await probe.callCount == 1)

    await probe.release()
    await first.value
    await second.value
}

@MainActor
@Test func sessionListModelDefaultsToStatistics() throws {
    let fixture = try SessionModelFixture(threadID: "default-selection", createRollout: false)
    defer { fixture.remove() }

    let model = SessionListModel(client: fixture.client, store: fixture.store)

    #expect(model.selection == .statistics)
    #expect(model.timeFilter == .thirtyDays)
}

@MainActor
@Test func reloadImmediatelyMergesLinkedWorktreeProject() async throws {
    let fixture = try SessionModelFixture(
        threadID: "worktree-reload",
        createRollout: false
    )
    defer { fixture.remove() }
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
    let threads = [
        directoryThread("main", cwd: main.path),
        directoryThread("linked", cwd: linked.path),
    ]
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        threadReloadOperation: { (threads, []) }
    )

    await model.reload()

    #expect(model.projectTree.map(\.path) == [main.path])
    #expect(model.projectTree[0].totalCount == 2)
    try await waitForTokenCondition { model.threadProjects.count == 2 }
    #expect(
        model.threadProjects.values.allSatisfy {
            $0.resolution == .project(path: main.path)
                && $0.classifierVersion == ThreadProjectClassification.classifierVersion
        }
    )
}

@MainActor
@Test func explicitStatisticsRangeDoesNotChangeMainPanelFilter() throws {
    let fixture = try SessionModelFixture(
        threadID: "explicit-statistics-range",
        createRollout: false
    )
    defer { fixture.remove() }
    let now = Int64(Date().timeIntervalSince1970)
    let model = SessionListModel(client: fixture.client, store: fixture.store)
    model.activeThreads = [
        directoryThread("recent", cwd: "/work/recent", updatedAt: now - 86_400),
        directoryThread("older", cwd: "/work/older", updatedAt: now - 10 * 86_400),
    ]

    let snapshot = model.statisticsSnapshot(for: .sevenDays)

    #expect(snapshot.totalSessionCount == 1)
    #expect(model.timeFilter == .thirtyDays)
    #expect(model.statisticsSnapshot.totalSessionCount == 2)
}

@MainActor
@Test func quotaCycleStatisticsSnapshotPublishesExactRangeWithoutChangingMainFilter() async throws {
    let fixture = try SessionModelFixture(
        threadID: "quota-cycle-statistics",
        createRollout: false
    )
    defer { fixture.remove() }
    let now = Int64(Date().timeIntervalSince1970)
    let rateLimits = try JSONDecoder().decode(
        CodexRateLimitSnapshot.self,
        from: Data(
            """
            {"primary":{"usedPercent":6,"windowDurationMins":10080,"resetsAt":\(now + 6 * 86_400)}}
            """.utf8
        )
    )
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        rateLimitRefreshOperation: { rateLimits }
    )
    model.activeThreads = [
        directoryThread("current-cycle", cwd: "/work/current", updatedAt: now),
        directoryThread("before-cycle", cwd: "/work/old", updatedAt: now - 2 * 86_400),
    ]
    await model.refreshRateLimits()

    #expect(model.quotaCycleStatisticsSnapshot?.totalSessionCount == 1)
    #expect(model.quotaCycleTokenUsage == 0)
    #expect(model.timeFilter == .thirtyDays)
    #expect(model.statisticsSnapshot.totalSessionCount == 2)

    let missingWindowModel = SessionListModel(client: fixture.client, store: fixture.store)
    #expect(missingWindowModel.quotaCycleStatisticsSnapshot == nil)
    #expect(missingWindowModel.quotaCycleTokenUsage == nil)
}

@Test func filtersByProjectFavoriteAndText() {
    let threads = [
        CodexThread(
            id: "1", name: "Client Dashboard", preview: "Add page", cwd: "/work/sample-client",
            createdAt: 1,
            updatedAt: 20, recencyAt: nil,
            gitInfo: GitInfo(branch: "test")),
        CodexThread(
            id: "2", name: "API Investigation", preview: "Access filter", cwd: "/work/sample-api",
            createdAt: 1,
            updatedAt: 10, recencyAt: nil, gitInfo: nil),
    ]
    let metadata = ["2": ThreadMetadata(threadID: "2", isFavorite: true, collectionID: nil)]
    let tags = [SessionTag(id: "bug", name: "Bug Fix", colorHex: "#B66B52", sortOrder: 0)]
    let threadTags = ["2": Set(["bug"])]

    let all = SessionFilter.apply(
        threads: threads, metadata: metadata, tags: tags, threadTags: threadTags,
        threadProjects: [:], selection: .recent, query: "", timeFilter: .all, sortOrder: .recent,
        now: 100)
    let project = SessionFilter.apply(
        threads: threads, metadata: metadata, tags: tags, threadTags: threadTags,
        threadProjects: [:], selection: .project("/work/sample-client"), query: "",
        timeFilter: .all, sortOrder: .recent, now: 100)
    let favorite = SessionFilter.apply(
        threads: threads, metadata: metadata, tags: tags, threadTags: threadTags,
        threadProjects: [:], selection: .favorites, query: "", timeFilter: .all, sortOrder: .recent,
        now: 100)
    let searched = SessionFilter.apply(
        threads: threads, metadata: metadata, tags: tags, threadTags: threadTags,
        threadProjects: [:], selection: .recent, query: "Bug", timeFilter: .all, sortOrder: .recent,
        now: 100)

    #expect(all.map(\.id) == ["1", "2"])
    #expect(project.map(\.id) == ["1"])
    #expect(favorite.map(\.id) == ["2"])
    #expect(searched.map(\.id) == ["2"])
}

@Test func appliesTimeWindowAndTitleSort() {
    let now: Int64 = 2_000_000
    let threads = [
        CodexThread(
            id: "a", name: "Zulu", preview: "", cwd: "/work/a", createdAt: 1,
            updatedAt: now - 900_000, recencyAt: nil, gitInfo: nil),
        CodexThread(
            id: "b", name: "Alpha", preview: "", cwd: "/work/b", createdAt: 1, updatedAt: now - 100,
            recencyAt: nil, gitInfo: nil),
    ]
    let result = SessionFilter.apply(
        threads: threads, metadata: [:], tags: [], threadTags: [:], threadProjects: [:],
        selection: .recent, query: "", timeFilter: .sevenDays, sortOrder: .title, now: now)
    #expect(result.map(\.id) == ["b"])
}

@Test func revisionRejectsStaleCommit() {
    var revisions = SessionStateRevision()
    let stale = revisions.begin(isLoading: false)
    let current = revisions.begin(isLoading: false)

    #expect(!revisions.accepts(stale))
    #expect(revisions.accepts(current))
}

@Test func staleRevisionCannotClearCurrentLoadingState() {
    var revisions = SessionStateRevision()
    let stale = revisions.begin(isLoading: true)
    let current = revisions.begin(isLoading: true)
    let staleFinished = revisions.finishLoading(stale)
    let currentFinished = revisions.finishLoading(current)

    #expect(!staleFinished)
    #expect(currentFinished)
}

@Test func buildsProjectDirectoryTreeFromFullPaths() {
    let threads = [
        directoryThread("root", cwd: "/work/codex"),
        directoryThread("home", cwd: "/work/codex/sample-app"),
        directoryThread("tools", cwd: "/work/codex/sample-app/tools"),
        directoryThread("other", cwd: "/other/codex"),
    ]

    let tree = ProjectDirectoryTree.build(threads: threads, threadProjects: [:])

    #expect(tree.map(\.path) == ["/other/codex", "/work/codex"])
    #expect(tree[0].name == "codex")
    #expect(tree[0].totalCount == 1)
    #expect(tree[1].directCount == 1)
    #expect(tree[1].totalCount == 3)
    #expect(tree[1].children.map(\.path) == ["/work/codex/sample-app"])
    #expect(tree[1].children[0].totalCount == 2)
    #expect(tree[1].children[0].children.map(\.path) == ["/work/codex/sample-app/tools"])
}

@Test func projectTreeMergesLinkedWorktreeIntoMainRepository() throws {
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
    let threads = [
        directoryThread("main", cwd: main.path),
        directoryThread("linked", cwd: linked.path),
    ]
    let identityIndex = ThreadProjectIdentityIndex.build(
        threads: threads,
        fileManager: fileManager
    )

    let tree = ProjectDirectoryTree.build(
        threads: threads,
        threadProjects: [:],
        projectIdentityIndex: identityIndex
    )

    #expect(tree.map(\.path) == [main.path])
    #expect(tree[0].directCount == 2)
    #expect(tree[0].totalCount == 2)

    let selected = SessionFilter.apply(
        threads: threads,
        metadata: [:],
        tags: [],
        threadTags: [:],
        threadProjects: [:],
        projectIdentityIndex: identityIndex,
        selection: .project(main.path),
        query: "",
        timeFilter: .all,
        sortOrder: .recent,
        now: 100
    )

    #expect(Set(selected.map(\.id)) == Set(["main", "linked"]))
}

@Test func projectSelectionIncludesOnlyItsDirectorySubtree() {
    let threads = [
        directoryThread("root", cwd: "/work/codex", updatedAt: 4),
        directoryThread("home", cwd: "/work/codex/sample-app", updatedAt: 3),
        directoryThread("tools", cwd: "/work/codex/sample-app/tools", updatedAt: 2),
        directoryThread("same-name", cwd: "/other/codex", updatedAt: 5),
        directoryThread("prefix-only", cwd: "/work/codex2", updatedAt: 1),
    ]

    let root = SessionFilter.apply(
        threads: threads,
        metadata: [:],
        tags: [],
        threadTags: [:],
        threadProjects: [:],
        selection: .project("/work/codex"),
        query: "",
        timeFilter: .all,
        sortOrder: .recent,
        now: 100
    )
    let child = SessionFilter.apply(
        threads: threads,
        metadata: [:],
        tags: [],
        threadTags: [:],
        threadProjects: [:],
        selection: .project("/work/codex/sample-app"),
        query: "",
        timeFilter: .all,
        sortOrder: .recent,
        now: 100
    )

    #expect(root.map(\.id) == ["root", "home", "tools"])
    #expect(child.map(\.id) == ["home", "tools"])
}

@Test func cachedProjectPathDrivesTreeSelectionSearchAndRowName() {
    let threads = [directoryThread("root", cwd: "/work/codex", updatedAt: 4)]
    let projects = [
        "root": ThreadProjectCache(
            threadID: "root",
            resolution: .project(path: "/work/codex/sessionnest"),
            analyzedUpdatedAt: 4,
            classifierVersion: ThreadProjectClassification.classifierVersion
        )
    ]

    let tree = ProjectDirectoryTree.build(threads: threads, threadProjects: projects)
    let child = SessionFilter.apply(
        threads: threads,
        metadata: [:],
        tags: [],
        threadTags: [:],
        threadProjects: projects,
        selection: .project("/work/codex/sessionnest"),
        query: "sessionnest",
        timeFilter: .all,
        sortOrder: .recent,
        now: 100
    )

    #expect(tree[0].children.map(\.path) == ["/work/codex/sessionnest"])
    #expect(child.map(\.id) == ["root"])
    #expect(child[0].projectPath == "/work/codex/sessionnest")
    #expect(child[0].projectName == "sessionnest")
}

@Test func staleOrMissingProjectCacheNeedsAnalysis() {
    let thread = directoryThread("root", cwd: "/work/codex", updatedAt: 4)

    #expect(ThreadProjectClassification.needsAnalysis(thread: thread, cached: nil))
    #expect(
        ThreadProjectClassification.needsAnalysis(
            thread: thread,
            cached: ThreadProjectCache(
                threadID: thread.id,
                resolution: .workingDirectory(path: "/work/codex"),
                analyzedUpdatedAt: 3,
                classifierVersion: ThreadProjectClassification.classifierVersion
            )
        ))
    #expect(
        ThreadProjectClassification.needsAnalysis(
            thread: thread,
            cached: ThreadProjectCache(
                threadID: thread.id,
                resolution: .workingDirectory(path: "/work/codex"),
                analyzedUpdatedAt: thread.updatedAt,
                classifierVersion: ThreadProjectClassification.classifierVersion
            )
        ) == false)
    #expect(
        ThreadProjectClassification.needsAnalysis(
            thread: thread,
            cached: ThreadProjectCache(
                threadID: thread.id,
                resolution: .project(path: "/work/codex"),
                analyzedUpdatedAt: thread.updatedAt,
                classifierVersion: ThreadProjectClassification.classifierVersion - 1
            )
        ))
}

@Test func scratchWorkspaceWithoutCurrentCacheIsProvisionallyNoProject() {
    let thread = directoryThread(
        "scratch",
        cwd: "/Users/me/Documents/Codex/2026-07-18/session",
        updatedAt: 4
    )

    #expect(
        ThreadProjectClassification.effectiveResolution(for: thread, cached: nil) == .noProject
    )
}

@Test func normalWorkspaceWithoutCurrentCacheUsesWorkingDirectory() {
    let thread = directoryThread("normal", cwd: "/work/app/../app", updatedAt: 4)

    #expect(
        ThreadProjectClassification.effectiveResolution(for: thread, cached: nil)
            == .workingDirectory(path: "/work/app")
    )
}

@Test func unknownProjectFallsBackToRawWorkingDirectory() {
    let thread = directoryThread("root", cwd: "/work/codex/../codex", updatedAt: 4)
    let cached = ThreadProjectCache(
        threadID: thread.id,
        resolution: .workingDirectory(path: "/work/codex"),
        analyzedUpdatedAt: thread.updatedAt,
        classifierVersion: ThreadProjectClassification.classifierVersion
    )

    #expect(ThreadProjectClassification.effectivePath(for: thread, cached: cached) == "/work/codex")
}

@Test func staleProjectPathDoesNotDriveTreeSelectionOrSearch() {
    let thread = directoryThread("root", cwd: "/work/codex", updatedAt: 4)
    let projects = [
        thread.id: ThreadProjectCache(
            threadID: thread.id,
            resolution: .project(path: "/work/codex/sessionnest"),
            analyzedUpdatedAt: 3,
            classifierVersion: ThreadProjectClassification.classifierVersion
        )
    ]

    let tree = ProjectDirectoryTree.build(threads: [thread], threadProjects: projects)
    let project = SessionFilter.apply(
        threads: [thread],
        metadata: [:],
        tags: [],
        threadTags: [:],
        threadProjects: projects,
        selection: .project("/work/codex/sessionnest"),
        query: "",
        timeFilter: .all,
        sortOrder: .recent,
        now: 100
    )
    let searched = SessionFilter.apply(
        threads: [thread],
        metadata: [:],
        tags: [],
        threadTags: [:],
        threadProjects: projects,
        selection: .recent,
        query: "sessionnest",
        timeFilter: .all,
        sortOrder: .recent,
        now: 100
    )

    #expect(
        ThreadProjectClassification.effectivePath(
            for: thread,
            cached: projects[thread.id]
        ) == "/work/codex")
    #expect(tree.map(\.path) == ["/work/codex"])
    #expect(tree[0].children.isEmpty)
    #expect(project.isEmpty)
    #expect(searched.isEmpty)
}

@Test func projectTreeOmitsNoProjectScratchPathsAndKeepsResolvedRepository() {
    let scratchWithoutProject = directoryThread(
        "scratch-none",
        cwd: "/Users/me/Documents/Codex/2026-07-18/none",
        updatedAt: 4
    )
    let scratchWithProject = directoryThread(
        "scratch-project",
        cwd: "/Users/me/Documents/Codex/2026-07-18/with-project",
        updatedAt: 4
    )
    let repository = "/Users/me/Documents/Codex/2026-07-18/with-project/repository"
    let projects = [
        scratchWithoutProject.id: ThreadProjectCache(
            threadID: scratchWithoutProject.id,
            resolution: .noProject,
            analyzedUpdatedAt: 4,
            classifierVersion: ThreadProjectClassification.classifierVersion
        ),
        scratchWithProject.id: ThreadProjectCache(
            threadID: scratchWithProject.id,
            resolution: .project(path: repository),
            analyzedUpdatedAt: 4,
            classifierVersion: ThreadProjectClassification.classifierVersion
        ),
    ]

    let tree = ProjectDirectoryTree.build(
        threads: [scratchWithoutProject, scratchWithProject],
        threadProjects: projects
    )

    #expect(tree.map(\.path) == [repository])
    #expect(tree[0].directCount == 1)
    #expect(tree[0].children.isEmpty)
}

@Test func noProjectSelectionAndRawWorkingDirectorySearchRemainAvailable() {
    let scratch = directoryThread(
        "scratch",
        cwd: "/Users/me/Documents/Codex/2026-07-18/session",
        updatedAt: 4
    )
    let normal = directoryThread("normal", cwd: "/work/normal", updatedAt: 3)
    let projects = [
        scratch.id: ThreadProjectCache(
            threadID: scratch.id,
            resolution: .noProject,
            analyzedUpdatedAt: 4,
            classifierVersion: ThreadProjectClassification.classifierVersion
        )
    ]

    let noProject = SessionFilter.apply(
        threads: [scratch, normal],
        metadata: [:],
        tags: [],
        threadTags: [:],
        threadProjects: projects,
        selection: .noProject,
        query: "",
        timeFilter: .all,
        sortOrder: .recent,
        now: 100
    )
    let searched = SessionFilter.apply(
        threads: [scratch, normal],
        metadata: [:],
        tags: [],
        threadTags: [:],
        threadProjects: projects,
        selection: .recent,
        query: "2026-07-18/session",
        timeFilter: .all,
        sortOrder: .recent,
        now: 100
    )

    #expect(noProject.map(\.id) == [scratch.id])
    #expect(noProject[0].projectPath == nil)
    #expect(noProject[0].projectName == "无项目")
    #expect(searched.map(\.id) == [scratch.id])
}

@Test func classificationTaskReplacementWaitsForCanceledTaskToFinish() async {
    let probe = ClassificationTaskReplacementProbe()
    let previous = Task.detached {
        while !Task.isCancelled {
            await Task.yield()
        }
        await probe.observeCancellation()
        await probe.waitForReleaseAndFinish()
    }
    let replacement = Task {
        await ProjectClassificationTaskReplacement.cancelAndWait(for: previous)
        return (await probe.snapshot()).finished
    }

    var snapshot = await probe.snapshot()
    for _ in 0..<1_000 where !snapshot.cancellationObserved {
        try? await Task.sleep(for: .milliseconds(1))
        snapshot = await probe.snapshot()
    }

    #expect(snapshot.cancellationObserved)
    #expect(!snapshot.finished)
    await probe.release()
    #expect(await replacement.value)
}

@Test func tokenScanStatisticsSelectionShowsAllActiveThreads() {
    let threads = [
        directoryThread("a", cwd: "/work/a", updatedAt: 2),
        directoryThread("b", cwd: "/work/b", updatedAt: 1),
    ]

    let result = SessionFilter.apply(
        threads: threads,
        metadata: [:],
        tags: [],
        threadTags: [:],
        threadProjects: [:],
        selection: .statistics,
        query: "",
        timeFilter: .all,
        sortOrder: .recent,
        now: 100
    )

    #expect(result.map(\.id) == ["a", "b"])
}

@Test func tokenScanQuotaSelectionShowsAllActiveThreads() {
    let threads = [
        directoryThread("a", cwd: "/work/a", updatedAt: 2),
        directoryThread("b", cwd: "/work/b", updatedAt: 1),
    ]

    let result = SessionFilter.apply(
        threads: threads,
        metadata: [:],
        tags: [],
        threadTags: [:],
        threadProjects: [:],
        selection: .quota,
        query: "",
        timeFilter: .all,
        sortOrder: .recent,
        now: 100
    )

    #expect(result.map(\.id) == ["a", "b"])
}

@MainActor
@Test func tokenScanReloadExcludesStaleCacheUntilAppendCatchesUp() async throws {
    let fixture = try SessionModelFixture(threadID: "cached", createRollout: true)
    defer { fixture.remove() }
    let cachedResult = tokenScanResult(total: 120, dayStart: 100)
    try await fixture.store.saveThreadTokenScan(
        threadID: fixture.thread.id,
        rolloutPath: fixture.thread.path!,
        fileSize: 0,
        fileModificationTimeNS: 0,
        parserVersion: 3,
        result: cachedResult,
        rebuild: true
    )
    try Data("new content".utf8).write(to: URL(fileURLWithPath: fixture.thread.path!))
    let probe = DeferredTokenScanProbe()
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        tokenScanOperation: { _, _, baseline, _ in
            try await probe.scan(result: TokenScanResult(offset: 11, state: baseline))
        },
        threadReloadOperation: { ([fixture.thread], []) }
    )
    model.timeFilter = .all

    await model.reload()
    try await waitForTokenCondition { await probe.started }

    #expect(model.isScanningTokenUsage)
    #expect(model.threadTokenCache[fixture.thread.id]?.maximum.totalTokens == 120)
    #expect(model.threadTokenDailyUsage.map(\.usage.totalTokens) == [120])
    #expect(model.statisticsSnapshot.totalUsage == .zero)
    #expect(model.tokenScanHealth.freshCount == 0)
    #expect(model.tokenScanHealth.staleCount == 1)
    #expect(model.tokenScanHealth.failedCount == 0)
    #expect(model.errorMessage == nil)
    await probe.release()
    try await waitForTokenCondition { !model.isScanningTokenUsage }
    #expect(model.statisticsSnapshot.totalUsage.totalTokens == 120)
    #expect(model.tokenScanHealth.freshCount == 1)
    #expect(model.tokenScanHealth.staleCount == 0)
    #expect(model.tokenScanHealth.failedCount == 0)
}

@MainActor
@Test func completedTokenScanPublishesActualIOAndPrunesExpiredTimedRows() async throws {
    // 创建一个 10 字节目标文件，让诊断可以验证真实正文读取字节。
    let fixture = try SessionModelFixture(threadID: "diagnostics", createRollout: true)
    defer { fixture.remove() }
    let rolloutURL = URL(fileURLWithPath: fixture.thread.path!)
    try Data(repeating: 1, count: 10).write(to: rolloutURL)

    // 先为其他线程写入一条刚好位于 30 天边界之前的历史秒级明细。
    let cutoff = TokenTimedRetentionPolicy.cutoff(now: Date(), calendar: .current)
    let expiredEvent = cutoff - 1
    let expiredUsage = TokenUsageBreakdown(
        inputTokens: 8,
        cachedInputTokens: 4,
        outputTokens: 2,
        reasoningOutputTokens: 1,
        totalTokens: 10
    )
    try await fixture.store.saveThreadTokenScan(
        threadID: "expired",
        rolloutPath: "/expired.jsonl",
        fileSize: 1,
        fileModificationTimeNS: 1,
        parserVersion: 3,
        result: TokenScanResult(
            offset: 1,
            state: TokenScanState(
                maximum: expiredUsage,
                dailyUsage: [:],
                timedUsage: [expiredEvent: expiredUsage],
                latestEventTimestamp: expiredEvent,
                observedCheckpoint: true
            )
        ),
        rebuild: true
    )

    // 注入稳定目标和固定偏移结果，使测试不依赖真实 JSONL 解析内容。
    let target = TokenScanTarget(
        id: fixture.thread.id,
        attributionThreadID: fixture.thread.id,
        url: rolloutURL
    )
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        tokenScanOperation: { _, _, _, _ in
            TokenScanResult(
                offset: 0,
                state: TokenScanState(
                    maximum: expiredUsage,
                    dailyUsage: [:],
                    latestEventTimestamp: Int64(Date().timeIntervalSince1970),
                    observedCheckpoint: true
                )
            )
        },
        tokenScanTargetDiscoveryOperation: { _ in [target] },
        threadReloadOperation: { ([fixture.thread], []) }
    )

    // 完成一轮扫描后再读取诊断和数据库，避免断言中间状态。
    await model.reload()
    try await waitForTokenCondition { !model.isScanningTokenUsage }
    let diagnostics = try #require(model.tokenScanDiagnostics)

    // 目标实际执行一次全量扫描；未换行尾段不进入 offset，但仍应计入读取字节。
    #expect(diagnostics.targetCount == 1)
    #expect(diagnostics.tokenReadFileCount == 1)
    #expect(diagnostics.tokenReadBytes == 10)
    #expect(diagnostics.tokenCacheReuseCount == 0)
    // 首轮每日清理应删除预置的唯一过期秒级明细。
    #expect(diagnostics.prunedTimedRowCount == 1)
    #expect(
        try await fixture.store.loadThreadTokenTimedUsage(
            startingAt: expiredEvent,
            endingAt: expiredEvent
        ).isEmpty
    )
}

@MainActor
@Test func tokenReloadWithholdsParentCoverageUntilTargetDiscoveryCompletes() async throws {
    // 创建一个本地父会话，并预置与当前空日志完全匹配的可复用缓存。
    let fixture = try SessionModelFixture(threadID: "cached-parent", createRollout: true)
    defer { fixture.remove() }
    let rolloutURL = URL(fileURLWithPath: fixture.thread.path!)
    let attributes = try FileManager.default.attributesOfItem(atPath: rolloutURL.path)
    let modificationDate = try #require(attributes[.modificationDate] as? Date)
    let modificationTimeNS = Int64(
        (modificationDate.timeIntervalSince1970 * 1_000_000_000).rounded()
    )
    let cachedResult = tokenScanResult(total: 120, dayStart: 100)
    try await fixture.store.saveThreadTokenScan(
        threadID: fixture.thread.id,
        rolloutPath: rolloutURL.path,
        fileSize: 0,
        fileModificationTimeNS: modificationTimeNS,
        parserVersion: 3,
        result: cachedResult,
        rebuild: true
    )
    // 暂停目标发现，检查 reload 已发布会话但尚未掌握子代理集合时的中间状态。
    let discovery = DeferredTokenDiscoveryProbe(
        targets: [
            TokenScanTarget(
                id: fixture.thread.id,
                attributionThreadID: fixture.thread.id,
                url: rolloutURL
            )
        ]
    )
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        tokenScanTargetDiscoveryOperation: { _ in await discovery.discover() },
        threadReloadOperation: { ([fixture.thread], []) }
    )
    model.timeFilter = .all

    // reload 异步等待 discovery，让测试能观察目录发现期间的公开状态。
    let reloadTask = Task { await model.reload() }
    try await waitForTokenCondition { await discovery.started }

    // 缓存可以先载入内存，但覆盖与统计必须保持为空，不能闪现仅父日志的 120 Token。
    #expect(model.threadTokenCache[fixture.thread.id]?.maximum.totalTokens == 120)
    #expect(model.isScanningTokenUsage)
    #expect(model.tokenCoveredThreadIDs.isEmpty)
    #expect(model.tokenAttributionThreadIDs.isEmpty)
    #expect(model.statisticsSnapshot.totalUsage == .zero)
    #expect(model.quotaCycleStatisticsSnapshot == nil)

    // 完整目标返回后允许扫描发布可信覆盖，并恢复缓存中的统计。
    await discovery.release()
    await reloadTask.value
    try await waitForTokenCondition { !model.isScanningTokenUsage }
    #expect(model.tokenCoveredThreadIDs == [fixture.thread.id])
    #expect(model.statisticsSnapshot.totalUsage.totalTokens == 120)
}

@MainActor
@Test func tokenScanAttributesChildOnlyUsageAfterAnEmptyParentScan() async throws {
    let fixture = try SessionModelFixture(threadID: "parent", createRollout: true)
    defer { fixture.remove() }
    let childURL = fixture.directoryURL.appendingPathComponent("child.jsonl")
    try Data().write(to: childURL)
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        tokenScanOperation: { url, _, _, _ in
            url == childURL
                ? tokenScanResult(total: 70, dayStart: 100)
                : TokenScanResult(offset: 0, state: .empty)
        },
        tokenScanTargetDiscoveryOperation: { _ in
            [
                TokenScanTarget(
                    id: fixture.thread.id,
                    attributionThreadID: fixture.thread.id,
                    url: URL(fileURLWithPath: fixture.thread.path!)
                ),
                TokenScanTarget(
                    id: "child",
                    attributionThreadID: fixture.thread.id,
                    url: childURL
                ),
            ]
        },
        threadReloadOperation: { ([fixture.thread], []) }
    )
    model.timeFilter = .all

    await model.reload()
    try await waitForTokenCondition { !model.isScanningTokenUsage }

    #expect(model.statisticsSnapshot.totalUsage.totalTokens == 70)
    #expect(model.statisticsSnapshot.totalSessionCount == 1)
    #expect(model.statisticsSnapshot.measuredSessionCount == 1)
    #expect(model.statisticsSnapshot.sessionRows.map(\.threadID) == [fixture.thread.id])
    #expect(model.statisticsSnapshot.sessionRows.map(\.usage.totalTokens) == [70])
    #expect(model.tokenScanHealth.freshCount == 2)
    #expect(model.tokenCoveredThreadIDs == ["child"])
}

@MainActor
@Test func tokenScanExcludesPartialChildUsageWhenItsParentScanFails() async throws {
    let fixture = try SessionModelFixture(threadID: "parent", createRollout: true)
    defer { fixture.remove() }
    let parentURL = URL(fileURLWithPath: fixture.thread.path!)
    let childURL = fixture.directoryURL.appendingPathComponent("child.jsonl")
    try Data().write(to: childURL)
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        tokenScanOperation: { url, _, _, _ in
            if url == parentURL { throw TokenScanTestError.expectedFailure }
            return tokenScanResult(total: 70, dayStart: 100)
        },
        tokenScanTargetDiscoveryOperation: { _ in
            [
                TokenScanTarget(
                    id: fixture.thread.id,
                    attributionThreadID: fixture.thread.id,
                    url: parentURL
                ),
                TokenScanTarget(
                    id: "child",
                    attributionThreadID: fixture.thread.id,
                    url: childURL
                ),
            ]
        },
        threadReloadOperation: { ([fixture.thread], []) }
    )
    model.timeFilter = .all

    await model.reload()
    try await waitForTokenCondition { !model.isScanningTokenUsage }

    #expect(model.tokenScanHealth.freshTargetIDs == ["child"])
    #expect(model.tokenScanHealth.failedTargetIDs == [fixture.thread.id])
    #expect(model.tokenCoveredThreadIDs.isEmpty)
    #expect(model.statisticsSnapshot.totalUsage == .zero)
    #expect(model.statisticsSnapshot.measuredSessionCount == 0)
    #expect(model.statisticsSnapshot.sessionRows.isEmpty)
}

@MainActor
@Test func tokenScanRebuildsGrowingEmptyChildCacheBeforeCountingUsage() async throws {
    let fixture = try SessionModelFixture(threadID: "parent", createRollout: true)
    defer { fixture.remove() }
    let childURL = fixture.directoryURL.appendingPathComponent("child.jsonl")
    let lines = [
        #"{"timestamp":"2026-07-20T06:12:34.472Z","type":"session_meta","payload":{"id":"019f7e27-a0fa-7f33-a653-c4318fa5dd48","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}}}"#,
        #"{"timestamp":"2026-07-20T06:12:34.472Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":400,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":500}}}}"#,
        #"{"timestamp":"2026-07-20T06:12:34.805Z","type":"event_msg","payload":{"type":"task_started","turn_id":"019f7e26-8eb1-74f1-a607-c0c7ca678fd3"}}"#,
        #"{"timestamp":"2026-07-20T06:12:34.805Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":520,"cached_input_tokens":410,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":520}}}}"#,
        #"{"timestamp":"2026-07-20T06:12:34.855Z","type":"event_msg","payload":{"type":"task_started","turn_id":"019f7e27-a3a5-7143-bf0a-055beb48d8f9"}}"#,
        #"{"timestamp":"2026-07-20T06:13:00.996Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":580,"cached_input_tokens":450,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":580}}}}"#,
    ]
    try Data((lines[0] + "\n").utf8).write(to: childURL)
    let target = TokenScanTarget(
        id: "child",
        attributionThreadID: fixture.thread.id,
        url: childURL
    )
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        tokenScanTargetDiscoveryOperation: { _ in [target] },
        threadReloadOperation: { ([fixture.thread], []) }
    )
    model.timeFilter = .all

    await model.reload()
    try await waitForTokenCondition { !model.isScanningTokenUsage }
    #expect(model.threadTokenCache["child"]?.latestEventTimestamp == nil)
    #expect(model.tokenScanHealth.freshTargetIDs == ["child"])
    #expect(model.statisticsSnapshot.measuredSessionCount == 0)

    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: childURL)
    await model.startTokenUsageScan(for: [fixture.thread])
    try await waitForTokenCondition { !model.isScanningTokenUsage }

    #expect(model.statisticsSnapshot.totalUsage.totalTokens == 60)
    #expect(model.statisticsSnapshot.measuredSessionCount == 1)
    #expect(model.statisticsSnapshot.sessionRows.map(\.threadID) == [fixture.thread.id])
    #expect(model.statisticsSnapshot.sessionRows.map(\.usage.totalTokens) == [60])
}

@MainActor
@Test func tokenScanRebuildsGrowingChildWhileForkReplayIsStillInProgress() async throws {
    // 子代理首段包含父会话 replay 检查点，但还没有进入自己的有效任务阶段。
    let fixture = try SessionModelFixture(threadID: "parent", createRollout: true)
    defer { fixture.remove() }
    let childURL = fixture.directoryURL.appendingPathComponent("replaying-child.jsonl")
    let childID = "019f7e27-a0fa-7f33-a653-c4318fa5dd48"
    let initialLines = [
        #"{"timestamp":"2026-07-20T06:12:34.472Z","type":"session_meta","payload":{"id":"019f7e27-a0fa-7f33-a653-c4318fa5dd48","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}}}"#,
        #"{"timestamp":"2026-07-20T06:12:34.500Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":400,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":500}}}}"#,
        #"{"timestamp":"2026-07-20T06:12:34.600Z","type":"event_msg","payload":{"type":"task_started","turn_id":"019f7e26-8eb1-74f1-a607-c0c7ca678fd3"}}"#,
        #"{"timestamp":"2026-07-20T06:12:34.700Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":520,"cached_input_tokens":410,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":520}}}}"#,
    ]
    try Data((initialLines.joined(separator: "\n") + "\n").utf8).write(to: childURL)
    let target = TokenScanTarget(
        id: childID,
        attributionThreadID: fixture.thread.id,
        url: childURL
    )
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        tokenScanTargetDiscoveryOperation: { _ in [target] },
        threadReloadOperation: { ([fixture.thread], []) }
    )
    model.timeFilter = .all

    // 首次全量扫描只建立 replay 基线，不应产生子代理自身用量。
    await model.reload()
    try await waitForTokenCondition { !model.isScanningTokenUsage }
    #expect(model.threadTokenCache[childID]?.maximum.totalTokens == 520)
    #expect(model.threadTokenDailyUsage.isEmpty)
    #expect(model.statisticsSnapshot.totalUsage == .zero)

    // 在有效 task_started 之前再追加 replay 检查点，增量恢复会误把 20 Token 当成子代理用量。
    let continuedReplay =
        #"{"timestamp":"2026-07-20T06:12:34.800Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":540,"cached_input_tokens":420,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":540}}}}"#
    // 以追加方式模拟同一个子代理日志继续增长，保留首段缓存作为恢复基线。
    do {
        let appendHandle = try FileHandle(forWritingTo: childURL)
        // 完成追加后关闭句柄，让随后读取到稳定的文件大小和修改时间。
        defer { try? appendHandle.close() }
        // 定位到现有日志末尾，确保第二段不会覆盖 session_meta。
        try appendHandle.seekToEnd()
        // 写入仍处于 fork replay 的检查点，随后立即触发新一轮扫描。
        try appendHandle.write(contentsOf: Data((continuedReplay + "\n").utf8))
    }
    await model.startTokenUsageScan(for: [fixture.thread])
    try await waitForTokenCondition { !model.isScanningTokenUsage }

    // growing subagent 必须从 session_meta 重建阶段，第二段 replay 仍然不能进入统计。
    #expect(model.threadTokenCache[childID]?.maximum.totalTokens == 540)
    #expect(model.threadTokenDailyUsage.isEmpty)
    #expect(model.statisticsSnapshot.totalUsage == .zero)
}

@MainActor
@Test func tokenScanReplacementSupersedesCanceledScan() async throws {
    let fixture = try SessionModelFixture(threadID: "replacement", createRollout: true)
    defer { fixture.remove() }
    let probe = ReplacementTokenScanProbe()
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        tokenScanOperation: { _, _, _, _ in try await probe.scan() }
    )

    await model.startTokenUsageScan(for: [fixture.thread])
    try await waitForTokenCondition { await probe.callCount == 1 }
    await model.startTokenUsageScan(for: [fixture.thread])
    try await waitForTokenCondition { !model.isScanningTokenUsage }

    #expect(await probe.callCount == 2)
    #expect(model.threadTokenCache[fixture.thread.id]?.maximum.totalTokens == 200)
    #expect(model.threadTokenDailyUsage.map(\.usage.totalTokens) == [200])
    #expect(model.errorMessage == nil)
}

@MainActor
@Test func tokenScanFailureKeepsCachedUsageAndMainErrorClear() async throws {
    let fixture = try SessionModelFixture(threadID: "failure", createRollout: true)
    defer { fixture.remove() }
    let oldResult = tokenScanResult(total: 80, dayStart: 100)
    try await fixture.store.saveThreadTokenScan(
        threadID: fixture.thread.id,
        rolloutPath: fixture.directoryURL.appendingPathComponent("old.jsonl").path,
        fileSize: 1,
        fileModificationTimeNS: 1,
        parserVersion: 1,
        result: oldResult,
        rebuild: true
    )
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        tokenScanOperation: { _, _, _, _ in throw TokenScanTestError.expectedFailure },
        threadReloadOperation: { ([fixture.thread], []) }
    )

    await model.reload()
    try await waitForTokenCondition { !model.isScanningTokenUsage }

    #expect(model.threadTokenCache[fixture.thread.id]?.maximum.totalTokens == 80)
    #expect(model.threadTokenDailyUsage.map(\.usage.totalTokens) == [80])
    #expect(model.tokenScanHealth.freshCount == 0)
    #expect(model.tokenScanHealth.staleCount == 0)
    #expect(model.tokenScanHealth.failedTargetIDs == [fixture.thread.id])
    #expect(model.tokenCoveredThreadIDs.isEmpty)
    #expect(model.errorMessage == nil)
}

@MainActor
@Test func unreadableRolloutKeepsCacheButIsExcludedFromStatisticsCoverage() async throws {
    let fixture = try SessionModelFixture(threadID: "unreadable", createRollout: true)
    defer { fixture.remove() }
    let cachedResult = tokenScanResult(total: 80, dayStart: 100)
    try await fixture.store.saveThreadTokenScan(
        threadID: fixture.thread.id,
        rolloutPath: fixture.thread.path!,
        fileSize: 1,
        fileModificationTimeNS: 1,
        parserVersion: 1,
        result: cachedResult,
        rebuild: true
    )
    try FileManager.default.removeItem(atPath: fixture.thread.path!)
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        threadReloadOperation: { ([fixture.thread], []) }
    )
    model.timeFilter = .all

    await model.reload()
    try await waitForTokenCondition { !model.isScanningTokenUsage }

    #expect(model.threadTokenCache[fixture.thread.id]?.maximum.totalTokens == 80)
    #expect(model.statisticsSnapshot.totalSessionCount == 1)
    #expect(model.statisticsSnapshot.measuredSessionCount == 0)
    #expect(model.statisticsSnapshot.totalUsage == .zero)
    #expect(model.statisticsSnapshot.sessionRows.isEmpty)
}

@MainActor
@Test func tokenScanRetriesCachedIncompleteTail() async throws {
    let fixture = try SessionModelFixture(threadID: "partial", createRollout: true)
    defer { fixture.remove() }
    try Data("partial".utf8).write(to: URL(fileURLWithPath: fixture.thread.path!))
    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.thread.path!)
    let fileSize = try #require((attributes[.size] as? NSNumber)?.int64Value)
    let modificationDate = try #require(attributes[.modificationDate] as? Date)
    let modificationTimeNS = Int64(
        (modificationDate.timeIntervalSince1970 * 1_000_000_000).rounded()
    )
    try await fixture.store.saveThreadTokenScan(
        threadID: fixture.thread.id,
        rolloutPath: fixture.thread.path!,
        fileSize: fileSize,
        fileModificationTimeNS: modificationTimeNS,
        parserVersion: 1,
        result: tokenScanResult(total: 40, dayStart: 100),
        rebuild: true
    )
    let probe = OffsetTokenScanProbe()
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        tokenScanOperation: { _, offset, baseline, _ in
            await probe.record(offset: offset)
            return TokenScanResult(offset: offset, state: baseline)
        }
    )

    await model.startTokenUsageScan(for: [fixture.thread])
    try await waitForTokenCondition { !model.isScanningTokenUsage }

    #expect(await probe.offsets == [0])
    #expect(model.tokenScanHealth.freshCount == 0)
    #expect(model.tokenScanHealth.staleTargetIDs == [fixture.thread.id])
    #expect(model.tokenScanHealth.failedCount == 0)
    #expect(model.tokenCoveredThreadIDs.isEmpty)
}

private actor ClassificationTaskReplacementProbe {
    private var cancellationObserved = false
    private var released = false
    private var finished = false

    func observeCancellation() {
        cancellationObserved = true
    }

    func waitForReleaseAndFinish() async {
        while !released {
            await Task.yield()
        }
        finished = true
    }

    func release() {
        released = true
    }

    func snapshot() -> (cancellationObserved: Bool, finished: Bool) {
        (cancellationObserved, finished)
    }
}

private actor DeferredReloadProbe {
    private(set) var callCount = 0
    private var released = false

    func load() async -> ([CodexThread], [CodexThread]) {
        callCount += 1
        guard callCount == 1 else { return ([], []) }
        while !released {
            await Task.yield()
        }
        return ([], [])
    }

    func release() {
        released = true
    }
}

private actor RateLimitRefreshProbe {
    let snapshot: CodexRateLimitSnapshot
    private(set) var callCount = 0
    private var shouldFail = false

    init(snapshot: CodexRateLimitSnapshot) {
        self.snapshot = snapshot
    }

    func load() throws -> CodexRateLimitSnapshot {
        callCount += 1
        if shouldFail { throw RateLimitRefreshTestError.expectedFailure }
        return snapshot
    }

    func failSubsequentLoads() {
        shouldFail = true
    }
}

private actor UsageRefreshProbe {
    let snapshot: CodexUsageSnapshot
    private var shouldFail = false

    init(snapshot: CodexUsageSnapshot) {
        self.snapshot = snapshot
    }

    func load() throws -> CodexUsageSnapshot {
        if shouldFail { throw RateLimitRefreshTestError.expectedFailure }
        return snapshot
    }

    func failSubsequentLoads() {
        shouldFail = true
    }
}

private actor DeferredRateLimitRefreshProbe {
    let snapshot: CodexRateLimitSnapshot
    private(set) var callCount = 0
    private var released = false

    init(snapshot: CodexRateLimitSnapshot) {
        self.snapshot = snapshot
    }

    func load() async throws -> CodexRateLimitSnapshot {
        callCount += 1
        while !released {
            await Task.yield()
        }
        return snapshot
    }

    func release() {
        released = true
    }
}

private actor InterleavedRateLimitRefreshProbe {
    private let snapshots: [CodexRateLimitSnapshot]
    private var releasedRequests: Set<Int> = []
    private(set) var callCount = 0

    init(snapshots: [CodexRateLimitSnapshot]) {
        self.snapshots = snapshots
    }

    func load() async -> CodexRateLimitSnapshot {
        let request = callCount
        callCount += 1
        while !releasedRequests.contains(request) {
            await Task.yield()
        }
        return snapshots[request]
    }

    func release(request: Int) {
        releasedRequests.insert(request)
    }
}

private actor ReplacementTokenScanProbe {
    private(set) var callCount = 0

    func scan() async throws -> TokenScanResult {
        callCount += 1
        if callCount == 1 {
            try await Task.sleep(for: .seconds(60))
        }
        return tokenScanResult(total: 200, dayStart: 200)
    }
}

private actor OffsetTokenScanProbe {
    private(set) var offsets: [Int64] = []

    func record(offset: Int64) {
        offsets.append(offset)
    }
}

private actor DeferredTokenScanProbe {
    private(set) var started = false
    private var released = false

    func scan(result: TokenScanResult) async throws -> TokenScanResult {
        started = true
        while !released {
            try await Task.sleep(for: .milliseconds(1))
        }
        return result
    }

    func release() {
        released = true
    }
}

private actor DeferredTokenDiscoveryProbe {
    // discovery 返回的完整目标集合由测试固定注入。
    private let targets: [TokenScanTarget]
    // started 用于让主线程准确观察 discovery 已经挂起。
    private(set) var started = false
    // released 控制何时允许完整目标集合发布。
    private var released = false

    init(targets: [TokenScanTarget]) {
        // 保存固定目标，确保测试只验证发布时序而不依赖文件枚举。
        self.targets = targets
    }

    func discover() async -> [TokenScanTarget] {
        // 标记 discovery 已进入，唤醒测试侧中间状态断言。
        started = true
        // 未释放前持续让出执行权，模拟大型日志目录的发现延迟。
        while !released {
            await Task.yield()
        }
        // 释放后一次性返回完整目标集。
        return targets
    }

    func release() {
        // 允许挂起的 discovery 完成并继续扫描。
        released = true
    }
}

private enum TokenScanTestError: Error {
    case expectedFailure
    case timedOut
}

private enum RateLimitRefreshTestError: Error {
    case expectedFailure
}

@MainActor
private func waitForTokenCondition(_ condition: () async -> Bool) async throws {
    for _ in 0..<1_000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw TokenScanTestError.timedOut
}

private func tokenScanResult(total: Int64, dayStart: Int64) -> TokenScanResult {
    let usage = TokenUsageBreakdown(
        inputTokens: total - 20,
        cachedInputTokens: max(0, total - 40),
        outputTokens: 20,
        reasoningOutputTokens: 5,
        totalTokens: total
    )
    return TokenScanResult(
        offset: 0,
        state: TokenScanState(
            maximum: usage,
            dailyUsage: [dayStart: usage],
            latestEventTimestamp: dayStart,
            observedCheckpoint: true
        )
    )
}

private func weeklyRateLimitSnapshot(
    usedPercent: Double,
    resetsAt: Int64? = nil
) throws -> CodexRateLimitSnapshot {
    let resetsAtJSON = resetsAt.map { ",\"resetsAt\":\($0)" } ?? ""
    return try JSONDecoder().decode(
        CodexRateLimitSnapshot.self,
        from: Data(
            """
            {"primary":{"usedPercent":\(usedPercent),"windowDurationMins":10080\(resetsAtJSON)}}
            """.utf8
        )
    )
}

private struct SessionModelFixture {
    let directoryURL: URL
    let thread: CodexThread
    let store: MetadataStore
    let client: CodexClient

    init(threadID: String, createRollout: Bool) throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let rolloutURL = directoryURL.appendingPathComponent("\(threadID).jsonl")
        if createRollout {
            try Data().write(to: rolloutURL)
        }
        let thread = CodexThread(
            id: threadID,
            name: threadID,
            preview: "",
            cwd: directoryURL.path,
            createdAt: 1,
            updatedAt: 100,
            recencyAt: nil,
            gitInfo: nil,
            path: rolloutURL.path
        )
        self.directoryURL = directoryURL
        self.thread = thread
        store = try MetadataStore(
            databaseURL: directoryURL.appendingPathComponent("metadata.sqlite"))
        client = try CodexClient(executableURL: URL(fileURLWithPath: "/usr/bin/true"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func directoryThread(
    _ id: String,
    cwd: String,
    updatedAt: Int64 = 1
) -> CodexThread {
    CodexThread(
        id: id,
        name: id,
        preview: "",
        cwd: cwd,
        createdAt: 1,
        updatedAt: updatedAt,
        recencyAt: nil,
        gitInfo: nil
    )
}
