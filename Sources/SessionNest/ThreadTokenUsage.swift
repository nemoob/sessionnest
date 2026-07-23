import Foundation

struct TokenUsageBreakdown: Codable, Equatable, Sendable {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64

    static let zero = TokenUsageBreakdown(
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        totalTokens: 0
    )

    var isZero: Bool { self == .zero }

    var nonCachedTokens: Int64 {
        // 缓存输入是总 Token 的子集，先收敛到有效范围再相减，避免重复计数或负值。
        let total = max(0, totalTokens)
        let cached = min(total, max(0, cachedInputTokens))
        return total - cached
    }

    func componentwiseMaximum(_ other: Self) -> Self {
        Self(
            inputTokens: max(inputTokens, other.inputTokens),
            cachedInputTokens: max(cachedInputTokens, other.cachedInputTokens),
            outputTokens: max(outputTokens, other.outputTokens),
            reasoningOutputTokens: max(reasoningOutputTokens, other.reasoningOutputTokens),
            totalTokens: max(totalTokens, other.totalTokens)
        )
    }

    func positiveDelta(from previous: Self) -> Self {
        Self(
            inputTokens: inputTokens > previous.inputTokens
                ? inputTokens - previous.inputTokens : 0,
            cachedInputTokens: cachedInputTokens > previous.cachedInputTokens
                ? cachedInputTokens - previous.cachedInputTokens : 0,
            outputTokens: outputTokens > previous.outputTokens
                ? outputTokens - previous.outputTokens : 0,
            reasoningOutputTokens: reasoningOutputTokens > previous.reasoningOutputTokens
                ? reasoningOutputTokens - previous.reasoningOutputTokens : 0,
            totalTokens: totalTokens > previous.totalTokens ? totalTokens - previous.totalTokens : 0
        )
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            reasoningOutputTokens: lhs.reasoningOutputTokens + rhs.reasoningOutputTokens,
            totalTokens: lhs.totalTokens + rhs.totalTokens
        )
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
    }
}

enum TokenUsageDefinition {
    static let explanation =
        "总 Token 取本地日志 total_tokens（已包含缓存输入）；非缓存 Token 为总 Token 减缓存输入，最低为 0。"
        + "额度消耗只采用 Codex 服务端百分比，本地 Token 不参与换算。"
}

struct TokenScanState: Equatable, Sendable {
    var maximum: TokenUsageBreakdown
    var dailyUsage: [Int64: TokenUsageBreakdown]
    var timedUsage: [Int64: TokenUsageBreakdown] = [:]
    var latestEventTimestamp: Int64?
    var observedCheckpoint: Bool

    static let empty = TokenScanState(
        maximum: .zero,
        dailyUsage: [:],
        latestEventTimestamp: nil,
        observedCheckpoint: false
    )
}

struct TokenScanResult: Equatable, Sendable {
    let offset: Int64
    let state: TokenScanState
    let duplicateTokenCheckpointCount: Int

    init(
        offset: Int64,
        state: TokenScanState,
        duplicateTokenCheckpointCount: Int = 0
    ) {
        self.offset = offset
        self.state = state
        self.duplicateTokenCheckpointCount = duplicateTokenCheckpointCount
    }

    var maximum: TokenUsageBreakdown { state.maximum }
    var dailyUsage: [Int64: TokenUsageBreakdown] { state.dailyUsage }
    var timedUsage: [Int64: TokenUsageBreakdown] { state.timedUsage }
    var latestEventTimestamp: Int64? { state.latestEventTimestamp }
    var observedCheckpoint: Bool { state.observedCheckpoint }
}

struct TokenScanTarget: Equatable, Sendable {
    let id: String
    let attributionThreadID: String
    let url: URL
}

struct TokenUsageRecalculationRange: Equatable, Sendable {
    let startDay: Int64
    let endDayExclusive: Int64

    init?(from startDate: Date, through endDate: Date, calendar: Calendar) {
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        guard start <= end,
            let endDayExclusive = calendar.date(byAdding: .day, value: 1, to: end)
        else { return nil }
        startDay = Int64(start.timeIntervalSince1970)
        self.endDayExclusive = Int64(endDayExclusive.timeIntervalSince1970)
    }

