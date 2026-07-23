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

@Test func tokenParserVersionTracksLocalTimeZone() throws {
    let utc = try #require(TimeZone(identifier: "UTC"))
    let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))

    #expect(TokenParserVersion.value(timeZone: utc) == TokenParserVersion.value(timeZone: utc))
    #expect(
        TokenParserVersion.value(timeZone: utc)
            != TokenParserVersion.value(timeZone: shanghai)
    )
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
@Test func concurrentForegroundRefreshEntriesShareReloadUsageRequest() async throws {
    let fixture = try SessionModelFixture(
        threadID: "foreground-refresh-coalescing",
        createRollout: false
    )
    defer { fixture.remove() }
    let probe = DeferredRateLimitRefreshProbe(
        snapshot: try weeklyRateLimitSnapshot(usedPercent: 6)
    )
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        rateLimitRefreshOperation: { try await probe.load() },
        tokenScanTargetDiscoveryOperation: { _ in [] },
        threadReloadOperation: { ([fixture.thread], []) }
    )

    let firstEntry = Task {
        await model.reloadIfStale()
        await model.refreshRateLimitsIfStale()
    }
    try await waitForTokenCondition { await probe.callCount == 1 }
    let secondEntry = Task {
        await model.reloadIfStale()
        await model.refreshRateLimitsIfStale()
    }
    try await Task.sleep(for: .milliseconds(20))

    #expect(await probe.callCount == 1)
    await probe.release()
    await firstEntry.value
    await secondEntry.value
    #expect(await probe.callCount == 1)
}

@MainActor
@Test func automaticReloadUsesObservedCodexChangesWhenMonitorIsAvailable() async throws {
    let fixture = try SessionModelFixture(threadID: "observed-change-refresh", createRollout: false)
    defer { fixture.remove() }
    let probe = ReloadCountProbe()
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        tokenScanTargetDiscoveryOperation: { _ in [] },
        threadReloadOperation: { await probe.load() }
    )
    model.enableCodexDataChangeMonitoring()

    // 首次打开仍需加载；监听模式下随后不再因时间过期重复全量刷新。
    await model.reloadIfStale(maximumAge: 0)
    await model.reloadIfStale(
        now: Date.distantFuture,
        maximumAge: 0,
        isLowPowerModeEnabled: false
    )
    #expect(await probe.callCount == 1)

    // 只有收到相关文件变化后，下次自动入口才执行完整刷新。
    model.codexDataDidChange()
    await model.reloadIfStale(
        now: Date.distantFuture,
        maximumAge: .infinity,
        isLowPowerModeEnabled: true
    )
    #expect(await probe.callCount == 2)
}

@MainActor
@Test func archiveAndUnarchiveMoveTheLocalThreadWithoutReloading() async throws {
    let fixture = try SessionModelFixture(threadID: "archive-local", createRollout: false)
    defer { fixture.remove() }
    let archiveProbe = ThreadArchiveProbe()
    let reloadProbe = ReloadCountProbe()
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        threadReloadOperation: { await reloadProbe.load() },
        threadArchiveOperation: { await archiveProbe.apply(threadID: $0, archived: $1) }
    )
    model.activeThreads = [fixture.thread]
    model.metadata[fixture.thread.id] = ThreadMetadata(
        threadID: fixture.thread.id,
        isFavorite: true,
        collectionID: nil
    )

    await model.archive(threadID: fixture.thread.id)

    #expect(model.activeThreads.isEmpty)
    #expect(model.archivedThreads.map(\.id) == [fixture.thread.id])
    #expect(model.metadata[fixture.thread.id]?.isFavorite == true)
    #expect(await reloadProbe.callCount == 0)

    await model.unarchive(threadID: fixture.thread.id)

    #expect(model.activeThreads.map(\.id) == [fixture.thread.id])
    #expect(model.archivedThreads.isEmpty)
    #expect(
        await archiveProbe.requests == [
            ThreadArchiveRequest(threadID: fixture.thread.id, archived: true),
            ThreadArchiveRequest(threadID: fixture.thread.id, archived: false),
        ])
    #expect(await reloadProbe.callCount == 0)
}

@MainActor
@Test func failedArchiveKeepsTheLocalThreadInPlace() async throws {
    let fixture = try SessionModelFixture(threadID: "archive-failure", createRollout: false)
    defer { fixture.remove() }
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        threadArchiveOperation: { _, _ in throw ThreadArchiveProbeError.expectedFailure }
    )
    model.activeThreads = [fixture.thread]

    await model.archive(threadID: fixture.thread.id)

    #expect(model.activeThreads.map(\.id) == [fixture.thread.id])
    #expect(model.archivedThreads.isEmpty)
    #expect(model.errorMessage != nil)
}

@MainActor
@Test func batchFavoriteAndArchiveKeepFailedItemsSelectedForRetry() async throws {
    let fixture = try SessionModelFixture(threadID: "batch-actions", createRollout: false)
    defer { fixture.remove() }
    let archiveProbe = ThreadArchiveProbe()
    let threads = [
        directoryThread("batch-a", cwd: "/work/a"),
        directoryThread("batch-b", cwd: "/work/b"),
        directoryThread("batch-c", cwd: "/work/c"),
    ]
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        threadArchiveOperation: { threadID, archived in
            await archiveProbe.apply(threadID: threadID, archived: archived)
            if archived && threadID == "batch-b" {
                throw ThreadArchiveProbeError.expectedFailure
            }
        }
    )
    model.activeThreads = threads
    model.selectedThreadIDs = Set(threads.map(\.id))

    await model.setFavorite(threadIDs: model.selectedThreadIDs, isFavorite: true)

    #expect(Set(model.metadata.keys) == Set(threads.map(\.id)))
    #expect(model.metadata.values.allSatisfy { $0.isFavorite })

    await model.archive(threadIDs: model.selectedThreadIDs)

    #expect(model.activeThreads.map(\.id) == ["batch-b"])
    #expect(Set(model.archivedThreads.map(\.id)) == ["batch-a", "batch-c"])
    #expect(model.selectedThreadIDs == ["batch-b"])
    #expect(model.errorMessage?.contains("已归档 2/3 个会话") == true)
    #expect(
        await archiveProbe.requests
            == [
                ThreadArchiveRequest(threadID: "batch-a", archived: true),
                ThreadArchiveRequest(threadID: "batch-b", archived: true),
                ThreadArchiveRequest(threadID: "batch-c", archived: true),
            ])

    model.selectedThreadIDs = Set(model.archivedThreads.map(\.id))
    await model.unarchive(threadIDs: model.selectedThreadIDs)

    #expect(Set(model.activeThreads.map(\.id)) == Set(threads.map(\.id)))
    #expect(model.archivedThreads.isEmpty)
    #expect(model.selectedThreadIDs.isEmpty)
    #expect(model.errorMessage == nil)
}

