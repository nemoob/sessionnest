import AppKit
import Combine
import Foundation

typealias TokenScanOperation =
    @Sendable (
        URL,
        Int64,
        TokenScanState,
        Calendar
    ) async throws -> TokenScanResult
typealias ThreadReloadOperation = @Sendable () async throws -> ([CodexThread], [CodexThread])
typealias RateLimitRefreshOperation = @Sendable () async throws -> CodexRateLimitSnapshot
typealias UsageRefreshOperation = @Sendable () async throws -> CodexUsageSnapshot
typealias TokenScanTargetDiscoveryOperation = @Sendable ([CodexThread]) async -> [TokenScanTarget]
private typealias IndexedTokenScanTargetDiscoveryOperation =
    @Sendable ([CodexThread]) async -> TokenDiscoveryResult

struct TokenScanDiagnostics: Equatable, Sendable {
    // 最近完成时间只在整轮扫描成功发布时更新，取消任务不会覆盖旧诊断。
    let completedAt: Date
    // 耗时覆盖目录发现、Token 扫描、存储和最终读取的完整链路。
    let duration: TimeInterval
    // 目录枚举数量是发现索引本轮检查的 JSONL 总基数。
    let discoveryEnumeratedFileCount: Int
    // 发现缓存命中数量反映无需读取日志头的文件数。
    let discoveryCacheHitCount: Int
    // 发现实际读取数量只统计打开并检查日志头的文件。
    let discoveryReadFileCount: Int
    // 发现读取字节按真实进入内存的前缀字节累计。
    let discoveryReadBytes: Int64
    // 发现读取失败数量用于识别权限或瞬时文件系统问题。
    let discoveryFailedReadCount: Int
    // 索引存储失败会导致后续刷新退化为冷发现，需要在诊断中明确提示。
    let discoveryCacheStoreFailed: Bool
    // 扫描目标包含可见会话日志及其可归属的子代理日志。
    let targetCount: Int
    // Token 缓存复用数量表示正文完全没有重新读取的目标。
    let tokenCacheReuseCount: Int
    // Token 实际读取数量包含增量和全量正文扫描。
    let tokenReadFileCount: Int
    // Token 读取字节使用扫描结果偏移与起始偏移之差计算。
    let tokenReadBytes: Int64
    // 失败目标数量与覆盖健康状态保持一致。
    let failedTargetCount: Int
    // 清理行数用于确认 30 天细粒度保留策略实际执行。
    let prunedTimedRowCount: Int
}

enum SidebarSelection: Hashable {
    case quota
    case recent
    case statistics
    case favorites
    case unclassified
    case noProject
    case archived
    case project(String)
    case collection(String)
    case tag(String)
}

enum SessionTimeFilter: String, CaseIterable {
    case all = "全部时间"
    case sevenDays = "最近 7 天"
    case thirtyDays = "最近 30 天"
}

enum SessionSortOrder: String, CaseIterable {
    case recent = "最近更新"
    case oldest = "最早更新"
    case title = "标题"
}

struct ManagedThread: Identifiable, Equatable {
    let thread: CodexThread
    let metadata: ThreadMetadata
    let tags: [SessionTag]
    let projectResolution: ThreadProjectResolution

    var id: String { thread.id }
    var projectPath: String? { projectResolution.projectPath }
    var projectName: String {
        projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "无项目"
    }
}

struct ProjectDirectoryNode: Identifiable, Equatable {
    let path: String
    let name: String
    let directCount: Int
    let totalCount: Int
    let children: [ProjectDirectoryNode]

    var id: String { path }
    var outlineChildren: [ProjectDirectoryNode]? { children.isEmpty ? nil : children }
}

enum ProjectDirectoryTree {
    static func build(
        threads: [CodexThread],
        threadProjects: [String: ThreadProjectCache],
        projectIdentityIndex: ThreadProjectIdentityIndex = .empty
    ) -> [ProjectDirectoryNode] {
        let resolvedThreads = threads.map { thread in
            (
                thread,
                ThreadProjectClassification.effectiveResolution(
                    for: thread,
                    cached: threadProjects[thread.id],
                    projectIdentityIndex: projectIdentityIndex
                )
            )
        }
        var directCounts: [String: Int] = [:]
        var includedPaths: Set<String> = []
        for (thread, resolution) in resolvedThreads {
            guard let projectPath = resolution.projectPath else { continue }
            let normalizedProjectPath = normalizedPath(projectPath)
            directCounts[normalizedProjectPath, default: 0] += 1
            includedPaths.insert(normalizedProjectPath)
            let normalizedWorkingDirectory = normalizedPath(thread.cwd)
            if CodexScratchWorkspaceDetector.sessionRoot(for: thread.cwd) == nil,
                contains(path: normalizedProjectPath, in: normalizedWorkingDirectory)
            {
                includedPaths.insert(normalizedWorkingDirectory)
            }
        }
        let paths = Array(includedPaths)
        let parentByPath = Dictionary(
            uniqueKeysWithValues: paths.map { path in
                let parent =
                    paths
                    .filter { $0 != path && contains(path: path, in: $0) }
                    .max { $0.count < $1.count }
                return (path, parent)
            })

        func sortedChildren(of parent: String?) -> [String] {
            paths
                .filter { parentByPath[$0] == parent }
                .sorted { lhs, rhs in
                    let lhsName = URL(fileURLWithPath: lhs).lastPathComponent
                    let rhsName = URL(fileURLWithPath: rhs).lastPathComponent
                    let comparison = lhsName.localizedCaseInsensitiveCompare(rhsName)
                    return comparison == .orderedSame ? lhs < rhs : comparison == .orderedAscending
                }
        }

        func makeNode(path: String) -> ProjectDirectoryNode {
            let children = sortedChildren(of: path).map(makeNode)
            let directCount = directCounts[path] ?? 0
            return ProjectDirectoryNode(
                path: path,
                name: URL(fileURLWithPath: path).lastPathComponent,
                directCount: directCount,
                totalCount: directCount + children.reduce(0) { $0 + $1.totalCount },
                children: children
            )
        }

        return sortedChildren(of: nil).map(makeNode)
    }

    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static func contains(path: String, in subtree: String) -> Bool {
        let path = normalizedPath(path)
        let subtree = normalizedPath(subtree)
        return path == subtree || path.hasPrefix(subtree == "/" ? "/" : subtree + "/")
    }
}

enum ThreadProjectClassification {
    static let classifierVersion: Int64 = 2

    static func effectiveResolution(
        for thread: CodexThread,
        cached: ThreadProjectCache?,
        projectIdentityIndex: ThreadProjectIdentityIndex = .empty
    ) -> ThreadProjectResolution {
        if let cached,
            cached.analyzedUpdatedAt >= thread.updatedAt,
            cached.classifierVersion == classifierVersion
        {
            return normalized(cached.resolution)
        }
        if CodexScratchWorkspaceDetector.sessionRoot(for: thread.cwd) != nil {
            return .noProject
        }
        if let canonicalProjectPath = projectIdentityIndex.canonicalProjectPath(for: thread) {
            return .project(path: ProjectDirectoryTree.normalizedPath(canonicalProjectPath))
        }
        return .workingDirectory(path: ProjectDirectoryTree.normalizedPath(thread.cwd))
    }