    func contains(_ timestamp: Int64) -> Bool {
        timestamp >= startDay && timestamp < endDayExclusive
    }
}

struct TokenDiscoveryCacheEntry: Equatable, Sendable {
    // 路径作为发现缓存主键，使文件元数据可在知道会话 ID 前复用。
    let rolloutPath: String
    // 文件大小用于识别新增内容或替换后的日志。
    let fileSize: Int64
    // 纳秒修改时间与大小共同判断文件内容是否保持不变。
    let fileModificationTimeNS: Int64
    // 子代理 ID 为空表示该文件已成功检查且不是子代理日志。
    let subagentID: String?
    // 父会话 ID 与子代理 ID 同时存在时才能恢复归属关系。
    let parentThreadID: String?
    // 解析器版本变化时必须重新检查文件前缀。
    let parserVersion: Int64
}

struct TokenDiscoveryMetrics: Equatable, Sendable {
    // 记录目录枚举看到的 JSONL 数量，作为发现工作的总基数。
    let enumeratedJSONLCount: Int
    // 记录 path、size、mtime 和版本完全匹配的缓存数量。
    let cacheHitCount: Int
    // 记录实际尝试读取日志前缀的文件数量。
    let metadataReadFileCount: Int
    // 记录成功读入内存的前缀字节数，便于评估磁盘开销。
    let metadataReadBytes: Int64
    // 记录无法取得属性或读取前缀的文件数量。
    let failedReadCount: Int
}

struct TokenDiscoveryResult: Equatable, Sendable {
    // targets 是本轮可供 Token 扫描使用的完整父子目标集合。
    let targets: [TokenScanTarget]
    // changedCacheEntries 只包含新增或发生变化且成功检查的文件。
    let changedCacheEntries: [TokenDiscoveryCacheEntry]
    // removedCachePaths 只包含已完整枚举根目录中不再存在的缓存路径。
    let removedCachePaths: Set<String>
    // metrics 暴露真实发现成本，避免 UI 只统计 Token 正文读取量。
    let metrics: TokenDiscoveryMetrics
    // 不确定目标沿用旧父子关系参与扫描，但本轮必须排除出可信覆盖。
    let uncertainTargetIDs: Set<String>
    // 无法关联到已知子代理的读取失败可能隐藏任意归属，必须撤下整轮覆盖。
    let hasUnattributedReadFailure: Bool
    // 缓存存储访问失败时继续发布目标，同时让诊断解释为何无法命中。
    let cacheStoreFailed: Bool

    init(
        targets: [TokenScanTarget],
        changedCacheEntries: [TokenDiscoveryCacheEntry],
        removedCachePaths: Set<String>,
        metrics: TokenDiscoveryMetrics,
        uncertainTargetIDs: Set<String> = [],
        hasUnattributedReadFailure: Bool = false,
        cacheStoreFailed: Bool = false
    ) {
        // 保存本轮完整目标集合。
        self.targets = targets
        // 保存需要持久化的索引增量。
        self.changedCacheEntries = changedCacheEntries
        // 保存已确认消失的缓存路径。
        self.removedCachePaths = removedCachePaths
        // 保存目录发现产生的实际 I/O 指标。
        self.metrics = metrics
        // 保存因发现读取失败而不能信任归属的目标。
        self.uncertainTargetIDs = uncertainTargetIDs
        // 保存无法缩小到具体目标的发现失败，供覆盖层采取保守策略。
        self.hasUnattributedReadFailure = hasUnattributedReadFailure
        // 保存缓存存储是否发生读写失败。
        self.cacheStoreFailed = cacheStoreFailed
    }

    var unreliableTargetIDs: Set<String> {
        // 未知日志可能属于任意父会话，无法安全地只撤下部分覆盖。
        guard hasUnattributedReadFailure else { return uncertainTargetIDs }
        return Set(targets.map(\.id))
    }