@MainActor
@Test func staleArchiveTaskCannotMutateNewerListAndSelectionState() async throws {
    let fixture = try SessionModelFixture(
        threadID: "stale-archive-task",
        createRollout: false
    )
    defer { fixture.remove() }
    let probe = DeferredThreadArchiveProbe()
    let staleThread = directoryThread("stale-archive", cwd: "/work/stale")
    let currentThread = directoryThread("current-archive", cwd: "/work/current")
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        threadArchiveOperation: { threadID, archived in
            await probe.apply(threadID: threadID, archived: archived)
        }
    )
    model.activeThreads = [staleThread, currentThread]
    model.selectedThreadIDs = [staleThread.id, currentThread.id]

    let staleTask = Task {
        await model.archive(threadID: staleThread.id)
    }
    await probe.waitUntilCallCount(1)
    let currentTask = Task {
        await model.archive(threadID: currentThread.id)
    }
    await probe.waitUntilCallCount(2)
    await probe.release(request: 1)
    await currentTask.value

    #expect(model.activeThreads.map(\.id) == [staleThread.id])
    #expect(model.archivedThreads.map(\.id) == [currentThread.id])
    #expect(model.selectedThreadIDs == [staleThread.id])

    await probe.release(request: 0)
    await staleTask.value

    #expect(model.activeThreads.map(\.id) == [staleThread.id])
    #expect(model.archivedThreads.map(\.id) == [currentThread.id])
    #expect(model.selectedThreadIDs == [staleThread.id])
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
        #expect(SessionNestQuotaRefreshSchedule.foregroundInterval == 10 * 60)
        #expect(
            SessionNestQuotaRefreshSchedule.tolerance(
                for: SessionNestQuotaRefreshSchedule.foregroundInterval
            ) == 60
        )
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
@Test func sessionBrowsingStatePersistsFiltersAndProjectExpansion() throws {
    let fixture = try SessionModelFixture(
        threadID: "browsing-state",
        createRollout: false
    )
    defer { fixture.remove() }
    let suiteName = "SessionNestBrowsingStateTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let browsingStateStore = SessionBrowsingStateStore(defaults: defaults)
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        browsingStateStore: browsingStateStore
    )

    model.selection = .project("/work/team/app")
    model.query = "crash swift"
    model.timeFilter = .sevenDays
    model.sortOrder = .title
    model.expandedProjectPaths = ["/work/team", "/work/team/app"]

    let restored = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        browsingStateStore: browsingStateStore
    )
    #expect(restored.selection == .project("/work/team/app"))
    #expect(restored.query.isEmpty)
    #expect(restored.timeFilter == .sevenDays)
    #expect(restored.sortOrder == .title)
    #expect(restored.expandedProjectPaths == ["/work/team", "/work/team/app"])
    let sanitizedData = try #require(
        defaults.data(forKey: SessionBrowsingStateStore.storageKey)
    )
    #expect(!String(decoding: sanitizedData, as: UTF8.self).contains("crash swift"))

    let legacyQuery = "旧版本私密搜索词"
    let legacyPayload = try JSONSerialization.data(
        withJSONObject: [
            "selection": "project:/work/legacy",
            "query": legacyQuery,
            "timeFilter": SessionTimeFilter.sevenDays.rawValue,
            "sortOrder": SessionSortOrder.title.rawValue,
            "expandedProjectPaths": ["/work/legacy"],
        ]
    )
    defaults.set(legacyPayload, forKey: SessionBrowsingStateStore.storageKey)
    let migrated = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        browsingStateStore: browsingStateStore
    )
    #expect(migrated.selection == .project("/work/legacy"))
    #expect(migrated.query.isEmpty)
    let migratedData = try #require(
        defaults.data(forKey: SessionBrowsingStateStore.storageKey)
    )
    #expect(!String(decoding: migratedData, as: UTF8.self).contains(legacyQuery))

    defaults.set(Data("damaged".utf8), forKey: SessionBrowsingStateStore.storageKey)
    let fallback = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        browsingStateStore: browsingStateStore
    )
    #expect(fallback.selection == .statistics)
    #expect(fallback.query.isEmpty)
    #expect(fallback.timeFilter == .thirtyDays)
    #expect(fallback.sortOrder == .recent)
    #expect(fallback.expandedProjectPaths.isEmpty)
}

@MainActor
@Test func reloadFallsBackFromStaleDynamicBrowsingSelections() async throws {
    let fixture = try SessionModelFixture(
        threadID: "stale-browsing-selection",
        createRollout: false
    )
    defer { fixture.remove() }
    let suiteName = "SessionNestStaleBrowsingSelectionTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let browsingStateStore = SessionBrowsingStateStore(defaults: defaults)
    let staleSelections: [SidebarSelection] = [
        .savedView("removed-view"),
        .tag("removed-tag"),
        .collection("removed-collection"),
        .project("/work/removed-project"),
    ]

    for staleSelection in staleSelections {
        browsingStateStore.save(
            SessionBrowsingState(
                selection: staleSelection,
                query: "",
                timeFilter: .thirtyDays,
                sortOrder: .recent,
                expandedProjectPaths: []
            )
        )
        let model = SessionListModel(
            client: fixture.client,
            store: fixture.store,
            tokenScanTargetDiscoveryOperation: { _ in [] },
            threadReloadOperation: { ([], []) },
            browsingStateStore: browsingStateStore
        )
        #expect(model.selection == staleSelection)

        await model.reload()

        #expect(model.selection == .recent)
    }
}

@MainActor
@Test func restoredSavedViewKeepsItsExplicitSearchQuery() async throws {
    let fixture = try SessionModelFixture(
        threadID: "restored-saved-view",
        createRollout: false
    )
    defer { fixture.remove() }
    let suiteName = "SessionNestRestoredSavedViewTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let browsingStateStore = SessionBrowsingStateStore(defaults: defaults)
    let savedView = try await fixture.store.createSavedView(
        name: "显式搜索",
        selection: .favorites,
        query: "保留在保存视图中的搜索词",
        timeFilter: .sevenDays,
        sortOrder: .title
    )
    browsingStateStore.save(
        SessionBrowsingState(
            selection: .savedView(savedView.id),
            query: "不会进入普通浏览状态",
            timeFilter: .all,
            sortOrder: .oldest,
            expandedProjectPaths: []
        )
    )
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        tokenScanTargetDiscoveryOperation: { _ in [] },
        threadReloadOperation: { ([], []) },
        browsingStateStore: browsingStateStore
    )
    #expect(model.query.isEmpty)

    await model.reload()

    #expect(model.selection == .savedView(savedView.id))
    #expect(model.query == "保留在保存视图中的搜索词")
    #expect(model.timeFilter == .sevenDays)
    #expect(model.sortOrder == .title)
}

