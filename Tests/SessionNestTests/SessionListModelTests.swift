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
            classifierVersion: 1
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
                classifierVersion: 1
            )
        ))
    #expect(
        ThreadProjectClassification.needsAnalysis(
            thread: thread,
            cached: ThreadProjectCache(
                threadID: thread.id,
                resolution: .workingDirectory(path: "/work/codex"),
                analyzedUpdatedAt: thread.updatedAt,
                classifierVersion: 1
            )
        ) == false)
    #expect(
        ThreadProjectClassification.needsAnalysis(
            thread: thread,
            cached: ThreadProjectCache(
                threadID: thread.id,
                resolution: .project(path: "/work/codex"),
                analyzedUpdatedAt: thread.updatedAt,
                classifierVersion: 0
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
        classifierVersion: 1
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
            classifierVersion: 1
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
            classifierVersion: 1
        ),
        scratchWithProject.id: ThreadProjectCache(
            threadID: scratchWithProject.id,
            resolution: .project(path: repository),
            analyzedUpdatedAt: 4,
            classifierVersion: 1
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
            classifierVersion: 1
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

@MainActor
@Test func tokenScanReloadPublishesCachedUsage() async throws {
    let fixture = try SessionModelFixture(threadID: "cached", createRollout: true)
    defer { fixture.remove() }
    let cachedResult = tokenScanResult(total: 120, dayStart: 100)
    try await fixture.store.saveThreadTokenScan(
        threadID: fixture.thread.id,
        rolloutPath: fixture.thread.path!,
        fileSize: 0,
        fileModificationTimeNS: 0,
        parserVersion: 1,
        result: cachedResult,
        rebuild: true
    )
    try Data("new content".utf8).write(to: URL(fileURLWithPath: fixture.thread.path!))
    let probe = DeferredTokenScanProbe()
    let model = SessionListModel(
        client: fixture.client,
        store: fixture.store,
        tokenScanOperation: { _, _, _, _ in try await probe.scan(result: cachedResult) },
        threadReloadOperation: { ([fixture.thread], []) }
    )
    model.timeFilter = .all

    await model.reload()
    try await waitForTokenCondition { await probe.started }

    #expect(model.isScanningTokenUsage)
    #expect(model.threadTokenCache[fixture.thread.id]?.maximum.totalTokens == 120)
    #expect(model.threadTokenDailyUsage.map(\.usage.totalTokens) == [120])
    #expect(model.statisticsSnapshot.totalUsage.totalTokens == 120)
    #expect(model.errorMessage == nil)
    await probe.release()
    try await waitForTokenCondition { !model.isScanningTokenUsage }
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
    private var shouldFail = false

    init(snapshot: CodexRateLimitSnapshot) {
        self.snapshot = snapshot
    }

    func load() throws -> CodexRateLimitSnapshot {
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

private func weeklyRateLimitSnapshot(usedPercent: Double) throws -> CodexRateLimitSnapshot {
    try JSONDecoder().decode(
        CodexRateLimitSnapshot.self,
        from: Data(
            """
            {"primary":{"usedPercent":\(usedPercent),"windowDurationMins":10080}}
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