    func markingCacheStoreFailed() -> Self {
        // 只改变诊断状态，已发现目标和增量仍可用于当前扫描或后续重试。
        Self(
            targets: targets,
            changedCacheEntries: changedCacheEntries,
            removedCachePaths: removedCachePaths,
            metrics: metrics,
            uncertainTargetIDs: uncertainTargetIDs,
            hasUnattributedReadFailure: hasUnattributedReadFailure,
            cacheStoreFailed: true
        )
    }
}

struct TokenScanHealth: Equatable, Sendable {
    let freshTargetIDs: Set<String>
    let staleTargetIDs: Set<String>
    let failedTargetIDs: Set<String>

    static let empty = TokenScanHealth(
        freshTargetIDs: [],
        staleTargetIDs: [],
        failedTargetIDs: []
    )

    var totalCount: Int {
        freshTargetIDs.count + staleTargetIDs.count + failedTargetIDs.count
    }

    var freshCount: Int { freshTargetIDs.count }
    var staleCount: Int { staleTargetIDs.count }
    var failedCount: Int { failedTargetIDs.count }

    func markingFailed(_ targetIDs: Set<String>) -> Self {
        Self(
            freshTargetIDs: freshTargetIDs.subtracting(targetIDs),
            staleTargetIDs: staleTargetIDs.subtracting(targetIDs),
            failedTargetIDs: failedTargetIDs.union(targetIDs)
        )
    }
}

enum LocalTokenScanTargetDiscovery {
    static func discover(
        threads: [CodexThread],
        roots: [URL] = defaultRoots(),
        fileManager: FileManager = .default
    ) -> [TokenScanTarget] {
        // 兼容旧调用：不提供持久缓存时保持每次完整发现的既有行为。
        discoverIndexed(
            threads: threads,
            cacheEntries: [:],
            parserVersion: 1,
            roots: roots,
            fileManager: fileManager
        ).targets
    }