@MainActor
@Test func savedViewRestoresCombinedSessionFilters() async throws {
    let fixture = try SessionModelFixture(threadID: "saved-view", createRollout: false)
    defer { fixture.remove() }
    let now = Int64(Date().timeIntervalSince1970)
    let matching = directoryThread("Alpha crash", cwd: "/work/matching", updatedAt: now)
    let wrongFavorite = directoryThread("Alpha ordinary", cwd: "/work/ordinary", updatedAt: now)
    let wrongQuery = directoryThread("Beta crash", cwd: "/work/beta", updatedAt: now)
    let model = SessionListModel(client: fixture.client, store: fixture.store)
    model.activeThreads = [wrongQuery, wrongFavorite, matching]
    model.metadata = [
        matching.id: ThreadMetadata(
            threadID: matching.id,
            isFavorite: true,
            collectionID: nil
        ),
        wrongQuery.id: ThreadMetadata(
            threadID: wrongQuery.id,
            isFavorite: true,
            collectionID: nil
        ),
    ]
    model.selection = .favorites
    model.query = "Alpha"
    model.timeFilter = .sevenDays
    model.sortOrder = .title

    await model.createSavedView(name: "收藏的 Alpha")
    let savedView = try #require(model.savedViews.first)

    model.selection = .recent
    model.query = ""
    model.timeFilter = .all
    model.sortOrder = .oldest
    model.applySavedView(id: savedView.id)

    #expect(model.selection == .savedView(savedView.id))
    #expect(model.query == "Alpha")
    #expect(model.timeFilter == .sevenDays)
    #expect(model.sortOrder == .title)
    #expect(model.visibleThreads.map(\.id) == [matching.id])

    await model.deleteSavedView(id: savedView.id)
    #expect(model.savedViews.isEmpty)
    #expect(model.selection == .recent)
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

@Test func statisticsSnapshotCacheReusesScopesUntilInputsOrDayChange() {
    var cache = StatisticsSnapshotCache()
    var buildCount = 0
    func snapshot() -> StatisticsSnapshot {
        buildCount += 1
        return StatisticsSnapshot(
            totalUsage: .zero,
            totalSessionCount: buildCount,
            measuredSessionCount: 0,
            averageTokensPerMeasuredSession: 0,
            dailyPoints: [],
            projectRows: [],
            sessionRows: []
        )
    }

    let first = cache.resolve(
        timeFilter: .thirtyDays,
        dayStart: 100,
        timeZoneIdentifier: "UTC",
        build: snapshot
    )
    let repeated = cache.resolve(
        timeFilter: .thirtyDays,
        dayStart: 100,
        timeZoneIdentifier: "UTC",
        build: snapshot
    )
    let otherScope = cache.resolve(
        timeFilter: .sevenDays,
        dayStart: 100,
        timeZoneIdentifier: "UTC",
        build: snapshot
    )

    #expect(first.totalSessionCount == 1)
    #expect(repeated.totalSessionCount == 1)
    #expect(otherScope.totalSessionCount == 2)
    #expect(buildCount == 2)

    cache.invalidate()
    let invalidated = cache.resolve(
        timeFilter: .thirtyDays,
        dayStart: 100,
        timeZoneIdentifier: "UTC",
        build: snapshot
    )
    let changedTimeZone = cache.resolve(
        timeFilter: .thirtyDays,
        dayStart: 100,
        timeZoneIdentifier: "Asia/Shanghai",
        build: snapshot
    )
    let nextDay = cache.resolve(
        timeFilter: .thirtyDays,
        dayStart: 200,
        timeZoneIdentifier: "Asia/Shanghai",
        build: snapshot
    )

    #expect(invalidated.totalSessionCount == 3)
    #expect(changedTimeZone.totalSessionCount == 4)
    #expect(nextDay.totalSessionCount == 5)
    #expect(buildCount == 5)
}

@Test func ninetyDayStatisticsScopeRoundTripsForPersistentSnapshots() throws {
    let duration = try #require(SessionTimeFilter.ninetyDays.duration)

    #expect(duration == 7_776_000)
    #expect(SessionTimeFilter.ninetyDays.statisticsPersistenceScope == "ninety_days")
    #expect(SessionTimeFilter(statisticsPersistenceScope: "ninety_days") == .ninetyDays)
}

@Test func statisticsSnapshotCacheReusesOnlyTheLatestMatchingCustomRange() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let firstRange = try #require(
        StatisticsDateRange(
            from: Date(timeIntervalSince1970: 0),
            through: Date(timeIntervalSince1970: 86_400),
            calendar: calendar
        )
    )
    let secondRange = try #require(
        StatisticsDateRange(
            from: Date(timeIntervalSince1970: 86_400),
            through: Date(timeIntervalSince1970: 172_800),
            calendar: calendar
        )
    )
    var cache = StatisticsSnapshotCache()
    var buildCount = 0
    func snapshot() -> StatisticsSnapshot {
        buildCount += 1
        return StatisticsSnapshot(
            totalUsage: .zero,
            totalSessionCount: buildCount,
            measuredSessionCount: 0,
            averageTokensPerMeasuredSession: 0,
            dailyPoints: [],
            projectRows: [],
            sessionRows: []
        )
    }

    let first = cache.resolve(
        dateRange: firstRange,
        dayStart: 200,
        timeZoneIdentifier: "UTC",
        build: snapshot
    )
    let repeated = cache.resolve(
        dateRange: firstRange,
        dayStart: 200,
        timeZoneIdentifier: "UTC",
        build: snapshot
    )
    let changedRange = cache.resolve(
        dateRange: secondRange,
        dayStart: 200,
        timeZoneIdentifier: "UTC",
        build: snapshot
    )
    let changedTimeZone = cache.resolve(
        dateRange: secondRange,
        dayStart: 200,
        timeZoneIdentifier: "Asia/Shanghai",
        build: snapshot
    )

    #expect(first.totalSessionCount == 1)
    #expect(repeated.totalSessionCount == 1)
    #expect(changedRange.totalSessionCount == 2)
    #expect(changedTimeZone.totalSessionCount == 3)
    #expect(buildCount == 3)
}

@Test func statisticsSnapshotCacheRestoresMatchingPersistentScopes() {
    var cache = StatisticsSnapshotCache()
    let persisted = StatisticsSnapshot(
        totalUsage: .zero,
        totalSessionCount: 42,
        measuredSessionCount: 0,
        averageTokensPerMeasuredSession: 0,
        dailyPoints: [],
        projectRows: [],
        sessionRows: []
    )
    cache.restore(
        [.sevenDays: persisted],
        dayStart: 100,
        timeZoneIdentifier: "UTC"
    )
    var buildCount = 0

    let restored = cache.resolve(
        timeFilter: .sevenDays,
        dayStart: 100,
        timeZoneIdentifier: "UTC"
    ) {
        buildCount += 1
        return persisted
    }
    _ = cache.resolve(
        timeFilter: .sevenDays,
        dayStart: 100,
        timeZoneIdentifier: "Asia/Shanghai"
    ) {
        buildCount += 1
        return persisted
    }

    #expect(restored.totalSessionCount == 42)
    #expect(buildCount == 1)
}

@Test func sidebarSnapshotCacheReusesValueUntilInputsChange() {
    var cache = SidebarSnapshotCache<Int>()
    var buildCount = 0
    func build() -> Int {
        buildCount += 1
        return buildCount
    }

    #expect(cache.resolve(build: build) == 1)
    #expect(cache.resolve(build: build) == 1)
    #expect(buildCount == 1)

    cache.invalidate()
    #expect(cache.resolve(build: build) == 2)
    #expect(buildCount == 2)
}

@Test func managedThreadSnapshotCacheSeparatesScopesUntilInputsChange() {
    var cache = ManagedThreadSnapshotCache()
    var buildCount = 0
    func build() -> [ManagedThread] {
        buildCount += 1
        return []
    }

    _ = cache.resolve(isArchived: false, build: build)
    _ = cache.resolve(isArchived: false, build: build)
    _ = cache.resolve(isArchived: true, build: build)
    _ = cache.resolve(isArchived: true, build: build)

    #expect(buildCount == 2)

    cache.invalidate()
    _ = cache.resolve(isArchived: false, build: build)
    _ = cache.resolve(isArchived: true, build: build)

    #expect(buildCount == 4)
}