    static func effectivePath(
        for thread: CodexThread,
        cached: ThreadProjectCache?
    ) -> String {
        effectiveResolution(for: thread, cached: cached).projectPath
            ?? ProjectDirectoryTree.normalizedPath(thread.cwd)
    }

    static func needsAnalysis(
        thread: CodexThread,
        cached: ThreadProjectCache?
    ) -> Bool {
        cached == nil || cached!.analyzedUpdatedAt < thread.updatedAt
            || cached!.classifierVersion != classifierVersion
    }

    private static func normalized(
        _ resolution: ThreadProjectResolution
    ) -> ThreadProjectResolution {
        switch resolution {
        case .project(let path):
            .project(path: ProjectDirectoryTree.normalizedPath(path))
        case .workingDirectory(let path):
            .workingDirectory(path: ProjectDirectoryTree.normalizedPath(path))
        case .noProject:
            .noProject
        }
    }
}

enum ProjectClassificationTaskReplacement {
    static func cancelAndWait(for task: Task<Void, Never>?) async {
        task?.cancel()
        await task?.value
    }
}

enum ThreadTokenCoverage {
    static func validThreadIDs(
        threads: [CodexThread],
        cache: [String: ThreadTokenCache],
        parserVersion: Int64,
        fileManager: FileManager = .default
    ) -> Set<String> {
        validTargetIDs(
            targets: threads.compactMap { thread in
                guard let path = thread.path else { return nil }
                return TokenScanTarget(
                    id: thread.id,
                    attributionThreadID: thread.id,
                    url: URL(fileURLWithPath: path)
                )
            },
            cache: cache,
            parserVersion: parserVersion,
            fileManager: fileManager
        )
    }

    static func validTargetIDs(
        targets: [TokenScanTarget],
        cache: [String: ThreadTokenCache],
        parserVersion: Int64,
        fileManager: FileManager = .default
    ) -> Set<String> {
        let health = health(
            targets: targets,
            cache: cache,
            parserVersion: parserVersion,
            fileManager: fileManager
        )
        return measuredTargetIDs(targets: targets, cache: cache, health: health)
    }

    static func measuredTargetIDs(
        targets: [TokenScanTarget],
        cache: [String: ThreadTokenCache],
        health: TokenScanHealth
    ) -> Set<String> {
        let targetsByThreadID = Dictionary(grouping: targets, by: \.attributionThreadID)
        return Set(
            targetsByThreadID.values.flatMap { attributedTargets -> [String] in
                guard
                    attributedTargets.allSatisfy({
                        health.freshTargetIDs.contains($0.id)
                    })
                else { return [] }

                return attributedTargets.compactMap { target in
                    guard let cached = cache[target.id],
                        cached.latestEventTimestamp != nil || !cached.maximum.isZero
                    else { return nil }
                    return target.id
                }
            }
        )
    }

    static func health(
        targets: [TokenScanTarget],
        cache: [String: ThreadTokenCache],
        parserVersion: Int64,
        fileManager: FileManager = .default
    ) -> TokenScanHealth {
        var freshTargetIDs: Set<String> = []
        var staleTargetIDs: Set<String> = []
        var failedTargetIDs: Set<String> = []

        for target in targets {
            let url = target.url
            guard url.pathExtension.lowercased() == "jsonl",
                fileManager.isReadableFile(atPath: url.path),
                let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                attributes[.type] as? FileAttributeType == .typeRegular,
                let size = (attributes[.size] as? NSNumber)?.int64Value,
                let modificationDate = attributes[.modificationDate] as? Date
            else {
                failedTargetIDs.insert(target.id)
                continue
            }
            guard let cached = cache[target.id] else {
                staleTargetIDs.insert(target.id)
                continue
            }
            let modificationTimeNS = Int64(
                (modificationDate.timeIntervalSince1970 * 1_000_000_000).rounded()
            )
            let decision = TokenCacheDecision.decide(
                rolloutPath: url.path,
                fileSize: size,
                modificationTime: modificationTimeNS,
                parserVersion: parserVersion,
                cachedRolloutPath: cached.rolloutPath,
                cachedFileSize: cached.fileSize,
                cachedModificationTime: cached.fileModificationTimeNS,
                cachedParserVersion: cached.parserVersion
            )
            if decision == .reuse, cached.scannedOffset == size {
                freshTargetIDs.insert(target.id)
            } else {
                staleTargetIDs.insert(target.id)
            }
        }

        return TokenScanHealth(
            freshTargetIDs: freshTargetIDs,
            staleTargetIDs: staleTargetIDs,
            failedTargetIDs: failedTargetIDs
        )
    }
}

struct SessionStateRevision {
    private(set) var current = 0
    private var loadingRevision: Int?

    mutating func begin(isLoading: Bool) -> Int {
        current += 1
        loadingRevision = isLoading ? current : nil
        return current
    }

    func accepts(_ revision: Int) -> Bool {
        revision == current
    }

    mutating func finishLoading(_ revision: Int) -> Bool {
        guard accepts(revision), loadingRevision == revision else { return false }
        loadingRevision = nil
        return true
    }
}