    static func discoverIndexed(
        threads: [CodexThread],
        cacheEntries: [String: TokenDiscoveryCacheEntry],
        parserVersion: Int64,
        roots: [URL] = defaultRoots(),
        fileManager: FileManager = .default
    ) -> TokenDiscoveryResult {
        // 可见会话 ID 是子代理沿父链向上归属的终点。
        let visibleThreadIDs = Set(threads.map(\.id))
        // 可见会话自身始终作为扫描目标，不依赖目录发现结果。
        var targets = Dictionary(
            uniqueKeysWithValues: threads.compactMap { thread -> (String, TokenScanTarget)? in
                // 没有本地日志路径的远端会话无法参与 Token 扫描。
                guard let path = thread.path else { return nil }
                // 父会话默认把用量归属给自己。
                return (
                    thread.id,
                    TokenScanTarget(
                        id: thread.id,
                        attributionThreadID: thread.id,
                        url: URL(fileURLWithPath: path)
                    )
                )
            }
        )
        // 所有已知子代理先保存直接父关系，随后统一解析多级链路。
        var subagents: [String: (parentID: String, url: URL)] = [:]
        // 标准化根目录路径，避免尾部斜杠影响包含判断。
        let normalizedRoots = roots.map { $0.standardizedFileURL.path }
        // 只有会话确实位于 Codex 日志根目录时才承担全目录发现成本。
        let hasThreadInRoots = targets.values.contains { target in
            // 标准化目标路径后再与根目录比较。
            let path = target.url.standardizedFileURL.path
            // 同时接受目标恰好等于根目录和位于根目录子层级两种情况。
            return normalizedRoots.contains { root in
                path == root || path.hasPrefix(root + "/")
            }
        }

        // seenPaths 用于区分真正删除的缓存和本轮仍存在的文件。
        var seenPaths: Set<String> = []
        // completedRootPaths 仅记录无枚举错误的根目录，防止误删暂时不可见缓存。
        var completedRootPaths: Set<String> = []
        // changedCacheEntries 只返回需要持久化的增量，避免每轮重写整张表。
        var changedCacheEntries: [TokenDiscoveryCacheEntry] = []
        // 以下计数直接反映目录发现产生的元数据和内容 I/O。
        var enumeratedJSONLCount = 0
        var cacheHitCount = 0
        var metadataReadFileCount = 0
        var metadataReadBytes: Int64 = 0
        var failedReadCount = 0
        // 变化文件读取失败时沿用旧关系扫描，但必须把对应目标标记为不确定。
        var uncertainTargetIDs: Set<String> = []
        // 没有正向缓存的失败无法定位归属，需要撤下整轮可信覆盖。
        var hasUnattributedReadFailure = false

        // 当前实现与旧逻辑一致：一旦存在根内会话，就检查传入的全部日志根目录。
        for root in roots where hasThreadInRoots {
            // 任一子路径枚举失败时不对该根目录生成删除集合。
            var enumerationFailed = false
            // 预取常用资源值，避免命中缓存前再调用 attributesOfItem。
            let resourceKeys: Set<URLResourceKey> = [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ]
            // 枚举错误继续其他目录，但会阻止本根目录清理旧缓存。
            guard
                let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: [.skipsHiddenFiles],
                    errorHandler: { _, _ in
                        // 记录不完整枚举，避免把权限或瞬时错误解释为文件删除。
                        enumerationFailed = true
                        // 返回 true 继续处理仍可访问的其他路径。
                        return true
                    }
                )
            else { continue }
            // 逐个处理 JSONL；目录和非日志文件不会进入缓存。
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
                // 统计所有枚举到的 JSONL 候选项。
                enumeratedJSONLCount += 1
                // 标准化路径，使内存字典、SQLite 主键和删除判断保持一致。
                let path = url.standardizedFileURL.path
                // 重叠根目录可能重复返回同一路径，只处理首次出现的一项。
                guard seenPaths.insert(path).inserted else { continue }
                // 取出历史项，读取失败时可保守恢复已知的正向父子关系。
                let cached = cacheEntries[path]

                let values: URLResourceValues
                do {
                    // 获取当前 size 和 mtime，命中时无需打开 JSONL。
                    values = try url.resourceValues(forKeys: resourceKeys)
                } catch {
                    // 属性读取失败意味着无法验证缓存是否仍然新鲜。
                    failedReadCount += 1
                    // 若以前确认过子代理关系，继续保留目标以免父会话误报完整覆盖。
                    if let id = restoreCachedSubagent(cached, url: url, into: &subagents) {
                        // 旧父子关系仅作保守占位，不能作为本轮可信统计覆盖。
                        uncertainTargetIDs.insert(id)
                    } else {
                        // 负缓存或无缓存不能证明该变化文件仍不是子代理。
                        hasUnattributedReadFailure = true
                    }
                    continue
                }
                // 目录等伪装成 .jsonl 的条目不能作为日志读取。
                guard values.isRegularFile == true,
                    let fileSize = values.fileSize,
                    let modificationDate = values.contentModificationDate
                else {
                    // 非普通文件或属性不全视为发现失败。
                    failedReadCount += 1
                    // 失败时保留既有正向关系，并留待下一轮重试。
                    if let id = restoreCachedSubagent(cached, url: url, into: &subagents) {
                        // 属性不完整时同样排除复用关系，等待下轮重新确认。
                        uncertainTargetIDs.insert(id)
                    } else {
                        // 无法从旧索引确定归属时不能把其他会话误报为完整。
                        hasUnattributedReadFailure = true
                    }
                    continue
                }
                // 与现有 Token 缓存使用相同的纳秒时间表示。
                let modificationTimeNS = Int64(
                    (modificationDate.timeIntervalSince1970 * 1_000_000_000).rounded()
                )
                // path、size、mtime 和解析器版本全部一致才允许跳过内容读取。
                if let cached,
                    cached.rolloutPath == path,
                    cached.fileSize == Int64(fileSize),
                    cached.fileModificationTimeNS == modificationTimeNS,
                    cached.parserVersion == parserVersion
                {
                    // 命中项复用正向或负向元数据。
                    cacheHitCount += 1
                    // 负缓存没有子代理 ID，因此该调用不会产生扫描目标。
                    restoreCachedSubagent(cached, url: url, into: &subagents)
                    continue
                }

                // 未命中项才会真正打开文件并读取前 64 KiB。
                metadataReadFileCount += 1
                // 读取结果区分“成功但不是子代理”和“读取失败”。
                switch readSubagentMetadata(at: url) {
                case .success(let metadata, let bytesRead):
                    // 累加实际进入内存的字节数，空文件会贡献 0。
                    metadataReadBytes += bytesRead
                    // 成功读取必须写入正缓存或负缓存，供下一轮直接复用。
                    let entry = TokenDiscoveryCacheEntry(
                        rolloutPath: path,
                        fileSize: Int64(fileSize),
                        fileModificationTimeNS: modificationTimeNS,
                        subagentID: metadata?.id,
                        parentThreadID: metadata?.parentID,
                        parserVersion: parserVersion
                    )
                    // 只把新增或变化项交给持久层更新。
                    changedCacheEntries.append(entry)
                    // 正向结果参与本轮父链解析；负结果仅进入缓存。
                    restoreCachedSubagent(entry, url: url, into: &subagents)
                case .failure:
                    // 读取失败不能写负缓存，否则权限恢复后仍会被永久跳过。
                    failedReadCount += 1
                    // 保留旧正向关系，使后续 Token 扫描能把该目标标记失败。
                    if let id = restoreCachedSubagent(cached, url: url, into: &subagents) {
                        // 前缀读取失败时正文即使成功，也不能证明旧父子关系仍然有效。
                        uncertainTargetIDs.insert(id)
                    } else {
                        // 读取失败可能隐藏新的子代理关系，只能保守撤下全局覆盖。
                        hasUnattributedReadFailure = true
                    }
                }
            }
            // 只有整个根目录枚举完整时才允许清理本根目录的消失路径。
            if !enumerationFailed {
                // 标准化根路径后加入删除范围。
                completedRootPaths.insert(root.standardizedFileURL.path)
            }
        }

        // 子代理可以通过其他子代理逐层向上找到可见父会话。
        for (id, subagent) in subagents {
            // 从直接父 ID 开始向上解析。
            var parentID = subagent.parentID
            // visited 防止损坏日志形成父链环路。
            var visited: Set<String> = [id]
            // 未抵达可见会话时继续沿已发现父关系上溯。
            while !visibleThreadIDs.contains(parentID),
                let parent = subagents[parentID],
                visited.insert(parentID).inserted
            {
                // 更新为更上一层父 ID。
                parentID = parent.parentID
            }
            // 无法抵达可见会话的孤立子代理不参与当前统计。
            guard visibleThreadIDs.contains(parentID) else { continue }
            // 最终目标把子代理 Token 归属到最上层可见父会话。
            targets[id] = TokenScanTarget(
                id: id,
                attributionThreadID: parentID,
                url: subagent.url
            )
        }

        // 仅在完整枚举的根目录内识别真正消失的缓存路径。
        let removedCachePaths = Set(
            cacheEntries.values.compactMap { entry -> String? in
                // 标准化历史路径，兼容旧数据中可能存在的路径表现差异。
                let path = URL(fileURLWithPath: entry.rolloutPath).standardizedFileURL.path
                // 未完整扫描的根目录不能产生删除操作。
                guard
                    completedRootPaths.contains(where: { root in
                        path == root || path.hasPrefix(root + "/")
                    })
                else { return nil }
                // 本轮仍见到的路径应继续保留。
                guard !seenPaths.contains(path) else { return nil }
                // 返回持久层实际使用的原始主键。
                return entry.rolloutPath
            }
        )
        // 保持旧 API 的稳定排序，避免缓存引入 UI 顺序变化。
        let sortedTargets = targets.values.sorted { $0.id > $1.id }
        // 汇总本轮真实 I/O 数据，交给诊断层展示或测试。
        let metrics = TokenDiscoveryMetrics(
            enumeratedJSONLCount: enumeratedJSONLCount,
            cacheHitCount: cacheHitCount,
            metadataReadFileCount: metadataReadFileCount,
            metadataReadBytes: metadataReadBytes,
            failedReadCount: failedReadCount
        )
        // 返回目标、缓存增量、删除集合和诊断指标。
        return TokenDiscoveryResult(
            targets: sortedTargets,
            changedCacheEntries: changedCacheEntries,
            removedCachePaths: removedCachePaths,
            metrics: metrics,
            uncertainTargetIDs: uncertainTargetIDs,
            hasUnattributedReadFailure: hasUnattributedReadFailure
        )
    }

    private static func defaultRoots() -> [URL] {
        let codexHome = defaultCodexHome()
        return [
            codexHome.appendingPathComponent("sessions", isDirectory: true),
            codexHome.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
    }

    static func defaultCodexHome() -> URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    private static func readSubagentMetadata(at url: URL) -> MetadataReadResult {
        do {
            // 打开失败属于可重试错误，不能持久化为负缓存。
            let handle = try FileHandle(forReadingFrom: url)
            // 无论读取和解析结果如何都关闭文件描述符。
            defer { try? handle.close() }
            // 空文件是成功的负结果，因此 nil 按空数据处理。
            let data = try handle.read(upToCount: 64 * 1024) ?? Data()
            // 成功读取后同时返回解析结果和实际字节数。
            return .success(
                metadata: parseSubagentMetadata(in: data),
                bytesRead: Int64(data.count)
            )
        } catch {
            // 读取错误留待下轮重试，并由调用方保留旧正向关系。
            return .failure
        }
    }

    private static func parseSubagentMetadata(in data: Data) -> SubagentMetadata? {
        // 只检查前 33 行，保持与旧发现逻辑一致的成本上限。
        for line in data.split(separator: 0x0A, maxSplits: 32) {
            // 快速字符串过滤避免对普通事件行执行 JSON 解析。
            guard line.range(of: Data(#""session_meta""#.utf8)) != nil,
                let object = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any],
                object["type"] as? String == "session_meta",
                let payload = object["payload"] as? [String: Any],
                let id = payload["id"] as? String,
                let source = payload["source"] as? [String: Any],
                let subagent = source["subagent"] as? [String: Any],
                let spawn = subagent["thread_spawn"] as? [String: Any],
                let parentID = spawn["parent_thread_id"] as? String
            else { continue }
            // 找到首个完整子代理元数据后立即结束前缀扫描。
            return SubagentMetadata(id: id, parentID: parentID)
        }
        // 成功读取但没有子代理元数据时形成可复用的负结果。
        return nil
    }

    @discardableResult
    private static func restoreCachedSubagent(
        _ entry: TokenDiscoveryCacheEntry?,
        url: URL,
        into subagents: inout [String: (parentID: String, url: URL)]
    ) -> String? {
        // 只有 ID 和父 ID 同时存在才是可用于归属的正向发现结果。
        guard let id = entry?.subagentID,
            let parentID = entry?.parentThreadID
        else { return nil }
        // 使用本轮枚举 URL，避免缓存路径表现差异影响后续文件读取。
        subagents[id] = (parentID, url)
        // 返回恢复的目标 ID，让失败分支可以把该关系标记为不确定。
        return id
    }

    private struct SubagentMetadata: Equatable, Sendable {
        // id 是子代理自身会话 ID。
        let id: String
        // parentID 是日志元数据声明的直接父会话 ID。
        let parentID: String
    }

    private enum MetadataReadResult {
        // 成功读取允许 metadata 为空，以表达可信负缓存。
        case success(metadata: SubagentMetadata?, bytesRead: Int64)
        // failure 表示文件应在下轮继续尝试读取。
        case failure
    }
}

enum QuotaCycleWindow {
    static func startTimestamp(window: CodexRateLimitWindow?) -> Int64? {
        guard let durationMins = window?.windowDurationMins,
            durationMins > 0,
            let resetsAt = window?.resetsAt
        else { return nil }

        let (durationSeconds, durationOverflow) = durationMins.multipliedReportingOverflow(by: 60)
        let (cycleStart, startOverflow) = resetsAt.subtractingReportingOverflow(durationSeconds)
        guard !durationOverflow, !startOverflow else { return nil }
        return cycleStart
    }

}

enum QuotaCycleTokenUsage {
    static func totalTokens(
        timedUsage: [ThreadTokenTimedUsage],
        coveredThreadIDs: Set<String>,
        knownThreadIDs: Set<String>,
        window: CodexRateLimitWindow?,
        now: Int64
    ) -> Int64? {
        guard let start = QuotaCycleWindow.startTimestamp(window: window) else { return nil }

        return timedUsage.lazy
            .filter {
                coveredThreadIDs.contains($0.threadID)
                    && knownThreadIDs.contains($0.threadID)
                    && $0.eventAt >= start
                    && $0.eventAt <= now
            }
            .reduce(0) { $0 + $1.usage.totalTokens }
    }

}

enum RolloutTokenScanner {
    static func scan(
        url: URL,
        fromOffset: Int64 = 0,
        baseline: TokenScanState = .empty,
        calendar: Calendar = .current,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> TokenScanResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard fromOffset >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        try handle.seek(toOffset: UInt64(fromOffset))

        var state = baseline
        var phase: ScanPhase = baseline.observedCheckpoint ? .active : .unknown
        var duplicateTokenCheckpointCount = 0
        var buffer = Data()
        var searchedByteCount = 0
        var offset = fromOffset

        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if isCancelled() { throw CancellationError() }
            // 追加新块后只从上轮尚未搜索的位置继续，避免超长单行被反复从头扫描。
            buffer.append(chunk)
            // 本轮完整行统一记录消费终点，最后只移动一次缓冲区前缀。
            var consumedEnd = buffer.startIndex
            // 已有尾行在上轮已确认没有换行，因此直接从新追加内容开始查找。
            var searchStart = buffer.index(
                buffer.startIndex,
                offsetBy: min(searchedByteCount, buffer.count)
            )
            while let newline = buffer[searchStart...].firstIndex(of: 0x0A) {
                // 超大块可能含有很多行，逐行响应取消，避免退出时仍长时间解析。
                if isCancelled() { throw CancellationError() }
                // 当前完整行从上一个消费终点开始，到换行符之前结束。
                let line = Data(buffer[consumedEnd..<newline])
                scan(
                    line: line,
                    state: &state,
                    phase: &phase,
                    duplicateTokenCheckpointCount: &duplicateTokenCheckpointCount,
                    calendar: calendar
                )
                // 下一行从换行符后开始，后续搜索不再回看已处理字节。
                consumedEnd = buffer.index(after: newline)
                searchStart = consumedEnd
            }
            if consumedEnd != buffer.startIndex {
                // 只提交以换行结尾的完整记录，保留末尾半行供下一次增量扫描。
                offset += Int64(buffer.distance(from: buffer.startIndex, to: consumedEnd))
                // 每个读取块最多移动一次前缀，避免逐行删除引发重复内存搬移。
                buffer.removeSubrange(buffer.startIndex..<consumedEnd)
            }
            // 剩余字节已全部确认无换行，下轮只需要检查新追加的字节。
            searchedByteCount = buffer.count
        }

        return TokenScanResult(
            offset: offset,
            state: state,
            duplicateTokenCheckpointCount: duplicateTokenCheckpointCount
        )
    }

    private static func scan(
        line: Data,
        state: inout TokenScanState,
        phase: inout ScanPhase,
        duplicateTokenCheckpointCount: inout Int,
        calendar: Calendar
    ) {
        updatePhase(line: line, phase: &phase)
        guard line.range(of: Data(#""token_count""#.utf8)) != nil,
            let event = try? JSONDecoder().decode(TokenEvent.self, from: line),
            event.type == "event_msg",
            event.payload.type == "token_count",
            let usage = event.payload.info?.totalTokenUsage,
            let timestamp = try? Date(event.timestamp, strategy: .iso8601)
        else { return }

        let timestampSeconds = Int64(timestamp.timeIntervalSince1970.rounded(.down))
        if phase.recordsUsage,
            state.observedCheckpoint,
            usage == state.maximum
        {
            // 完全相同的累计检查点没有新用量，显式去重并留下诊断计数。
            duplicateTokenCheckpointCount += 1
            state.latestEventTimestamp = max(
                state.latestEventTimestamp ?? timestampSeconds, timestampSeconds)
            return
        }

        let delta = usage.positiveDelta(from: state.maximum)
        if phase.recordsUsage, !delta.isZero {
            let day = Int64(calendar.startOfDay(for: timestamp).timeIntervalSince1970)
            state.dailyUsage[day] = (state.dailyUsage[day] ?? .zero) + delta
            state.timedUsage[timestampSeconds] =
                (state.timedUsage[timestampSeconds] ?? .zero) + delta
        }
        state.maximum = state.maximum.componentwiseMaximum(usage)
        state.latestEventTimestamp = max(
            state.latestEventTimestamp ?? timestampSeconds, timestampSeconds)
        state.observedCheckpoint = true
    }

    private static func updatePhase(line: Data, phase: inout ScanPhase) {
        switch phase {
        case .active:
            return
        case .unknown:
            guard line.range(of: Data(#""session_meta""#.utf8)) != nil else { return }
            guard line.range(of: Data(#""subagent""#.utf8)) != nil,
                let event = try? JSONDecoder().decode(SubagentSessionEvent.self, from: line),
                event.type == "session_meta",
                event.payload.source.subagent != nil
            else {
                phase = .active
                return
            }
            phase = .forkReplay(subagentID: event.payload.id)
        case .forkReplay(let subagentID):
            guard line.range(of: Data(#""task_started""#.utf8)) != nil,
                let event = try? JSONDecoder().decode(TaskStartedEvent.self, from: line),
                event.type == "event_msg",
                event.payload.type == "task_started",
                event.payload.turnID > subagentID
            else { return }
            phase = .active
        }
    }

    private enum ScanPhase {
        case unknown
        case forkReplay(subagentID: String)
        case active

        var recordsUsage: Bool {
            if case .forkReplay = self { return false }
            return true
        }
    }

    private struct SubagentSessionEvent: Decodable {
        let type: String
        let payload: Payload

        struct Payload: Decodable {
            let id: String
            let source: Source
        }

        struct Source: Decodable {
            let subagent: Subagent?
        }

        struct Subagent: Decodable {}
    }

    private struct TaskStartedEvent: Decodable {
        let type: String
        let payload: Payload

        struct Payload: Decodable {
            let type: String
            let turnID: String

            private enum CodingKeys: String, CodingKey {
                case type
                case turnID = "turn_id"
            }
        }
    }

    private struct TokenEvent: Decodable {
        let timestamp: String
        let type: String
        let payload: Payload

        struct Payload: Decodable {
            let type: String
            let info: Info?
        }

        struct Info: Decodable {
            let totalTokenUsage: TokenUsageBreakdown

            private enum CodingKeys: String, CodingKey {
                case totalTokenUsage = "total_token_usage"
            }
        }
    }
}

enum TokenCacheDecision: Equatable, Sendable {
    case reuse
    case append
    case rebuild

    static func decide(
        rolloutPath: String,
        fileSize: Int64,
        modificationTime: Int64,
        parserVersion: Int64,
        cachedRolloutPath: String,
        cachedFileSize: Int64,
        cachedModificationTime: Int64,
        cachedParserVersion: Int64
    ) -> Self {
        guard rolloutPath == cachedRolloutPath,
            parserVersion == cachedParserVersion,
            fileSize >= cachedFileSize,
            modificationTime >= cachedModificationTime
        else { return .rebuild }

        if fileSize == cachedFileSize {
            return modificationTime == cachedModificationTime ? .reuse : .rebuild
        }
        return .append
    }
}

enum TokenReconciliationPolicy {
    // 每天最多重新核对一次同一日志，在持续纠错和后台磁盘读取之间保持平衡。
    static let minimumInterval: Int64 = 24 * 60 * 60

    static func isDue(lastReconciledAt: Int64?, now: Int64) -> Bool {
        guard let lastReconciledAt else { return true }
        let (nextReconciliationAt, overflow) = lastReconciledAt.addingReportingOverflow(
            minimumInterval
        )
        return !overflow && now >= nextReconciliationAt
    }
}