@Test func visibleThreadSnapshotCacheReusesFiltersUntilInputsOrTimeWindowExpire() throws {
    let thread = directoryThread("active", cwd: "/work/active", updatedAt: 100)
    let managedThreads = SessionFilter.buildManagedThreads(
        threads: [thread],
        metadata: [:],
        tags: [],
        threadTags: [:],
        threadProjects: [:]
    )
    let key = VisibleThreadSnapshotKey(
        selection: .recent,
        query: "",
        timeFilter: .sevenDays,
        sortOrder: .recent
    )
    let duration = try #require(key.timeFilter.duration)
    var cache = VisibleThreadSnapshotCache()
    var buildCount = 0

    func resolve(at now: Int64, key: VisibleThreadSnapshotKey) -> [ManagedThread] {
        cache.resolve(key: key, now: now) {
            buildCount += 1
            return SessionFilter.apply(
                managedThreads: managedThreads,
                threadTags: [:],
                selection: key.selection,
                query: key.query,
                timeFilter: key.timeFilter,
                sortOrder: key.sortOrder,
                now: now
            )
        }
    }

    #expect(resolve(at: 100, key: key).map(\.id) == [thread.id])
    #expect(resolve(at: 100 + duration, key: key).map(\.id) == [thread.id])
    #expect(buildCount == 1)

    #expect(resolve(at: 101 + duration, key: key).isEmpty)
    #expect(resolve(at: 102 + duration, key: key).isEmpty)
    #expect(buildCount == 2)

    let searchedKey = VisibleThreadSnapshotKey(
        selection: .recent,
        query: "missing",
        timeFilter: .sevenDays,
        sortOrder: .recent
    )
    #expect(resolve(at: 102 + duration, key: searchedKey).isEmpty)
    #expect(buildCount == 3)

    cache.invalidate()
    #expect(resolve(at: 102 + duration, key: searchedKey).isEmpty)
    #expect(buildCount == 4)
}

@MainActor
@Test func managedThreadSnapshotInvalidatesWhenModelInputsChange() throws {
    let fixture = try SessionModelFixture(
        threadID: "managed-thread-cache-invalidation",
        createRollout: false
    )
    defer { fixture.remove() }
    let thread = directoryThread("active", cwd: "/work/active", updatedAt: 4)
    let tag = SessionTag(id: "swift", name: "Swift", colorHex: "#5C78BB", sortOrder: 0)
    let model = SessionListModel(client: fixture.client, store: fixture.store)
    model.timeFilter = .all
    model.activeThreads = [thread]

    #expect(try #require(model.visibleThreads.first).tags.isEmpty)

    model.metadata[thread.id] = ThreadMetadata(
        threadID: thread.id,
        isFavorite: true,
        collectionID: nil
    )
    model.tags = [tag]
    model.threadTags[thread.id] = [tag.id]
    model.threadProjects[thread.id] = ThreadProjectCache(
        threadID: thread.id,
        resolution: .project(path: "/work/project"),
        analyzedUpdatedAt: thread.updatedAt,
        classifierVersion: ThreadProjectClassification.classifierVersion
    )

    let updated = try #require(model.visibleThreads.first)
    #expect(updated.metadata.isFavorite)
    #expect(updated.tags == [tag])
    #expect(updated.projectPath == "/work/project")

    model.selection = .archived
    #expect(model.visibleThreads.isEmpty)
    model.archivedThreads = [directoryThread("archived", cwd: "/work/archived")]
    #expect(model.visibleThreads.map(\.id) == ["archived"])
}

@MainActor
@Test func statisticsSnapshotCacheInvalidatesWhenModelInputsChange() throws {
    let fixture = try SessionModelFixture(
        threadID: "statistics-cache-invalidation",
        createRollout: false
    )
    defer { fixture.remove() }
    let now = Int64(Date().timeIntervalSince1970)
    let model = SessionListModel(client: fixture.client, store: fixture.store)
    model.activeThreads = [
        directoryThread("first", cwd: "/work/first", updatedAt: now)
    ]

    #expect(model.statisticsSnapshot.totalSessionCount == 1)

    model.activeThreads.append(
        directoryThread("second", cwd: "/work/second", updatedAt: now)
    )

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

@Test func searchMatchesAllKeywordsAcrossVisibleFields() {
    let matching = CodexThread(
        id: "matching",
        name: "API Migration",
        preview: "Repair the cache crash",
        cwd: "/work/service",
        createdAt: 1,
        updatedAt: 20,
        recencyAt: nil,
        gitInfo: GitInfo(branch: "feature/cache")
    )
    let partial = CodexThread(
        id: "partial",
        name: "API Migration",
        preview: "Update documentation",
        cwd: "/work/service",
        createdAt: 1,
        updatedAt: 10,
        recencyAt: nil,
        gitInfo: nil
    )

    let result = SessionFilter.apply(
        threads: [matching, partial],
        metadata: [:],
        tags: [],
        threadTags: [:],
        threadProjects: [:],
        selection: .recent,
        query: "  api   CRÁSH ",
        timeFilter: .all,
        sortOrder: .recent,
        now: 100
    )

    #expect(result.map(\.id) == [matching.id])
}

@Test func searchHighlightSegmentsPreserveTextAndMarkEveryKeyword() {
    let segments = SessionSearch.highlightedSegments(
        in: "Fix Cache, then cache",
        query: " cache  FIX "
    )

    #expect(
        segments
            == [
                SessionSearchSegment(text: "Fix", isMatch: true),
                SessionSearchSegment(text: " ", isMatch: false),
                SessionSearchSegment(text: "Cache", isMatch: true),
                SessionSearchSegment(text: ", then ", isMatch: false),
                SessionSearchSegment(text: "cache", isMatch: true),
            ]
    )
    #expect(segments.map(\.text).joined() == "Fix Cache, then cache")
    #expect(
        SessionSearch.highlightedSegments(in: "unchanged", query: "missing")
            == [SessionSearchSegment(text: "unchanged", isMatch: false)]
    )
}

@Test func searchEscapeClearsQueryBeforeReleasingFocus() {
    var query = "cache crash"
    var isFocused = true

    #expect(SessionSearchKeyboard.handleEscape(query: &query, isFocused: &isFocused))
    #expect(query.isEmpty)
    #expect(isFocused)
    #expect(SessionSearchKeyboard.handleEscape(query: &query, isFocused: &isFocused))
    #expect(!isFocused)
    #expect(!SessionSearchKeyboard.handleEscape(query: &query, isFocused: &isFocused))
}

@Test func sessionRowAccessibilitySummarizesVisibleContext() {
    let item = ManagedThread(
        thread: CodexThread(
            id: "accessible",
            name: "修复缓存",
            preview: "避免重复读取",
            cwd: "/work/sessionnest",
            createdAt: 1,
            updatedAt: 2,
            recencyAt: nil,
            gitInfo: GitInfo(branch: "feature/cache")
        ),
        metadata: ThreadMetadata(
            threadID: "accessible",
            isFavorite: true,
            collectionID: nil
        ),
        tags: [
            SessionTag(
                id: "quality",
                name: "质量",
                colorHex: "#5C78BB",
                sortOrder: 0
            ),
            SessionTag(
                id: "urgent",
                name: "紧急",
                colorHex: "#B66B52",
                sortOrder: 1
            ),
        ],
        projectResolution: .project(path: "/work/sessionnest")
    )

    #expect(
        SessionRowAccessibility.label(for: item, relativeActivity: "3分钟前")
            == "修复缓存，项目 sessionnest，分支 feature/cache，标签 质量、紧急，更新于 3分钟前"
    )
}

