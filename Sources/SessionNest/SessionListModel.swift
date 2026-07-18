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

enum SidebarSelection: Hashable {
    case recent
    case statistics
    case favorites
    case unclassified
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
    let projectPath: String

    var id: String { thread.id }
    var projectName: String { URL(fileURLWithPath: projectPath).lastPathComponent }
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
        threadProjects: [String: ThreadProjectCache]
    ) -> [ProjectDirectoryNode] {
        let directCounts = Dictionary(
            grouping: threads,
            by: {
                ThreadProjectClassification.effectivePath(
                    for: $0,
                    cached: threadProjects[$0.id]
                )
            }
        ).mapValues(\.count)
        let paths = Array(Set(directCounts.keys).union(threads.map { normalizedPath($0.cwd) }))
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
    static let classifierVersion: Int64 = 1

    static func effectiveResolution(
        for thread: CodexThread,
        cached: ThreadProjectCache?
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
        Set(
            threads.compactMap { thread in
                guard let cached = cache[thread.id],
                    let path = thread.path
                else { return nil }
                let url = URL(fileURLWithPath: path)
                guard url.pathExtension.lowercased() == "jsonl",
                    fileManager.isReadableFile(atPath: url.path),
                    let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                    attributes[.type] as? FileAttributeType == .typeRegular,
                    let size = (attributes[.size] as? NSNumber)?.int64Value,
                    let modificationDate = attributes[.modificationDate] as? Date
                else { return nil }
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
                return decision == .rebuild ? nil : thread.id
            })
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
                projectPath: ThreadProjectClassification.effectivePath(
                    for: thread,
                    cached: threadProjects[thread.id]
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
        case .recent, .statistics, .archived:
            true
        case .favorites:
            thread.metadata.isFavorite
        case .unclassified:
            thread.metadata.collectionID == nil
        case .project(let path):
            ProjectDirectoryTree.contains(path: thread.projectPath, in: path)
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
                thread.projectPath,
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

@MainActor
final class SessionListModel: ObservableObject {
    @Published var activeThreads: [CodexThread] = []
    @Published var archivedThreads: [CodexThread] = []
    @Published var metadata: [String: ThreadMetadata] = [:]
    @Published var collections: [SessionCollection] = []
    @Published var tags: [SessionTag] = []
    @Published var threadTags: [String: Set<String>] = [:]
    @Published var threadProjects: [String: ThreadProjectCache] = [:]
    @Published var threadTokenCache: [String: ThreadTokenCache] = [:]
    @Published var threadTokenDailyUsage: [ThreadTokenDailyUsage] = []
    @Published private(set) var tokenCoveredThreadIDs: Set<String> = []
    @Published private(set) var rateLimitSnapshot: CodexRateLimitSnapshot?
    @Published private(set) var accountSnapshot: CodexAccountSnapshot?
    @Published private(set) var lastSuccessfulReloadAt: Date?
    @Published var selection: SidebarSelection = .statistics
    @Published var selectedThreadID: String?
    @Published var query = ""
    @Published var timeFilter: SessionTimeFilter = .thirtyDays
    @Published var sortOrder: SessionSortOrder = .recent
    @Published var isLoading = true
    @Published var isClassifyingProjects = false
    @Published var isScanningTokenUsage = false
    @Published var errorMessage: String?

    let client: CodexClient
    let store: MetadataStore
    private let rateLimitRefreshOperation: RateLimitRefreshOperation
    private let tokenScanOperation: TokenScanOperation
    private let threadReloadOperation: ThreadReloadOperation?
    private var stateRevision = SessionStateRevision()
    private var classificationTask: Task<Void, Never>?
    private var classificationGeneration = 0
    private var classificationReplacementRequest = 0
    private var tokenScanTask: Task<Void, Never>?
    private var tokenScanGeneration = 0
    private var tokenScanReplacementRequest = 0
    private var reloadTask: Task<Void, Never>?
    private var rateLimitRefreshTask: Task<Void, Never>?

    private static let tokenParserVersion: Int64 = 1
    static let automaticRefreshInterval: TimeInterval = 15 * 60

    var totalSessionCount: Int {
        activeThreads.count + archivedThreads.count
    }

    var visibleThreads: [ManagedThread] {
        SessionFilter.apply(
            threads: selection == .archived ? archivedThreads : activeThreads,
            metadata: metadata,
            tags: tags,
            threadTags: threadTags,
            threadProjects: threadProjects,
            selection: selection,
            query: query,
            timeFilter: timeFilter,
            sortOrder: sortOrder
        )
    }

    var projectTree: [ProjectDirectoryNode] {
        ProjectDirectoryTree.build(threads: activeThreads, threadProjects: threadProjects)
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
            timeFilter: timeFilter,
            calendar: .current,
            now: Int64(Date().timeIntervalSince1970)
        )
    }

    func currentQuotaCycleTokenUsage(
        now: Int64 = Int64(Date().timeIntervalSince1970),
        calendar: Calendar = .current
    ) -> Int64? {
        QuotaCycleTokenUsage.totalTokens(
            dailyUsage: threadTokenDailyUsage,
            coveredThreadIDs: tokenCoveredThreadIDs,
            knownThreadIDs: Set((activeThreads + archivedThreads).map(\.id)),
            window: rateLimitSnapshot?.weeklyWindow,
            calendar: calendar,
            now: now
        )
    }

    func currentQuotaCycleStatisticsSnapshot(
        calendar: Calendar = .current,
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> StatisticsSnapshot? {
        guard
            let startDay = QuotaCycleWindow.startDay(
                window: rateLimitSnapshot?.weeklyWindow,
                calendar: calendar
            )
        else { return nil }

        return SessionStatistics.build(
            threads: activeThreads + archivedThreads,
            coveredThreadIDs: tokenCoveredThreadIDs,
            dailyUsage: threadTokenDailyUsage,
            threadProjects: threadProjects,
            startingAt: startDay,
            calendar: calendar,
            now: now
        )
    }

    init(
        client: CodexClient,
        store: MetadataStore,
        rateLimitRefreshOperation: RateLimitRefreshOperation? = nil,
        tokenScanOperation: @escaping TokenScanOperation = { url, offset, baseline, calendar in
            try RolloutTokenScanner.scan(
                url: url,
                fromOffset: offset,
                baseline: baseline,
                calendar: calendar
            )
        },
        threadReloadOperation: ThreadReloadOperation? = nil
    ) {
        self.client = client
        self.store = store
        self.rateLimitRefreshOperation =
            rateLimitRefreshOperation ?? { try await client.readRateLimits() }
        self.tokenScanOperation = tokenScanOperation
        self.threadReloadOperation = threadReloadOperation
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
            let rateLimitSnapshot =
                threadReloadOperation == nil ? try? await client.readRateLimits() : nil
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
            threadTokenCache = result.6
            threadTokenDailyUsage = result.7
            tokenCoveredThreadIDs = ThreadTokenCoverage.validThreadIDs(
                threads: result.0.0 + result.0.1,
                cache: result.6,
                parserVersion: Self.tokenParserVersion
            )
            self.rateLimitSnapshot = rateLimitSnapshot
            self.accountSnapshot = accountSnapshot
            lastSuccessfulReloadAt = Date()
            errorMessage = nil
            await startProjectClassification(for: result.0.0 + result.0.1)
            await startTokenUsageScan(for: result.0.0 + result.0.1)
        } catch {
            record(error, revision: revision)
        }
    }

    func reloadIfStale(
        now: Date = Date(),
        maximumAge: TimeInterval = automaticRefreshInterval
    ) async {
        guard
            SessionRefreshPolicy.shouldRefresh(
                lastSuccessfulReloadAt: lastSuccessfulReloadAt,
                now: now,
                maximumAge: maximumAge
            )
        else { return }

        await reload()
    }

    func refreshRateLimits() async {
        if let rateLimitRefreshTask {
            await rateLimitRefreshTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await rateLimitRefreshOperation()
                guard !Task.isCancelled else { return }
                rateLimitSnapshot = snapshot
            } catch {
                return
            }
        }
        rateLimitRefreshTask = task
        await task.value
        rateLimitRefreshTask = nil
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

    private func startProjectClassification(for threads: [CodexThread]) async {
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
                        resolution = ThreadProjectClassifier.classify(
                            evidence: evidence,
                            candidates: candidates
                        ).map(ThreadProjectResolution.project(path:)) ?? .noProject
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
                            resolution = ThreadProjectClassifier.classify(
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
        tokenScanReplacementRequest += 1
        let replacementRequest = tokenScanReplacementRequest
        let previousTask = tokenScanTask
        previousTask?.cancel()
        await previousTask?.value
        guard replacementRequest == tokenScanReplacementRequest else { return }

        let cached = (try? await store.loadThreadTokenCache()) ?? threadTokenCache
        tokenScanGeneration += 1
        let generation = tokenScanGeneration
        let parserVersion = Self.tokenParserVersion
        let calendar = Calendar.current
        let operation = tokenScanOperation

        isScanningTokenUsage = true
        tokenScanTask = Task.detached(priority: .utility) { [weak self, store] in
            for thread in threads {
                guard !Task.isCancelled,
                    await self?.acceptsTokenScan(
                        generation,
                        replacementRequest: replacementRequest
                    ) == true
                else { return }
                guard let path = thread.path else { continue }
                let url = URL(fileURLWithPath: path)
                guard url.pathExtension.lowercased() == "jsonl",
                    FileManager.default.isReadableFile(atPath: url.path)
                else { continue }

                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular,
                        let size = (attributes[.size] as? NSNumber)?.int64Value,
                        let modificationDate = attributes[.modificationDate] as? Date
                    else {
                        continue
                    }
                    let modificationTimeNS = Int64(
                        (modificationDate.timeIntervalSince1970 * 1_000_000_000).rounded()
                    )
                    let previous = cached[thread.id]
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
                    }
                    guard decision != .reuse else { continue }

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

                    let result = try await operation(url, offset, baseline, calendar)
                    guard !Task.isCancelled,
                        await self?.acceptsTokenScan(
                            generation,
                            replacementRequest: replacementRequest
                        ) == true
                    else { return }
                    try await store.saveThreadTokenScan(
                        threadID: thread.id,
                        rolloutPath: url.path,
                        fileSize: size,
                        fileModificationTimeNS: modificationTimeNS,
                        parserVersion: parserVersion,
                        result: result,
                        rebuild: decision == .rebuild
                    )
                } catch {
                    if Task.isCancelled { return }
                }
            }

            guard !Task.isCancelled,
                await self?.acceptsTokenScan(
                    generation,
                    replacementRequest: replacementRequest
                ) == true
            else { return }
            do {
                async let loadedCache = store.loadThreadTokenCache()
                async let loadedDailyUsage = store.loadThreadTokenDailyUsage()
                let result = try await (loadedCache, loadedDailyUsage)
                guard !Task.isCancelled else { return }
                await self?.publishTokenUsage(
                    cache: result.0,
                    dailyUsage: result.1,
                    generation: generation,
                    replacementRequest: replacementRequest
                )
            } catch {
                await self?.finishTokenScan(
                    generation,
                    replacementRequest: replacementRequest
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
        generation: Int,
        replacementRequest: Int
    ) {
        guard acceptsTokenScan(generation, replacementRequest: replacementRequest) else { return }
        threadTokenCache = cache
        threadTokenDailyUsage = dailyUsage
        tokenCoveredThreadIDs = ThreadTokenCoverage.validThreadIDs(
            threads: activeThreads + archivedThreads,
            cache: cache,
            parserVersion: Self.tokenParserVersion
        )
        isScanningTokenUsage = false
        tokenScanTask = nil
    }

    private func finishTokenScan(_ generation: Int, replacementRequest: Int) {
        guard acceptsTokenScan(generation, replacementRequest: replacementRequest) else { return }
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