enum SessionFilter {
    static func apply(
        threads: [CodexThread],
        metadata: [String: ThreadMetadata],
        tags: [SessionTag],
        threadTags: [String: Set<String>],
        threadProjects: [String: ThreadProjectCache],
        projectIdentityIndex: ThreadProjectIdentityIndex = .empty,
        selection: SidebarSelection,
        query: String,
        timeFilter: SessionTimeFilter,
        sortOrder: SessionSortOrder,
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> [ManagedThread] {
        let managedThreads = threads.map { thread in
            let threadMetadata =
                metadata[thread.id]
                ?? ThreadMetadata(threadID: thread.id, isFavorite: false, collectionID: nil)
            let tagIDs = threadTags[thread.id] ?? []
            let attachedTags =
                tags
                .filter { tagIDs.contains($0.id) }
                .sorted {
                    if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                    return $0.id < $1.id
                }
            return ManagedThread(
                thread: thread,
                metadata: threadMetadata,
                tags: attachedTags,
                projectResolution: ThreadProjectClassification.effectiveResolution(
                    for: thread,
                    cached: threadProjects[thread.id],
                    projectIdentityIndex: projectIdentityIndex
                )
            )
        }

        let cutoff: Int64?
        switch timeFilter {
        case .all:
            cutoff = nil
        case .sevenDays:
            cutoff = now - 7 * 24 * 60 * 60
        case .thirtyDays:
            cutoff = now - 30 * 24 * 60 * 60
        }

        let searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return
            managedThreads
            .filter { matchesSelection($0, selection: selection, threadTags: threadTags) }
            .filter { thread in
                guard let cutoff else { return true }
                return thread.thread.activityTimestamp >= cutoff
            }
            .filter { searchQuery.isEmpty || matchesQuery($0, query: searchQuery) }
            .sorted { lhs, rhs in
                switch sortOrder {
                case .recent:
                    if lhs.thread.activityTimestamp != rhs.thread.activityTimestamp {
                        return lhs.thread.activityTimestamp > rhs.thread.activityTimestamp
                    }
                case .oldest:
                    if lhs.thread.activityTimestamp != rhs.thread.activityTimestamp {
                        return lhs.thread.activityTimestamp < rhs.thread.activityTimestamp
                    }
                case .title:
                    let comparison = lhs.thread.displayTitle.localizedCaseInsensitiveCompare(
                        rhs.thread.displayTitle
                    )
                    if comparison != .orderedSame { return comparison == .orderedAscending }
                }
                return lhs.id < rhs.id
            }
    }

    private static func matchesSelection(
        _ thread: ManagedThread,
        selection: SidebarSelection,
        threadTags: [String: Set<String>]
    ) -> Bool {
        switch selection {
        case .quota, .recent, .statistics, .archived:
            true
        case .favorites:
            thread.metadata.isFavorite
        case .unclassified:
            thread.metadata.collectionID == nil
        case .noProject:
            thread.projectResolution.isNoProject
        case .project(let path):
            thread.projectPath.map { ProjectDirectoryTree.contains(path: $0, in: path) } == true
        case .collection(let id):
            thread.metadata.collectionID == id
        case .tag(let id):
            threadTags[thread.id]?.contains(id) == true
        }
    }

    private static func matchesQuery(_ thread: ManagedThread, query: String) -> Bool {
        let values =
            [
                thread.thread.displayTitle,
                thread.thread.preview,
                thread.thread.cwd,
                thread.projectPath ?? "",
                thread.projectName,
                thread.thread.gitInfo?.branch ?? "",
            ] + thread.tags.map(\.name)
        return values.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

enum SessionRefreshPolicy {
    static func shouldRefresh(
        lastSuccessfulReloadAt: Date?,
        now: Date,
        maximumAge: TimeInterval
    ) -> Bool {
        guard let lastSuccessfulReloadAt else { return true }
        return now.timeIntervalSince(lastSuccessfulReloadAt) >= maximumAge
    }
}

enum SessionNestAutomaticSessionRefreshPolicy {
    // 低电量时完整会话扫描最多每小时一次，减少目录和数据库活动。
    static let lowPowerMinimumAge: TimeInterval = 60 * 60

    static func maximumAge(
        requestedMaximumAge: TimeInterval,
        isLowPowerModeEnabled: Bool
    ) -> TimeInterval {
        // 正常供电时完全沿用调用方设定的刷新周期。
        guard isLowPowerModeEnabled else { return requestedMaximumAge }
        // 低电量模式只延长自动刷新，不改变手动 reload 的行为。
        return max(requestedMaximumAge, lowPowerMinimumAge)
    }
}

enum TokenTimedRetentionPolicy {
    // 当天也计入保留窗口，因此 30 个本地自然日向前偏移 29 天。
    static let retainedDayCount = 30

    static func cutoff(now: Date, calendar: Calendar) -> Int64 {
        // 先落到本地自然日零点，避免固定秒数在夏令时切换时偏移日期。
        let today = calendar.startOfDay(for: now)
        // Calendar 按自然日回退，极端失败时保守退回当天而不是误留无限数据。
        let firstRetainedDay =
            calendar.date(byAdding: .day, value: -(retainedDayCount - 1), to: today)
            ?? today
        // SQLite 使用秒级 Unix 时间作为 timed 明细边界。
        return Int64(firstRetainedDay.timeIntervalSince1970)
    }

    static func shouldPrune(
        lastPrunedAt: Date?,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        // 首次运行必须执行一次清理，处理旧版本累积的历史明细。
        guard let lastPrunedAt else { return true }
        // 同一自然日内只清理一次，避免每轮扫描重复 DELETE。
        return !calendar.isDate(lastPrunedAt, inSameDayAs: now)
    }

    static func canRepresentExactRange(startingAt start: Int64, cutoff: Int64) -> Bool {
        // 查询起点早于保留边界时不能把残缺数据冒充完整额度周期。
        start >= cutoff
    }
}

@MainActor
final class SessionListModel: ObservableObject {
    @Published var activeThreads: [CodexThread] = []
    @Published var archivedThreads: [CodexThread] = []
    @Published var metadata: [String: ThreadMetadata] = [:]
    @Published var collections: [SessionCollection] = []
    @Published var tags: [SessionTag] = []
    @Published var threadTags: [String: Set<String>] = [:]
    @Published var threadProjects: [String: ThreadProjectCache] = [:]
    @Published private(set) var projectIdentityIndex: ThreadProjectIdentityIndex = .empty
    @Published var threadTokenCache: [String: ThreadTokenCache] = [:]
    @Published var threadTokenDailyUsage: [ThreadTokenDailyUsage] = []
    @Published private(set) var tokenCoveredThreadIDs: Set<String> = []
    @Published private(set) var tokenAttributionThreadIDs: [String: String] = [:]
    @Published private(set) var tokenScanHealth = TokenScanHealth.empty
    @Published private(set) var tokenScanDiagnostics: TokenScanDiagnostics?
    @Published private(set) var rateLimitSnapshot: CodexRateLimitSnapshot?
    @Published private(set) var resetCreditsSnapshot: CodexRateLimitResetCreditsSummary?
    @Published private(set) var accountSnapshot: CodexAccountSnapshot?
    @Published private(set) var quotaCycleStatisticsSnapshot: StatisticsSnapshot?
    @Published private(set) var lastSuccessfulReloadAt: Date?
    @Published private(set) var lastSuccessfulUsageRefreshAt: Date?
    // 自动刷新同时参考最近尝试，失败后不会在每次界面打开时立即重试。
    private(set) var lastUsageRefreshAttemptAt: Date?
    @Published var selection: SidebarSelection = .statistics
    @Published var selectedThreadID: String?
    @Published var query = ""
    @Published var timeFilter: SessionTimeFilter = .thirtyDays
    @Published var sortOrder: SessionSortOrder = .recent
    @Published var isLoading = true
    @Published var isClassifyingProjects = false
    @Published var isScanningTokenUsage = false
    @Published private(set) var isRefreshingUsage = false
    @Published private(set) var usageRefreshErrorMessage: String?
    @Published var errorMessage: String?

    let client: CodexClient
    let store: MetadataStore
    private let usageRefreshOperation: UsageRefreshOperation
    private let tokenScanOperation: TokenScanOperation
    private let tokenScanTargetDiscoveryOperation: IndexedTokenScanTargetDiscoveryOperation
    private let threadReloadOperation: ThreadReloadOperation?
    private let refreshesUsageDuringReload: Bool
    private var stateRevision = SessionStateRevision()
    private var classificationTask: Task<Void, Never>?
    private var classificationGeneration = 0
    private var classificationReplacementRequest = 0
    private var tokenScanTask: Task<Void, Never>?
    private var tokenScanGeneration = 0
    private var tokenScanReplacementRequest = 0
    private var reloadTask: Task<Void, Never>?
    private var rateLimitRefreshTask: Task<Void, Never>?
    private var usageRefreshGeneration = 0
    private var lastTimedUsagePruneAt: Date?

    private static let tokenParserVersion: Int64 = 3
    // 发现闭包在 utility 任务执行，版本常量不依赖主 actor 状态。
    nonisolated private static let tokenDiscoveryParserVersion: Int64 = 1
    static let automaticRefreshInterval: TimeInterval = 15 * 60

    var totalSessionCount: Int {
        activeThreads.count + archivedThreads.count
    }

    var quotaCycleTokenUsage: Int64? {
        quotaCycleStatisticsSnapshot?.totalUsage.totalTokens
    }

    var visibleThreads: [ManagedThread] {
        SessionFilter.apply(
            threads: selection == .archived ? archivedThreads : activeThreads,
            metadata: metadata,
            tags: tags,
            threadTags: threadTags,
            threadProjects: threadProjects,
            projectIdentityIndex: projectIdentityIndex,
            selection: selection,
            query: query,
            timeFilter: timeFilter,
            sortOrder: sortOrder
        )
    }

    var projectTree: [ProjectDirectoryNode] {
        ProjectDirectoryTree.build(
            threads: activeThreads,
            threadProjects: threadProjects,
            projectIdentityIndex: projectIdentityIndex
        )
    }

    var statisticsSnapshot: StatisticsSnapshot {
        statisticsSnapshot(for: timeFilter)
    }

    func statisticsSnapshot(for timeFilter: SessionTimeFilter) -> StatisticsSnapshot {
        SessionStatistics.build(
            threads: activeThreads + archivedThreads,
            coveredThreadIDs: tokenCoveredThreadIDs,
            dailyUsage: threadTokenDailyUsage,
            threadProjects: threadProjects,
            projectIdentityIndex: projectIdentityIndex,
            usageAttributionThreadIDs: tokenAttributionThreadIDs,
            timeFilter: timeFilter,
            calendar: .current,
            now: Int64(Date().timeIntervalSince1970)
        )
    }

    init(
        client: CodexClient,
        store: MetadataStore,
        rateLimitRefreshOperation: RateLimitRefreshOperation? = nil,
        usageRefreshOperation: UsageRefreshOperation? = nil,
        tokenScanOperation: @escaping TokenScanOperation = { url, offset, baseline, calendar in
            try RolloutTokenScanner.scan(
                url: url,
                fromOffset: offset,
                baseline: baseline,
                calendar: calendar
            )
        },
        tokenScanTargetDiscoveryOperation: TokenScanTargetDiscoveryOperation? = nil,
        threadReloadOperation: ThreadReloadOperation? = nil
    ) {
        self.client = client
        self.store = store
        if let usageRefreshOperation {
            self.usageRefreshOperation = usageRefreshOperation
        } else if let rateLimitRefreshOperation {
            self.usageRefreshOperation = {
                CodexUsageSnapshot(
                    rateLimits: try await rateLimitRefreshOperation(),
                    resetCredits: nil
                )
            }
        } else {
            self.usageRefreshOperation = { try await client.readUsageSnapshot() }
        }
        self.tokenScanOperation = tokenScanOperation
        if let tokenScanTargetDiscoveryOperation {
            // 测试和定制调用继续接受旧的 targets-only 闭包，避免扩大公开注入接口。
            self.tokenScanTargetDiscoveryOperation = { threads in
                // 调用方自行提供目标时没有发现 I/O 指标，使用零值明确区分。
                let targets = await tokenScanTargetDiscoveryOperation(threads)
                // 返回完整结果形态，让扫描主流程只维护一条路径。
                return TokenDiscoveryResult(
                    targets: targets,
                    changedCacheEntries: [],
                    removedCachePaths: [],
                    metrics: TokenDiscoveryMetrics(
                        enumeratedJSONLCount: 0,
                        cacheHitCount: 0,
                        metadataReadFileCount: 0,
                        metadataReadBytes: 0,
                        failedReadCount: 0
                    )
                )
            }
        } else {
            // 默认发现从 SQLite 读取持久索引，热刷新无需重读全部日志头。
            self.tokenScanTargetDiscoveryOperation = { [store] threads in
                // 索引读取失败时退化为冷发现，不阻断 Token 统计主功能。
                let cachedEntries: [String: TokenDiscoveryCacheEntry]
                let cacheLoadFailed: Bool
                do {
                    // 正常读取持久索引，未变化文件只需比较元数据。
                    cachedEntries = try await store.loadTokenDiscoveryCache()
                    cacheLoadFailed = false
                } catch {
                    // 读取失败时退化为冷发现，并把原因带到扫描诊断。
                    cachedEntries = [:]
                    cacheLoadFailed = true
                }
                // 目录枚举和日志头读取放到 utility 任务，避免阻塞主线程。
                let result = await Task.detached(priority: .utility) {
                    LocalTokenScanTargetDiscovery.discoverIndexed(
                        threads: threads,
                        cacheEntries: cachedEntries,
                        parserVersion: Self.tokenDiscoveryParserVersion
                    )
                }.value
                // 读取失败状态随发现结果返回，持久化将在主流程代际校验后执行。
                return cacheLoadFailed ? result.markingCacheStoreFailed() : result
            }
        }
        self.threadReloadOperation = threadReloadOperation
        refreshesUsageDuringReload =
            threadReloadOperation == nil
            || rateLimitRefreshOperation != nil
            || usageRefreshOperation != nil
    }

    func reload() async {
        if let reloadTask {
            await reloadTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await performReload()
        }
        reloadTask = task
        await task.value
        reloadTask = nil
    }

    private func performReload() async {
        let revision = beginStateRevision(isLoading: true)
        defer {
            if stateRevision.finishLoading(revision) {
                isLoading = false
            }
        }

        do {
            async let loadedThreadLists = loadThreadLists()
            async let loadedMetadata = store.loadMetadata()
            async let loadedCollections = store.loadCollections()
            async let loadedTags = store.loadTags()
            async let loadedThreadTags = store.loadThreadTags()
            async let loadedThreadProjects = store.loadThreadProjects()
            async let loadedThreadTokenCache = store.loadThreadTokenCache()
            async let loadedThreadTokenDailyUsage = store.loadThreadTokenDailyUsage()

            let result = try await (
                loadedThreadLists,
                loadedMetadata,
                loadedCollections,
                loadedTags,
                loadedThreadTags,
                loadedThreadProjects,
                loadedThreadTokenCache,
                loadedThreadTokenDailyUsage
            )
            let allThreads = result.0.0 + result.0.1
            let projectIdentityIndex = await Task.detached(priority: .utility) {
                ThreadProjectIdentityIndex.build(threads: allThreads)
            }.value
            let usageGeneration: Int?
            let usageSnapshot: CodexUsageSnapshot?
            if refreshesUsageDuringReload {
                // 完整 reload 读取额度也属于一次尝试，失败时同样进入自动退避周期。
                lastUsageRefreshAttemptAt = Date()
                let generation = beginUsageRefresh()
                usageGeneration = generation
                usageSnapshot = try? await usageRefreshOperation()
            } else {
                usageGeneration = nil
                usageSnapshot = nil
            }
            let accountSnapshot =
                threadReloadOperation == nil ? try? await client.readAccount() : nil
            guard stateRevision.accepts(revision) else { return }
            activeThreads = result.0.0
            archivedThreads = result.0.1
            metadata = result.1
            collections = result.2
            tags = result.3
            threadTags = result.4
            threadProjects = result.5
            self.projectIdentityIndex = projectIdentityIndex
            threadTokenCache = result.6
            threadTokenDailyUsage = result.7
            // 完整发现父会话和子代理日志前，先撤下仅由父日志推导的覆盖结果。
            tokenCoveredThreadIDs = []
            // 归属关系必须等待完整目标集，避免子代理缓存暂时按独立会话解释。
            tokenAttributionThreadIDs = [:]
            // 新一轮发现尚未形成健康快照，清空旧状态避免误报“已追平”。
            tokenScanHealth = .empty
            // 线程数据已经发布但日志目标仍在发现，立即进入扫描态阻止部分统计闪现。
            isScanningTokenUsage = true
            // 本额度周期快照是基于旧覆盖生成的，发现完成前不继续展示。
            quotaCycleStatisticsSnapshot = nil
            self.accountSnapshot = accountSnapshot
            let reloadCompletedAt = Date()
            lastSuccessfulReloadAt = reloadCompletedAt
            var acceptedUsageGeneration: Int?
            if let usageSnapshot,
                let usageGeneration,
                acceptsUsageRefresh(usageGeneration)
            {
                rateLimitSnapshot = usageSnapshot.rateLimits
                resetCreditsSnapshot = usageSnapshot.resetCredits
                lastSuccessfulUsageRefreshAt = reloadCompletedAt
                usageRefreshErrorMessage = nil
                acceptedUsageGeneration = usageGeneration
            }
            errorMessage = nil
            await refreshQuotaCycleStatistics(
                acceptingUsageGeneration: acceptedUsageGeneration
            )
            await startProjectClassification(
                for: allThreads,
                projectIdentityIndex: projectIdentityIndex
            )
            await startTokenUsageScan(for: allThreads)
        } catch {
            record(error, revision: revision)
        }
    }

    func reloadIfStale(
        now: Date = Date(),
        maximumAge: TimeInterval = automaticRefreshInterval,
        isLowPowerModeEnabled: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    ) async {
        // 只有自动入口应用低电量延长策略，显式 reload 仍立即执行。
        let effectiveMaximumAge = SessionNestAutomaticSessionRefreshPolicy.maximumAge(
            requestedMaximumAge: maximumAge,
            isLowPowerModeEnabled: isLowPowerModeEnabled
        )
        guard
            SessionRefreshPolicy.shouldRefresh(
                lastSuccessfulReloadAt: lastSuccessfulReloadAt,
                now: now,
                maximumAge: effectiveMaximumAge
            )
        else { return }

        await reload()
    }

    func refreshRateLimits(now: Date = Date()) async {
        if let rateLimitRefreshTask {
            await rateLimitRefreshTask.value
            return
        }

        // 手动或自动请求真正开始前记录尝试时间，失败也能抑制紧接着的重复请求。
        lastUsageRefreshAttemptAt = now
        isRefreshingUsage = true
        let task = Task { [weak self] in
            guard let self else { return }
            let generation = beginUsageRefresh()
            do {
                let snapshot = try await usageRefreshOperation()
                guard !Task.isCancelled, acceptsUsageRefresh(generation) else { return }
                rateLimitSnapshot = snapshot.rateLimits
                resetCreditsSnapshot = snapshot.resetCredits
                lastSuccessfulUsageRefreshAt = now
                usageRefreshErrorMessage = nil
                await refreshQuotaCycleStatistics(acceptingUsageGeneration: generation)
            } catch {
                guard acceptsUsageRefresh(generation) else { return }
                usageRefreshErrorMessage = error.localizedDescription
            }
        }
        rateLimitRefreshTask = task
        await task.value
        rateLimitRefreshTask = nil
        isRefreshingUsage = false
    }

    func refreshRateLimitsIfStale(
        now: Date = Date(),
        maximumAge: TimeInterval = SessionNestQuotaRefreshSchedule.interval,
        isLowPowerModeEnabled: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    ) async {
        // 在模型层统一应用低电量阈值，状态栏和主窗口不会再出现策略遗漏。
        let effectiveMaximumAge = SessionNestAutomaticQuotaRefreshPolicy.maximumAge(
            requestedMaximumAge: maximumAge,
            isLowPowerModeEnabled: isLowPowerModeEnabled
        )
        // 成功时间用于 UI，最近尝试时间用于失败退避；自动入口采用两者中较新的一个。
        let freshnessReference = [lastSuccessfulUsageRefreshAt, lastUsageRefreshAttemptAt]
            .compactMap { $0 }
            .max()
        guard
            SessionRefreshPolicy.shouldRefresh(
                lastSuccessfulReloadAt: freshnessReference,
                now: now,
                maximumAge: effectiveMaximumAge
            )
        else { return }

        await refreshRateLimits(now: now)
    }

    private func beginUsageRefresh() -> Int {
        usageRefreshGeneration += 1
        return usageRefreshGeneration
    }

    private func acceptsUsageRefresh(_ generation: Int) -> Bool {
        generation == usageRefreshGeneration
    }

    private func loadThreadLists() async throws -> ([CodexThread], [CodexThread]) {
        if let threadReloadOperation {
            return try await threadReloadOperation()
        }
        try await client.start()
        async let active = client.listThreads(archived: false, searchTerm: nil)
        async let archived = client.listThreads(archived: true, searchTerm: nil)
        return try await (active, archived)
    }

    func toggleFavorite(threadID: String) async {
        let revision = beginStateRevision(isLoading: false)
        let isFavorite = !(metadata[threadID]?.isFavorite ?? false)
        do {
            try await store.setFavorite(threadID: threadID, isFavorite: isFavorite)
            await refreshLocalState()
        } catch {
            record(error, revision: revision)
        }
    }

    func createCollection(name: String) async {
        let revision = beginStateRevision(isLoading: false)
        do {
            _ = try await store.createCollection(name: name)
            await refreshLocalState()
        } catch {
            record(error, revision: revision)
        }
    }

    func createTag(name: String, colorHex: String) async {
        let revision = beginStateRevision(isLoading: false)
        do {
            _ = try await store.createTag(name: name, colorHex: colorHex)
            await refreshLocalState()
        } catch {
            record(error, revision: revision)
        }
    }

    func move(threadID: String, to collectionID: String?) async {
        let revision = beginStateRevision(isLoading: false)
        do {
            try await store.assign(threadID: threadID, collectionID: collectionID)
            await refreshLocalState()
        } catch {
            record(error, revision: revision)
        }
    }

    func setTags(threadID: String, tagIDs: Set<String>) async {
        let revision = beginStateRevision(isLoading: false)
        do {
            try await store.setTags(threadID: threadID, tagIDs: tagIDs)
            await refreshLocalState()
        } catch {
            record(error, revision: revision)
        }
    }

    func archive(threadID: String) async {
        let revision = beginStateRevision(isLoading: false)
        do {
            try await client.archive(threadID: threadID)
            await reload()
        } catch {
            record(error, revision: revision)
        }
    }

    func unarchive(threadID: String) async {
        let revision = beginStateRevision(isLoading: false)
        do {
            try await client.unarchive(threadID: threadID)
            await reload()
        } catch {
            record(error, revision: revision)
        }
    }

    private func refreshLocalState() async {
        let revision = beginStateRevision(isLoading: false)
        do {
            async let loadedMetadata = store.loadMetadata()
            async let loadedCollections = store.loadCollections()
            async let loadedTags = store.loadTags()
            async let loadedThreadTags = store.loadThreadTags()
            let result = try await (
                loadedMetadata,
                loadedCollections,
                loadedTags,
                loadedThreadTags
            )
            guard stateRevision.accepts(revision) else { return }
            metadata = result.0
            collections = result.1
            tags = result.2
            threadTags = result.3
            errorMessage = nil
        } catch {
            record(error, revision: revision)
        }
    }

    private func beginStateRevision(isLoading: Bool) -> Int {
        let revision = stateRevision.begin(isLoading: isLoading)
        self.isLoading = isLoading
        return revision
    }

    private func startProjectClassification(
        for threads: [CodexThread],
        projectIdentityIndex: ThreadProjectIdentityIndex
    ) async {
        classificationReplacementRequest += 1
        let replacementRequest = classificationReplacementRequest
        let previousTask = classificationTask
        await ProjectClassificationTaskReplacement.cancelAndWait(for: previousTask)
        guard replacementRequest == classificationReplacementRequest else { return }

        classificationGeneration += 1
        let generation = classificationGeneration
        let staleThreads = threads.filter {
            ThreadProjectClassification.needsAnalysis(
                thread: $0,
                cached: threadProjects[$0.id]
            )
        }

        guard !staleThreads.isEmpty else {
            classificationTask = nil
            isClassifyingProjects = false
            return
        }

        isClassifyingProjects = true
        classificationTask = Task.detached { [weak self, client, store] in
            for thread in staleThreads {
                guard !Task.isCancelled,
                    await self?.acceptsClassification(
                        generation,
                        replacementRequest: replacementRequest
                    ) == true
                else { return }

                do {
                    let scratchRoot = CodexScratchWorkspaceDetector.sessionRoot(for: thread.cwd)
                    let resolution: ThreadProjectResolution
                    if let scratchRoot {
                        var evidence = try await client.readThreadEvidence(threadID: thread.id)
                        evidence.commandWorkingDirectories.insert(thread.cwd)
                        let candidates = try ThreadProjectScanner.scratchGitRepositories(
                            in: scratchRoot,
                            evidence: evidence
                        )
                        resolution =
                            ThreadProjectClassifier.classify(
                                evidence: evidence,
                                candidates: candidates
                            ).map(ThreadProjectResolution.project(path:)) ?? .noProject
                    } else if let canonicalProjectPath =
                        projectIdentityIndex.canonicalProjectPath(for: thread)
                    {
                        resolution = .project(path: canonicalProjectPath)
                    } else {
                        let candidates = try ThreadProjectScanner.directChildGitRepositories(
                            in: thread.cwd
                        )
                        if candidates.isEmpty {
                            resolution = .workingDirectory(
                                path: ProjectDirectoryTree.normalizedPath(thread.cwd)
                            )
                        } else {
                            let evidence = try await client.readThreadEvidence(threadID: thread.id)
                            resolution =
                                ThreadProjectClassifier.classify(
                                    evidence: evidence,
                                    candidates: candidates
                                ).map(ThreadProjectResolution.project(path:))
                                ?? .workingDirectory(
                                    path: ProjectDirectoryTree.normalizedPath(thread.cwd)
                                )
                        }
                    }
                    let cached = ThreadProjectCache(
                        threadID: thread.id,
                        resolution: resolution,
                        analyzedUpdatedAt: thread.updatedAt,
                        classifierVersion: ThreadProjectClassification.classifierVersion
                    )

                    guard !Task.isCancelled,
                        await self?.acceptsClassification(
                            generation,
                            replacementRequest: replacementRequest
                        ) == true
                    else { return }
                    try await store.saveThreadProject(cached)
                    guard !Task.isCancelled else { return }
                    await self?.publish(
                        cached,
                        generation: generation,
                        replacementRequest: replacementRequest
                    )
                } catch {
                    if Task.isCancelled { return }
                }
            }
            await self?.finishClassification(
                generation,
                replacementRequest: replacementRequest
            )
        }
    }

    private func acceptsClassification(
        _ generation: Int,
        replacementRequest: Int
    ) -> Bool {
        classificationGeneration == generation
            && classificationReplacementRequest == replacementRequest
    }

    private func publish(
        _ cached: ThreadProjectCache,
        generation: Int,
        replacementRequest: Int
    ) {
        guard
            acceptsClassification(
                generation,
                replacementRequest: replacementRequest
            )
        else { return }
        threadProjects[cached.threadID] = cached
    }

    private func finishClassification(
        _ generation: Int,
        replacementRequest: Int
    ) {
        guard
            acceptsClassification(
                generation,
                replacementRequest: replacementRequest
            )
        else { return }
        isClassifyingProjects = false
    }

    func startTokenUsageScan(for threads: [CodexThread]) async {
        // 每次请求先取得新的替换序号，保证旧扫描不能重新发布结果。
        tokenScanReplacementRequest += 1
        // 目标发现可能需要遍历目录，等待期间先明确标记扫描状态。
        isScanningTokenUsage = true
        // 完整目标集未知时不采用仅父日志或上一轮的覆盖结果。
        tokenCoveredThreadIDs = []
        // 归属映射必须和本轮目标同时发布，避免旧子代理映射污染统计。
        tokenAttributionThreadIDs = [:]
        // 清空旧健康结果，让界面准确显示正在发现日志。
        tokenScanHealth = .empty
        // 旧额度周期快照依赖旧覆盖，扫描完成前暂时撤下。
        quotaCycleStatisticsSnapshot = nil
        let replacementRequest = tokenScanReplacementRequest
        let previousTask = tokenScanTask
        previousTask?.cancel()
        await previousTask?.value
        guard replacementRequest == tokenScanReplacementRequest else { return }

        // 诊断耗时从真正开始发现目标时计算，不包含等待上一轮取消的时间。
        let scanStartedAt = Date()
        // 发现结果同时携带持久索引命中率和真实日志头读取量。
        var discoveryResult = await tokenScanTargetDiscoveryOperation(threads)
        guard replacementRequest == tokenScanReplacementRequest else { return }
        do {
            // 通过首次代际校验后才持久化增量，淘汰的旧发现不会主动覆盖新索引。
            try await store.updateTokenDiscoveryCache(
                changedEntries: discoveryResult.changedCacheEntries,
                removedPaths: discoveryResult.removedCachePaths
            )
        } catch {
            // 索引写入失败不阻断当前目标扫描，但必须进入可见诊断。
            discoveryResult = discoveryResult.markingCacheStoreFailed()
        }
        // 索引写入期间可能收到新请求，继续前必须再次确认代际。
        guard replacementRequest == tokenScanReplacementRequest else { return }
        // 后续覆盖、缓存和扫描全部使用同一份稳定目标集合。
        let targets = discoveryResult.targets
        let cached = (try? await store.loadThreadTokenCache()) ?? threadTokenCache
        // Token 缓存读取也是挂起点，避免旧请求恢复后覆盖新扫描任务。
        guard replacementRequest == tokenScanReplacementRequest else { return }
        tokenScanGeneration += 1
        let generation = tokenScanGeneration
        let parserVersion = Self.tokenParserVersion
        let calendar = Calendar.current
        // 细粒度事件只写入最近 30 个本地自然日，日汇总仍全部保存。
        let timedUsageCutoff = TokenTimedRetentionPolicy.cutoff(
            now: scanStartedAt,
            calendar: calendar
        )
        // 同一进程每个本地自然日最多执行一次全局历史明细清理。
        let shouldPruneTimedUsage = TokenTimedRetentionPolicy.shouldPrune(
            lastPrunedAt: lastTimedUsagePruneAt,
            now: scanStartedAt,
            calendar: calendar
        )
        let operation = tokenScanOperation

        tokenAttributionThreadIDs = Dictionary(
            uniqueKeysWithValues: targets.map { ($0.id, $0.attributionThreadID) }
        )
        tokenScanHealth = ThreadTokenCoverage.health(
            targets: targets,
            cache: cached,
            parserVersion: parserVersion
        ).markingFailed(discoveryResult.uncertainTargetIDs)
        tokenCoveredThreadIDs = ThreadTokenCoverage.measuredTargetIDs(
            targets: targets,
            cache: cached,
            health: tokenScanHealth
        )

        isScanningTokenUsage = true
        tokenScanTask = Task.detached(priority: .utility) { [weak self, store] in
            // 失败目标沿用既有覆盖健康语义，并进入本轮诊断。
            var failedTargetIDs = discoveryResult.uncertainTargetIDs
            // 完全命中 Token 缓存的目标不打开正文文件。
            var tokenCacheReuseCount = 0
            // 实际扫描调用数量包含全量重建和增量追加。
            var tokenReadFileCount = 0
            // 实际读取字节使用扫描前后偏移差累计。
            var tokenReadBytes: Int64 = 0
            for target in targets {
                guard !Task.isCancelled,
                    await self?.acceptsTokenScan(
                        generation,
                        replacementRequest: replacementRequest
                    ) == true
                else { return }
                let url = target.url
                guard url.pathExtension.lowercased() == "jsonl",
                    FileManager.default.isReadableFile(atPath: url.path)
                else {
                    failedTargetIDs.insert(target.id)
                    continue
                }

                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular,
                        let size = (attributes[.size] as? NSNumber)?.int64Value,
                        let modificationDate = attributes[.modificationDate] as? Date
                    else {
                        failedTargetIDs.insert(target.id)
                        continue
                    }
                    let modificationTimeNS = Int64(
                        (modificationDate.timeIntervalSince1970 * 1_000_000_000).rounded()
                    )
                    let previous = cached[target.id]
                    var decision =
                        previous.map {
                            TokenCacheDecision.decide(
                                rolloutPath: url.path,
                                fileSize: size,
                                modificationTime: modificationTimeNS,
                                parserVersion: parserVersion,
                                cachedRolloutPath: $0.rolloutPath,
                                cachedFileSize: $0.fileSize,
                                cachedModificationTime: $0.fileModificationTimeNS,
                                cachedParserVersion: $0.parserVersion
                            )
                        } ?? .rebuild
                    if decision == .reuse,
                        let previous,
                        previous.scannedOffset < size
                    {
                        decision = .append
                    } else if decision == .reuse,
                        let previous,
                        previous.scannedOffset > size
                    {
                        decision = .rebuild
                    }
                    // 子代理增量可能仍处于父会话 fork replay，保守全量重扫才能恢复阶段边界。
                    if decision == .append,
                        target.id != target.attributionThreadID
                    {
                        decision = .rebuild
                    }
                    // 没有任何检查点的普通日志增长后也从头扫描，避免从元数据之后错误恢复阶段。
                    if decision == .append,
                        let previous,
                        previous.latestEventTimestamp == nil,
                        previous.maximum.isZero
                    {
                        decision = .rebuild
                    }
                    // 完全复用时只累计命中数，不进入正文解析和数据库写入。
                    if decision == .reuse {
                        tokenCacheReuseCount += 1
                        continue
                    }

                    let offset: Int64
                    let baseline: TokenScanState
                    switch decision {
                    case .reuse:
                        continue
                    case .append:
                        guard let previous else { continue }
                        offset = previous.scannedOffset
                        baseline = TokenScanState(
                            maximum: previous.maximum,
                            dailyUsage: [:],
                            latestEventTimestamp: previous.latestEventTimestamp,
                            observedCheckpoint: true
                        )
                    case .rebuild:
                        offset = 0
                        baseline = .empty
                    }

                    // 即将调用解析器时才计为一次实际 Token 正文读取。
                    tokenReadFileCount += 1
                    let result = try await operation(url, offset, baseline, calendar)
                    // 解析器会读取到文件尾；按扫描前文件大小计入包含未换行尾段的真实字节。
                    tokenReadBytes += max(0, size - offset)
                    guard !Task.isCancelled,
                        await self?.acceptsTokenScan(
                            generation,
                            replacementRequest: replacementRequest
                        ) == true
                    else { return }
                    try await store.saveThreadTokenScan(
                        threadID: target.id,
                        rolloutPath: url.path,
                        fileSize: size,
                        fileModificationTimeNS: modificationTimeNS,
                        parserVersion: parserVersion,
                        result: result,
                        rebuild: decision == .rebuild,
                        timedUsageCutoff: timedUsageCutoff
                    )
                } catch {
                    if Task.isCancelled { return }
                    failedTargetIDs.insert(target.id)
                }
            }

            guard !Task.isCancelled,
                await self?.acceptsTokenScan(
                    generation,
                    replacementRequest: replacementRequest
                ) == true
            else { return }
            // 清理结果默认是零，数据库失败不会中断已完成的 Token 统计发布。
            var prunedTimedRowCount = 0
            // 只有成功执行清理时才记录日期，失败会在下一轮扫描继续重试。
            var timedUsagePrunedAt: Date?
            if shouldPruneTimedUsage {
                do {
                    // 删除严格早于保留边界的秒级明细，日汇总表不受影响。
                    prunedTimedRowCount = try await store.pruneThreadTokenTimedUsage(
                        before: timedUsageCutoff
                    )
                    // 用扫描开始时间标记本地自然日，避免跨午夜完成造成重复判断。
                    timedUsagePrunedAt = scanStartedAt
                } catch {
                    // 清理属于空间维护，失败时保留数据并让下次扫描重试。
                }
            }
            do {
                async let loadedCache = store.loadThreadTokenCache()
                async let loadedDailyUsage = store.loadThreadTokenDailyUsage()
                let result = try await (loadedCache, loadedDailyUsage)
                guard !Task.isCancelled else { return }
                // 完成时间在数据库回读后生成，因此耗时覆盖整条扫描链路。
                let completedAt = Date()
                // 汇总持久发现索引、Token 缓存和实际 I/O 指标供设置页诊断。
                let diagnostics = TokenScanDiagnostics(
                    completedAt: completedAt,
                    duration: max(0, completedAt.timeIntervalSince(scanStartedAt)),
                    discoveryEnumeratedFileCount: discoveryResult.metrics.enumeratedJSONLCount,
                    discoveryCacheHitCount: discoveryResult.metrics.cacheHitCount,
                    discoveryReadFileCount: discoveryResult.metrics.metadataReadFileCount,
                    discoveryReadBytes: discoveryResult.metrics.metadataReadBytes,
                    discoveryFailedReadCount: discoveryResult.metrics.failedReadCount,
                    discoveryCacheStoreFailed: discoveryResult.cacheStoreFailed,
                    targetCount: targets.count,
                    tokenCacheReuseCount: tokenCacheReuseCount,
                    tokenReadFileCount: tokenReadFileCount,
                    tokenReadBytes: tokenReadBytes,
                    failedTargetCount: failedTargetIDs.count,
                    prunedTimedRowCount: prunedTimedRowCount
                )
                await self?.publishTokenUsage(
                    cache: result.0,
                    dailyUsage: result.1,
                    targets: targets,
                    failedTargetIDs: failedTargetIDs,
                    diagnostics: diagnostics,
                    timedUsagePrunedAt: timedUsagePrunedAt,
                    generation: generation,
                    replacementRequest: replacementRequest
                )
            } catch {
                await self?.finishTokenScan(
                    generation,
                    replacementRequest: replacementRequest,
                    failedTargetIDs: Set(targets.map(\.id))
                )
            }
        }
    }

    private func acceptsTokenScan(_ generation: Int, replacementRequest: Int) -> Bool {
        tokenScanGeneration == generation
            && tokenScanReplacementRequest == replacementRequest
    }

    private func publishTokenUsage(
        cache: [String: ThreadTokenCache],
        dailyUsage: [ThreadTokenDailyUsage],
        targets: [TokenScanTarget],
        failedTargetIDs: Set<String>,
        diagnostics: TokenScanDiagnostics,
        timedUsagePrunedAt: Date?,
        generation: Int,
        replacementRequest: Int
    ) async {
        guard acceptsTokenScan(generation, replacementRequest: replacementRequest) else { return }
        threadTokenCache = cache
        threadTokenDailyUsage = dailyUsage
        tokenAttributionThreadIDs = Dictionary(
            uniqueKeysWithValues: targets.map { ($0.id, $0.attributionThreadID) }
        )
        tokenScanHealth = ThreadTokenCoverage.health(
            targets: targets,
            cache: cache,
            parserVersion: Self.tokenParserVersion
        ).markingFailed(failedTargetIDs)
        tokenCoveredThreadIDs = ThreadTokenCoverage.measuredTargetIDs(
            targets: targets,
            cache: cache,
            health: tokenScanHealth
        )
        // 只有通过代际检查的完整扫描可以替换上一次诊断。
        tokenScanDiagnostics = diagnostics
        // 成功清理后记录日期，保证同一自然日不重复执行全局 DELETE。
        if let timedUsagePrunedAt {
            lastTimedUsagePruneAt = timedUsagePrunedAt
        }
        await refreshQuotaCycleStatistics()
        isScanningTokenUsage = false
        tokenScanTask = nil
    }

    private func refreshQuotaCycleStatistics(
        now: Int64 = Int64(Date().timeIntervalSince1970),
        calendar: Calendar = .current,
        acceptingUsageGeneration: Int? = nil
    ) async {
        if let acceptingUsageGeneration {
            guard acceptsUsageRefresh(acceptingUsageGeneration) else { return }
        }
        guard
            let start = QuotaCycleWindow.startTimestamp(
                window: rateLimitSnapshot?.weeklyWindow
            )
        else {
            quotaCycleStatisticsSnapshot = nil
            return
        }

        // 秒级明细只保留最近 30 个本地自然日，先计算当前精确数据边界。
        let timedUsageCutoff = TokenTimedRetentionPolicy.cutoff(
            now: Date(timeIntervalSince1970: TimeInterval(now)),
            calendar: calendar
        )
        // 若额度周期早于保留边界，宁可不展示，也不能把部分数据当成完整周期。
        guard
            start <= now,
            TokenTimedRetentionPolicy.canRepresentExactRange(
                startingAt: start,
                cutoff: timedUsageCutoff
            )
        else {
            quotaCycleStatisticsSnapshot = nil
            return
        }

        do {
            let timedUsage = try await store.loadThreadTokenTimedUsage(
                startingAt: start,
                endingAt: now
            )
            if let acceptingUsageGeneration {
                guard acceptsUsageRefresh(acceptingUsageGeneration) else { return }
            }
            quotaCycleStatisticsSnapshot = SessionStatistics.build(
                threads: activeThreads + archivedThreads,
                coveredThreadIDs: tokenCoveredThreadIDs,
                timedUsage: timedUsage,
                threadProjects: threadProjects,
                projectIdentityIndex: projectIdentityIndex,
                usageAttributionThreadIDs: tokenAttributionThreadIDs,
                startingAt: start,
                calendar: calendar,
                now: now
            )
        } catch {
            if let acceptingUsageGeneration {
                guard acceptsUsageRefresh(acceptingUsageGeneration) else { return }
            }
            quotaCycleStatisticsSnapshot = nil
        }
    }

    private func finishTokenScan(
        _ generation: Int,
        replacementRequest: Int,
        failedTargetIDs: Set<String> = []
    ) async {
        guard acceptsTokenScan(generation, replacementRequest: replacementRequest) else { return }
        tokenScanHealth = tokenScanHealth.markingFailed(failedTargetIDs)
        tokenCoveredThreadIDs = tokenScanHealth.freshTargetIDs
        await refreshQuotaCycleStatistics()
        isScanningTokenUsage = false
        tokenScanTask = nil
    }

    private func record(_ error: Error, revision: Int) {
        guard stateRevision.accepts(revision) else { return }
        errorMessage = error.localizedDescription
    }

    func open(threadID: String) {
        guard let thread = (activeThreads + archivedThreads).first(where: { $0.id == threadID }),
            let url = thread.openURL
        else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