@Test func resolvesOnlyAttachedTagsInDisplayOrder() throws {
    let thread = directoryThread("tagged", cwd: "/work/tagged")
    let tags = [
        SessionTag(id: "later", name: "Later", colorHex: "#B66B52", sortOrder: 2),
        SessionTag(id: "unused", name: "Unused", colorHex: "#5C78BB", sortOrder: 0),
        SessionTag(id: "beta", name: "Beta", colorHex: "#5C78BB", sortOrder: 1),
        SessionTag(id: "alpha", name: "Alpha", colorHex: "#5C78BB", sortOrder: 1),
    ]

    let result = SessionFilter.apply(
        threads: [thread],
        metadata: [:],
        tags: tags,
        threadTags: [thread.id: Set(["later", "beta", "alpha", "missing"])],
        threadProjects: [:],
        selection: .recent,
        query: "Later",
        timeFilter: .all,
        sortOrder: .recent,
        now: 100
    )

    #expect(try #require(result.first).tags.map(\.id) == ["alpha", "beta", "later"])
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

@Test func onlySessionSelectionsBuildTheSessionList() {
    #expect(!SidebarSelection.quota.showsSessionList)
    #expect(!SidebarSelection.statistics.showsSessionList)

    let listSelections: [SidebarSelection] = [
        .recent,
        .favorites,
        .unclassified,
        .noProject,
        .archived,
        .project("/work/project"),
        .collection("collection"),
        .tag("tag"),
        .savedView("saved-view"),
    ]
    for selection in listSelections {
        #expect(selection.showsSessionList)
    }
}

@Test func sidebarCountsBuildAllActiveCategoriesInOneSnapshot() {
    let favorite = directoryThread("favorite", cwd: "/work/favorite")
    let scratch = directoryThread(
        "scratch",
        cwd: "/Users/me/Documents/Codex/2026-07-23/session"
    )
    let uncategorized = directoryThread("uncategorized", cwd: "/work/uncategorized")
    let counts = SidebarCounts.build(
        threads: [favorite, scratch, uncategorized],
        metadata: [
            favorite.id: ThreadMetadata(
                threadID: favorite.id,
                isFavorite: true,
                collectionID: "work"
            ),
            scratch.id: ThreadMetadata(
                threadID: scratch.id,
                isFavorite: false,
                collectionID: nil
            ),
        ],
        threadTags: [
            favorite.id: ["important", "swift"],
            scratch.id: ["important"],
        ],
        threadProjects: [:]
    )

    #expect(counts.favoriteCount == 1)
    #expect(counts.unclassifiedCount == 2)
    #expect(counts.noProjectCount == 1)
    #expect(counts.collectionCounts == ["work": 1])
    #expect(counts.tagCounts == ["important": 2, "swift": 1])
}

@MainActor
@Test func sidebarSnapshotsInvalidateWhenTheirModelInputsChange() throws {
    let fixture = try SessionModelFixture(
        threadID: "sidebar-cache-invalidation",
        createRollout: false
    )
    defer { fixture.remove() }
    let first = directoryThread("first", cwd: "/work/first")
    let second = directoryThread("second", cwd: "/work/second")
    let model = SessionListModel(client: fixture.client, store: fixture.store)
    model.activeThreads = [first]

    #expect(model.projectTree.map(\.path) == ["/work/first"])
    #expect(model.sidebarCounts.favoriteCount == 0)

    model.metadata[first.id] = ThreadMetadata(
        threadID: first.id,
        isFavorite: true,
        collectionID: nil
    )
    model.threadTags[first.id] = ["important"]

    #expect(model.sidebarCounts.favoriteCount == 1)
    #expect(model.sidebarCounts.tagCounts == ["important": 1])
    #expect(model.projectTree.map(\.path) == ["/work/first"])

    model.activeThreads.append(second)

    #expect(model.projectTree.map(\.path) == ["/work"])
    #expect(model.projectTree[0].children.map(\.path) == ["/work/first", "/work/second"])
    #expect(model.sidebarCounts.unclassifiedCount == 2)
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

@Test func groupsSiblingProjectsIntoSelectableSmartFolder() {
    let threads = [
        directoryThread("editor", cwd: "/work/apps/editor", updatedAt: 3),
        directoryThread("server", cwd: "/work/apps/server", updatedAt: 2),
        directoryThread("solo", cwd: "/other/solo", updatedAt: 1),
        directoryThread("prefix", cwd: "/work/apps2/tool", updatedAt: 4),
    ]

    let tree = ProjectDirectoryTree.build(threads: threads, threadProjects: [:])

    #expect(tree.map(\.path) == ["/work/apps", "/other/solo", "/work/apps2/tool"])
    let smartFolder = tree[0]
    #expect(smartFolder.isSmartFolder)
    #expect(smartFolder.directCount == 0)
    #expect(smartFolder.totalCount == 2)
    #expect(smartFolder.children.map(\.path) == ["/work/apps/editor", "/work/apps/server"])
    #expect(!tree[1].isSmartFolder)
    #expect(!tree[2].isSmartFolder)

    let selected = SessionFilter.apply(
        threads: threads,
        metadata: [:],
        tags: [],
        threadTags: [:],
        threadProjects: [:],
        selection: .project(smartFolder.path),
        query: "",
        timeFilter: .all,
        sortOrder: .recent,
        now: 100
    )

    #expect(selected.map(\.id) == ["editor", "server"])
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
@Test func tokenScanReloadKeepsParsedUsageWhileAppendCatchesUp() async throws {
    let fixture = try SessionModelFixture(threadID: "cached", createRollout: true)
    defer { fixture.remove() }
    let cachedResult = tokenScanResult(total: 120, dayStart: 100)
    try await fixture.store.saveThreadTokenScan(
        threadID: fixture.thread.id,
        rolloutPath: fixture.thread.path!,
        fileSize: 0,
        fileModificationTimeNS: 0,
        parserVersion: TokenParserVersion.value(timeZone: Calendar.current.timeZone),
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
    // 日志仍在增长只代表统计正在追赶，已经成功解析的历史 Token 不能从界面归零。
    #expect(model.statisticsSnapshot.totalUsage.totalTokens == 120)
    // 已解析缓存仍属于有效的最低值，因此会话覆盖数量保持稳定。
    #expect(model.statisticsSnapshot.measuredSessionCount == 1)
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

@Test func appendOnlyStaleTargetKeepsParsedTokenCoverageLowerBound() throws {
    // 构造一个已经成功解析、但扫描完成后又继续增长的活跃日志。
    let fileManager = FileManager.default
    let directoryURL = fileManager.temporaryDirectory
        .appendingPathComponent("SessionCoverageTests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directoryURL) }
    let rolloutURL = directoryURL.appendingPathComponent("active.jsonl")
    try Data(repeating: 1, count: 121).write(to: rolloutURL)
    let attributes = try fileManager.attributesOfItem(atPath: rolloutURL.path)
    let modificationDate = try #require(attributes[.modificationDate] as? Date)
    let modificationTimeNS = Int64(
        (modificationDate.timeIntervalSince1970 * 1_000_000_000).rounded()
    )
    let target = TokenScanTarget(
        id: "active",
        attributionThreadID: "parent",
        url: rolloutURL
    )
    // 持久缓存中的 120 Token 是已经确认的历史最低值，不能因 freshness 变化而丢失。
    let cache = ThreadTokenCache(
        threadID: target.id,
        rolloutPath: target.url.path,
        fileSize: 120,
        fileModificationTimeNS: modificationTimeNS - 1,
        scannedOffset: 120,
        maximum: TokenUsageBreakdown(
            inputTokens: 100,
            cachedInputTokens: 80,
            outputTokens: 20,
            reasoningOutputTokens: 0,
            totalTokens: 120
        ),
        latestEventTimestamp: 100,
        parserVersion: TokenParserVersion.value(timeZone: Calendar.current.timeZone),
        lastReconciledAt: nil
    )
    // stale 只表示统计仍在追赶，不应撤下已经解析成功的目标。
    let health = TokenScanHealth(
        freshTargetIDs: [],
        staleTargetIDs: [target.id],
        failedTargetIDs: []
    )

    // 覆盖集合必须保留该目标，UI 才能展示单调不减的已解析 Token。
    #expect(
        ThreadTokenCoverage.measuredTargetIDs(
            targets: [target],
            cache: [target.id: cache],
            health: health,
            parserVersion: TokenParserVersion.value(timeZone: Calendar.current.timeZone),
            fileManager: fileManager
        ) == [target.id]
    )
}

@MainActor
@Test func tokenScanRebuildsUnchangedDailyUsageAfterTimeZoneChange() async throws {
    let fixture = try SessionModelFixture(threadID: "time-zone-change", createRollout: true)
    defer { fixture.remove() }
    let rolloutURL = URL(fileURLWithPath: fixture.thread.path!)
    let line = tokenCheckpointLine(timestamp: "2026-07-23T00:30:00Z", total: 120) + "\n"
    try Data(line.utf8).write(to: rolloutURL)
    let attributes = try FileManager.default.attributesOfItem(atPath: rolloutURL.path)
    let fileSize = try #require((attributes[.size] as? NSNumber)?.int64Value)
    let modificationDate = try #require(attributes[.modificationDate] as? Date)
    let modificationTimeNS = Int64(
        (modificationDate.timeIntervalSince1970 * 1_000_000_000).rounded()
    )
    var utcCalendar = Calendar(identifier: .gregorian)
    utcCalendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    var shanghaiCalendar = Calendar(identifier: .gregorian)
    shanghaiCalendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let eventDate = try Date("2026-07-23T00:30:00Z", strategy: .iso8601)
    let utcDayStart = Int64(utcCalendar.startOfDay(for: eventDate).timeIntervalSince1970)
    let shanghaiDayStart = Int64(
        shanghaiCalendar.startOfDay(for: eventDate).timeIntervalSince1970
    )
    let utcResult = try RolloutTokenScanner.scan(url: rolloutURL, calendar: utcCalendar)
    try await fixture.store.saveThreadTokenScan(
        threadID: fixture.thread.id,
        rolloutPath: rolloutURL.path,
        fileSize: fileSize,
        fileModificationTimeNS: modificationTimeNS,
        parserVersion: TokenParserVersion.value(timeZone: utcCalendar.timeZone),
        result: utcResult,
        rebuild: true,
        reconciledAt: Int64(Date().timeIntervalSince1970)
    )
    let target = TokenScanTarget(
        id: fixture.thread.id,
        attributionThreadID: fixture.thread.id,
        url: rolloutURL
    )
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        tokenScanTargetDiscoveryOperation: { _ in [target] }
    )

    await model.startTokenUsageScan(for: [fixture.thread], calendar: shanghaiCalendar)
    try await waitForTokenCondition { !model.isScanningTokenUsage }

    #expect(utcDayStart != shanghaiDayStart)
    #expect(model.threadTokenDailyUsage.map(\.dayStart) == [shanghaiDayStart])
    #expect(
        model.threadTokenCache[fixture.thread.id]?.parserVersion
            == TokenParserVersion.value(timeZone: shanghaiCalendar.timeZone)
    )
    #expect(model.tokenScanDiagnostics?.tokenReadFileCount == 1)
    #expect(model.tokenScanDiagnostics?.tokenCacheReuseCount == 0)
}

@MainActor
@Test func tokenScanWarnsWhenStableScopeMateriallyDoublesThenDropsToZero() async throws {
    let fixture = try SessionModelFixture(threadID: "anomaly", createRollout: true)
    defer { fixture.remove() }
    let rolloutURL = URL(fileURLWithPath: fixture.thread.path!)
    let firstCheckpoint =
        tokenCheckpointLine(timestamp: "2026-07-13T16:01:00Z", total: 100_000) + "\n"
    try Data(firstCheckpoint.utf8).write(to: rolloutURL)
    let target = TokenScanTarget(
        id: fixture.thread.id,
        attributionThreadID: fixture.thread.id,
        url: rolloutURL
    )
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        tokenScanTargetDiscoveryOperation: { _ in [target] }
    )

    // 首轮只建立进程内基线，不把初始全量读取误报为异常。
    await model.startTokenUsageScan(for: [fixture.thread])
    try await waitForTokenCondition { !model.isScanningTokenUsage }
    #expect(model.tokenUsageAnomaly == nil)

    let doubledCheckpoint =
        tokenCheckpointLine(timestamp: "2026-07-13T16:02:00Z", total: 200_000) + "\n"
    let handle = try FileHandle(forWritingTo: rolloutURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(doubledCheckpoint.utf8))
    try handle.close()
    await model.startTokenUsageScan(for: [fixture.thread])
    try await waitForTokenCondition { !model.isScanningTokenUsage }
    #expect(
        model.tokenUsageAnomaly == .doubled(previous: 100_000, current: 200_000)
    )

    // 同一目标截断为空后，全量统计归零并给出上轮数值，底层统计仍保持真实结果。
    try Data().write(to: rolloutURL)
    await model.startTokenUsageScan(for: [fixture.thread])
    try await waitForTokenCondition { !model.isScanningTokenUsage }
    #expect(model.tokenUsageAnomaly == .droppedToZero(previous: 200_000))
    #expect(model.threadTokenDailyUsage.isEmpty)
}

@MainActor
@Test func tokenScanRebuildsTruncatedRolloutAndRemovesOldDailyUsage() async throws {
    let fixture = try SessionModelFixture(threadID: "truncated", createRollout: true)
    defer { fixture.remove() }
    let rolloutURL = URL(fileURLWithPath: fixture.thread.path!)
    let original =
        [
            tokenCheckpointLine(timestamp: "2026-07-13T16:01:00Z", total: 40),
            tokenCheckpointLine(timestamp: "2026-07-14T16:01:00Z", total: 100),
        ].joined(separator: "\n") + "\n"
    try Data(original.utf8).write(to: rolloutURL)
    let target = TokenScanTarget(
        id: fixture.thread.id,
        attributionThreadID: fixture.thread.id,
        url: rolloutURL
    )
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        tokenScanTargetDiscoveryOperation: { _ in [target] }
    )
    model.activeThreads = [fixture.thread]
    model.timeFilter = .all

    await model.startTokenUsageScan(for: [fixture.thread])
    try await waitForTokenCondition { !model.isScanningTokenUsage }
    #expect(model.statisticsSnapshot.totalUsage.totalTokens == 100)
    #expect(model.threadTokenDailyUsage.count == 2)

    let truncated =
        tokenCheckpointLine(timestamp: "2026-07-15T16:01:00Z", total: 30) + "\n"
    try Data(truncated.utf8).write(to: rolloutURL)
    #expect(truncated.utf8.count < original.utf8.count)

    await model.startTokenUsageScan(for: [fixture.thread])
    try await waitForTokenCondition { !model.isScanningTokenUsage }

    #expect(model.threadTokenCache[fixture.thread.id]?.maximum.totalTokens == 30)
    #expect(model.threadTokenDailyUsage.map(\.usage.totalTokens) == [30])
    #expect(model.statisticsSnapshot.totalUsage.totalTokens == 30)
    #expect(model.statisticsSnapshot.measuredSessionCount == 1)
    #expect(model.tokenScanHealth.freshTargetIDs == [fixture.thread.id])
}

@MainActor
@Test func tokenScanRebuildsSameSizeRolloutReplacement() async throws {
    let fixture = try SessionModelFixture(threadID: "replaced", createRollout: true)
    defer { fixture.remove() }
    let rolloutURL = URL(fileURLWithPath: fixture.thread.path!)
    let original =
        tokenCheckpointLine(timestamp: "2026-07-13T16:01:00Z", total: 40) + "\n"
    try Data(original.utf8).write(to: rolloutURL)
    let target = TokenScanTarget(
        id: fixture.thread.id,
        attributionThreadID: fixture.thread.id,
        url: rolloutURL
    )
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        tokenScanTargetDiscoveryOperation: { _ in [target] }
    )
    model.activeThreads = [fixture.thread]
    model.timeFilter = .all

    await model.startTokenUsageScan(for: [fixture.thread])
    try await waitForTokenCondition { !model.isScanningTokenUsage }
    let cachedModificationTime = try #require(
        model.threadTokenCache[fixture.thread.id]?.fileModificationTimeNS
    )
    #expect(model.statisticsSnapshot.totalUsage.totalTokens == 40)

    let replacement =
        tokenCheckpointLine(timestamp: "2026-07-15T16:01:00Z", total: 70) + "\n"
    #expect(replacement.utf8.count == original.utf8.count)
    try Data(replacement.utf8).write(to: rolloutURL)
    try FileManager.default.setAttributes(
        [
            .modificationDate: Date(
                timeIntervalSince1970: Double(cachedModificationTime) / 1_000_000_000 + 1
            )
        ],
        ofItemAtPath: rolloutURL.path
    )

    await model.startTokenUsageScan(for: [fixture.thread])
    try await waitForTokenCondition { !model.isScanningTokenUsage }

    #expect(model.threadTokenCache[fixture.thread.id]?.maximum.totalTokens == 70)
    #expect(model.threadTokenDailyUsage.map(\.usage.totalTokens) == [70])
    #expect(model.statisticsSnapshot.totalUsage.totalTokens == 70)
    #expect(model.statisticsSnapshot.measuredSessionCount == 1)
    #expect(model.tokenScanHealth.freshTargetIDs == [fixture.thread.id])
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
        parserVersion: TokenParserVersion.value(timeZone: Calendar.current.timeZone),
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
                ),
                duplicateTokenCheckpointCount: 2
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
    #expect(diagnostics.duplicateTokenCheckpointCount == 2)
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
        parserVersion: TokenParserVersion.value(timeZone: Calendar.current.timeZone),
        result: cachedResult,
        rebuild: true,
        reconciledAt: Int64(Date().timeIntervalSince1970)
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
@Test func rapidTokenScanRequestsCoalesceToTheLatestRequest() async throws {
    let fixture = try SessionModelFixture(threadID: "scan-coalescing", createRollout: true)
    defer { fixture.remove() }
    let target = TokenScanTarget(
        id: fixture.thread.id,
        attributionThreadID: fixture.thread.id,
        url: URL(fileURLWithPath: fixture.thread.path!)
    )
    let probe = TokenScanRequestProbe(target: target)
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        tokenScanOperation: { _, _, _, _ in await probe.scan() },
        tokenScanTargetDiscoveryOperation: { await probe.discover($0) }
    )

    let first = Task {
        await model.startTokenUsageScan(for: [])
    }
    try await waitForTokenCondition { model.isScanningTokenUsage }
    let latest = Task {
        await model.startTokenUsageScan(for: [fixture.thread])
    }
    await first.value
    await latest.value
    try await waitForTokenCondition { !model.isScanningTokenUsage }

    #expect(await probe.requestedThreadIDs == [[fixture.thread.id]])
    #expect(await probe.scanCount == 1)
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
@Test func tokenScanReconcilesUnchangedRawLogWithCorruptedDatabaseOncePerDay() async throws {
    let fixture = try SessionModelFixture(threadID: "reconcile", createRollout: true)
    defer { fixture.remove() }
    let rolloutURL = URL(fileURLWithPath: fixture.thread.path!)
    let rawLine =
        #"{"timestamp":"2026-07-23T07:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20,"reasoning_output_tokens":10,"total_tokens":120}}}}"#
        + "\n"
    try Data(rawLine.utf8).write(to: rolloutURL)
    let attributes = try FileManager.default.attributesOfItem(atPath: rolloutURL.path)
    let fileSize = try #require((attributes[.size] as? NSNumber)?.int64Value)
    let modificationDate = try #require(attributes[.modificationDate] as? Date)
    let modificationTimeNS = Int64(
        (modificationDate.timeIntervalSince1970 * 1_000_000_000).rounded()
    )
    let secondaryURL = fixture.directoryURL.appendingPathComponent("secondary.jsonl")
    try Data(rawLine.utf8).write(to: secondaryURL)
    let secondaryAttributes = try FileManager.default.attributesOfItem(atPath: secondaryURL.path)
    let secondaryFileSize = try #require(
        (secondaryAttributes[.size] as? NSNumber)?.int64Value
    )
    let secondaryModificationDate = try #require(
        secondaryAttributes[.modificationDate] as? Date
    )
    let secondaryModificationTimeNS = Int64(
        (secondaryModificationDate.timeIntervalSince1970 * 1_000_000_000).rounded()
    )

    // 模拟文件元数据完全匹配、但 SQLite 汇总被静默改错的旧缓存。
    let corrupted = tokenScanResult(total: 999, dayStart: 100)
    try await fixture.store.saveThreadTokenScan(
        threadID: fixture.thread.id,
        rolloutPath: rolloutURL.path,
        fileSize: fileSize,
        fileModificationTimeNS: modificationTimeNS,
        parserVersion: TokenParserVersion.value(timeZone: Calendar.current.timeZone),
        result: TokenScanResult(offset: fileSize, state: corrupted.state),
        rebuild: true
    )
    // 第二个到期缓存保持正确，用来证明单轮不会集中重读全部日志。
    let accurate = tokenScanResult(total: 120, dayStart: 100)
    try await fixture.store.saveThreadTokenScan(
        threadID: "secondary",
        rolloutPath: secondaryURL.path,
        fileSize: secondaryFileSize,
        fileModificationTimeNS: secondaryModificationTimeNS,
        parserVersion: TokenParserVersion.value(timeZone: Calendar.current.timeZone),
        result: TokenScanResult(offset: secondaryFileSize, state: accurate.state),
        rebuild: true
    )
    let target = TokenScanTarget(
        id: fixture.thread.id,
        attributionThreadID: fixture.thread.id,
        url: rolloutURL
    )
    let secondaryTarget = TokenScanTarget(
        id: "secondary",
        attributionThreadID: fixture.thread.id,
        url: secondaryURL
    )
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        tokenScanTargetDiscoveryOperation: { _ in [target, secondaryTarget] },
        threadReloadOperation: { ([fixture.thread], []) }
    )

    // 首轮只重建第一个目标，并用原始日志替换其错误缓存和日汇总。
    await model.reload()
    try await waitForTokenCondition { !model.isScanningTokenUsage }
    let reconciledDiagnostics = try #require(model.tokenScanDiagnostics)
    let reconciledCache = try #require(model.threadTokenCache[fixture.thread.id])
    #expect(reconciledCache.maximum.totalTokens == 120)
    #expect(reconciledCache.lastReconciledAt != nil)
    #expect(model.threadTokenCache["secondary"]?.lastReconciledAt == nil)
    #expect(model.threadTokenDailyUsage.map(\.usage.totalTokens).sorted() == [120, 120])
    #expect(reconciledDiagnostics.tokenReconciliationCount == 1)
    #expect(reconciledDiagnostics.tokenReadFileCount == 1)
    #expect(reconciledDiagnostics.tokenCacheReuseCount == 1)

    // 下一轮复用第一个目标，并让第二个到期缓存继续完成对账。
    await model.startTokenUsageScan(for: [fixture.thread])
    try await waitForTokenCondition { !model.isScanningTokenUsage }
    let continuedDiagnostics = try #require(model.tokenScanDiagnostics)
    #expect(continuedDiagnostics.tokenReconciliationCount == 1)
    #expect(continuedDiagnostics.tokenReadFileCount == 1)
    #expect(continuedDiagnostics.tokenCacheReuseCount == 1)
    #expect(model.threadTokenCache["secondary"]?.lastReconciledAt != nil)

    // 两个目标都刚对账后，24 小时内再次扫描不应打开任何正文。
    await model.startTokenUsageScan(for: [fixture.thread])
    try await waitForTokenCondition { !model.isScanningTokenUsage }
    let reusedDiagnostics = try #require(model.tokenScanDiagnostics)
    #expect(reusedDiagnostics.tokenReconciliationCount == 0)
    #expect(reusedDiagnostics.tokenReadFileCount == 0)
    #expect(reusedDiagnostics.tokenCacheReuseCount == 2)
    #expect(model.threadTokenCache[fixture.thread.id]?.maximum.totalTokens == 120)
}

@MainActor
@Test func manualTokenRecalculationRereadsUnchangedLogAndPreservesOtherDays() async throws {
    let fixture = try SessionModelFixture(threadID: "manual-recalculation", createRollout: true)
    defer { fixture.remove() }
    let rolloutURL = URL(fileURLWithPath: fixture.thread.path!)
    try Data(repeating: 1, count: 10).write(to: rolloutURL)
    let firstDay: Int64 = 1_767_225_600
    let secondDay = firstDay + 24 * 60 * 60
    let thirdDay = secondDay + 24 * 60 * 60
    let probe = TokenRecalculationProbe(
        fileSize: 10,
        days: [firstDay, secondDay, thirdDay]
    )
    let target = TokenScanTarget(
        id: fixture.thread.id,
        attributionThreadID: fixture.thread.id,
        url: rolloutURL
    )
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        tokenScanOperation: { _, _, _, _ in await probe.scan() },
        tokenScanTargetDiscoveryOperation: { _ in [target] }
    )
    model.activeThreads = [fixture.thread]
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))

    await model.startTokenUsageScan(for: [fixture.thread], calendar: calendar)
    try await waitForTokenCondition { !model.isScanningTokenUsage }
    #expect(model.threadTokenDailyUsage.map(\.usage.totalTokens) == [10, 20, 30])

    let selectedDate = Date(timeIntervalSince1970: TimeInterval(secondDay))
    await model.recalculateTokenUsage(
        from: selectedDate,
        through: selectedDate,
        calendar: calendar
    )
    try await waitForTokenCondition { !model.isScanningTokenUsage }

    #expect(await probe.callCount == 2)
    #expect(model.threadTokenDailyUsage.map(\.usage.totalTokens) == [10, 200, 30])
    #expect(model.tokenScanDiagnostics?.tokenReadFileCount == 1)
    #expect(model.tokenScanDiagnostics?.tokenCacheReuseCount == 0)

    // 手动重算期间若源日志增长，必须完整同步新内容，不能让更新后的缓存跳过范围外事件。
    try Data(repeating: 1, count: 11).write(to: rolloutURL)
    await model.recalculateTokenUsage(
        from: selectedDate,
        through: selectedDate,
        calendar: calendar
    )
    try await waitForTokenCondition { !model.isScanningTokenUsage }
    #expect(await probe.callCount == 3)
    #expect(model.threadTokenDailyUsage.map(\.usage.totalTokens) == [11, 201, 31])
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

private struct ThreadArchiveRequest: Equatable {
    let threadID: String
    let archived: Bool
}

private actor ThreadArchiveProbe {
    private(set) var requests: [ThreadArchiveRequest] = []

    func apply(threadID: String, archived: Bool) {
        requests.append(ThreadArchiveRequest(threadID: threadID, archived: archived))
    }
}

private actor DeferredThreadArchiveProbe {
    private(set) var callCount = 0
    private var releasedRequests: Set<Int> = []

    func apply(threadID: String, archived: Bool) async {
        let request = callCount
        callCount += 1
        while !releasedRequests.contains(request) {
            await Task.yield()
        }
    }

    func waitUntilCallCount(_ expectedCount: Int) async {
        while callCount < expectedCount {
            await Task.yield()
        }
    }

    func release(request: Int) {
        releasedRequests.insert(request)
    }
}

private actor ReloadCountProbe {
    private(set) var callCount = 0

    func load() -> ([CodexThread], [CodexThread]) {
        callCount += 1
        return ([], [])
    }
}

private actor TokenScanRequestProbe {
    private let target: TokenScanTarget
    private(set) var requestedThreadIDs: [[String]] = []
    private(set) var scanCount = 0

    init(target: TokenScanTarget) {
        self.target = target
    }

    func discover(_ threads: [CodexThread]) -> [TokenScanTarget] {
        requestedThreadIDs.append(threads.map(\.id))
        return threads.isEmpty ? [] : [target]
    }

    func scan() -> TokenScanResult {
        scanCount += 1
        return tokenScanResult(total: 50, dayStart: 100)
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

private actor TokenRecalculationProbe {
    private let fileSize: Int64
    private let days: [Int64]
    private(set) var callCount = 0

    init(fileSize: Int64, days: [Int64]) {
        self.fileSize = fileSize
        self.days = days
    }

    func scan() -> TokenScanResult {
        callCount += 1
        let totals: [Int64]
        switch callCount {
        case 1:
            totals = [10, 20, 30]
        case 2:
            totals = [10, 200, 30]
        default:
            totals = [11, 201, 31]
        }
        let dailyUsage = Dictionary(
            uniqueKeysWithValues: zip(days, totals).map { day, total in
                (
                    day,
                    TokenUsageBreakdown(
                        inputTokens: total,
                        cachedInputTokens: 0,
                        outputTokens: 0,
                        reasoningOutputTokens: 0,
                        totalTokens: total
                    )
                )
            }
        )
        return TokenScanResult(
            offset: fileSize + Int64(max(0, callCount - 2)),
            state: TokenScanState(
                maximum: dailyUsage.values.reduce(.zero, +),
                dailyUsage: dailyUsage,
                latestEventTimestamp: days.last,
                observedCheckpoint: true
            )
        )
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

private enum ThreadArchiveProbeError: Error {
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

private func tokenCheckpointLine(timestamp: String, total: Int64) -> String {
    """
    {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(total - 10),"cached_input_tokens":\(max(0, total - 20)),"output_tokens":10,"reasoning_output_tokens":2,"total_tokens":\(total)}}}}
    """
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
