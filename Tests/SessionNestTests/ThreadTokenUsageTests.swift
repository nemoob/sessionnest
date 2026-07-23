import Foundation
import Testing

@testable import SessionNest

@Suite("ThreadTokenUsageTests")
struct ThreadTokenUsageTests {
    @Test func subagentScanExcludesForkedParentHistory() throws {
        let lines = [
            #"{"timestamp":"2026-07-20T06:12:34.472Z","type":"session_meta","payload":{"id":"019f7e27-a0fa-7f33-a653-c4318fa5dd48","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}}}"#,
            #"{"timestamp":"2026-07-20T06:12:34.472Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":400,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":500}}}}"#,
            #"{"timestamp":"2026-07-20T06:12:34.805Z","type":"event_msg","payload":{"type":"task_started","turn_id":"019f7e26-8eb1-74f1-a607-c0c7ca678fd3"}}"#,
            #"{"timestamp":"2026-07-20T06:12:34.805Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":520,"cached_input_tokens":410,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":520}}}}"#,
            #"{"timestamp":"2026-07-20T06:12:34.855Z","type":"event_msg","payload":{"type":"task_started","turn_id":"019f7e27-a3a5-7143-bf0a-055beb48d8f9"}}"#,
            #"{"timestamp":"2026-07-20T06:13:00.996Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":580,"cached_input_tokens":450,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":580}}}}"#,
        ]
        let url = try fixture(data: Data((lines.joined(separator: "\n") + "\n").utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try RolloutTokenScanner.scan(url: url, calendar: localCalendar)

        #expect(result.maximum == usage(580, 450, 0, 0, 580))
        #expect(result.dailyUsage.values.reduce(.zero, +) == usage(60, 40, 0, 0, 60))
    }

    @Test func discoversSubagentRolloutAndAttributesItToVisibleParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let parentURL = root.appendingPathComponent("parent.jsonl")
        let childURL = root.appendingPathComponent("child.jsonl")
        try Data().write(to: parentURL)
        try Data(
            #"{"timestamp":"2026-07-20T00:00:00Z","type":"session_meta","payload":{"id":"child","cwd":"/work/project","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent","depth":1}}}}}"#
                .utf8
        ).write(to: childURL)
        let parent = CodexThread(
            id: "parent",
            name: "Parent",
            preview: "",
            cwd: "/work/project",
            createdAt: 1,
            updatedAt: 2,
            recencyAt: nil,
            gitInfo: nil,
            path: parentURL.path
        )

        let targets = LocalTokenScanTargetDiscovery.discover(
            threads: [parent],
            roots: [root]
        )

        #expect(targets.map(\.id).sorted() == ["child", "parent"])
        #expect(targets.first { $0.id == "child" }?.attributionThreadID == "parent")
        #expect(
            targets.first { $0.id == "child" }?.url.resolvingSymlinksInPath()
                == childURL.resolvingSymlinksInPath()
        )
    }

    @Test func indexedDiscoveryReusesPositiveAndNegativeMetadataWithoutReadingFilesAgain() throws {
        // 创建独立根目录，避免用户真实 Codex 日志影响缓存命中数量。
        let root = try discoveryRoot()
        // 测试完成后清理日志和目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 父会话空日志同时验证成功读取后的负缓存。
        let parentURL = root.appendingPathComponent("parent.jsonl")
        // 普通大日志验证发现读取始终限制在前 64 KiB。
        let ordinaryURL = root.appendingPathComponent("ordinary.jsonl")
        // 子代理日志提供可复用的正向父子元数据。
        let childURL = root.appendingPathComponent("child.jsonl")
        // 写入空父日志。
        try Data().write(to: parentURL)
        // 写入超过前缀上限的普通日志。
        try Data(repeating: 0x61, count: 80 * 1024).write(to: ordinaryURL)
        // 写入完整子代理元数据。
        try subagentData(id: "child", parentID: "parent").write(to: childURL)
        // 只把父会话暴露给 SessionNest，子代理必须由目录发现补齐。
        let parent = discoveryThread(id: "parent", url: parentURL)

        // 首轮没有缓存，因此三个 JSONL 都必须读取一次。
        let first = LocalTokenScanTargetDiscovery.discoverIndexed(
            threads: [parent],
            cacheEntries: [:],
            parserVersion: 1,
            roots: [root]
        )
        // 把首轮增量模拟为持久层已保存的完整缓存。
        let cache = applying(first, to: [:])
        // 第二轮输入完全一致，应只枚举属性而不再打开日志正文。
        let second = LocalTokenScanTargetDiscovery.discoverIndexed(
            threads: [parent],
            cacheEntries: cache,
            parserVersion: 1,
            roots: [root]
        )

        // 首轮看到了三个候选文件并实际读取三次。
        #expect(first.metrics.enumeratedJSONLCount == 3)
        #expect(first.metrics.metadataReadFileCount == 3)
        // 大日志最多贡献 64 KiB，另加子代理元数据的实际长度。
        #expect(
            first.metrics.metadataReadBytes
                == Int64(64 * 1024 + subagentData(id: "child", parentID: "parent").count))
        // 父日志和普通日志都应保存 ID 为空的可信负缓存。
        #expect(cache[parentURL.standardizedFileURL.path]?.subagentID == nil)
        #expect(cache[ordinaryURL.standardizedFileURL.path]?.subagentID == nil)
        // 第二轮三个文件全部命中，内容读取和缓存更新都必须为零。
        #expect(second.metrics.cacheHitCount == 3)
        #expect(second.metrics.metadataReadFileCount == 0)
        #expect(second.metrics.metadataReadBytes == 0)
        #expect(second.changedCacheEntries.isEmpty)
        // 正缓存复用后仍需返回相同父子目标。
        #expect(second.targets.map(\.id).sorted() == ["child", "parent"])
        #expect(second.targets.first { $0.id == "child" }?.attributionThreadID == "parent")
    }

    @Test func indexedDiscoveryReadsOnlyNewAndChangedFilesAndRemovesDeletedPaths() throws {
        // 创建只包含测试日志的发现根目录。
        let root = try discoveryRoot()
        // 测试后移除全部临时内容。
        defer { try? FileManager.default.removeItem(at: root) }
        // 父日志保证发现逻辑会遍历该根目录。
        let parentURL = root.appendingPathComponent("parent.jsonl")
        // 已有子代理用于验证修改文件的单独重读。
        let childURL = root.appendingPathComponent("child.jsonl")
        // 后续新增并删除的子代理用于验证增量和清理集合。
        let addedURL = root.appendingPathComponent("added.jsonl")
        // 写入初始父日志。
        try Data().write(to: parentURL)
        // 写入初始子代理关系。
        try subagentData(id: "child", parentID: "parent").write(to: childURL)
        // 构造唯一可见父会话。
        let parent = discoveryThread(id: "parent", url: parentURL)

        // 首轮建立父日志和子代理日志缓存。
        let first = LocalTokenScanTargetDiscovery.discoverIndexed(
            threads: [parent],
            cacheEntries: [:],
            parserVersion: 1,
            roots: [root]
        )
        // 保存首轮缓存作为第二轮输入。
        let firstCache = applying(first, to: [:])
        // 新文件是第二轮唯一发生变化的路径。
        try subagentData(id: "added", parentID: "parent").write(to: addedURL)
        // 第二轮应复用两个旧文件，只读取新增日志。
        let second = LocalTokenScanTargetDiscovery.discoverIndexed(
            threads: [parent],
            cacheEntries: firstCache,
            parserVersion: 1,
            roots: [root]
        )
        // 合并第二轮缓存，为删除判断提供完整历史集合。
        let secondCache = applying(second, to: firstCache)

        // 新增文件只触发一次前缀读取。
        #expect(second.metrics.cacheHitCount == 2)
        #expect(second.metrics.metadataReadFileCount == 1)
        #expect(
            second.changedCacheEntries.map(\.rolloutPath) == [addedURL.standardizedFileURL.path])
        #expect(second.removedCachePaths.isEmpty)

        // 给已有子代理追加内容，确保 size 变化而不依赖文件系统 mtime 精度。
        let appendHandle = try FileHandle(forWritingTo: childURL)
        // 写入前定位到文件末尾。
        try appendHandle.seekToEnd()
        // 追加一个换行使该文件成为唯一修改项。
        try appendHandle.write(contentsOf: Data("\n".utf8))
        // 关闭句柄，让下一轮取得稳定文件大小。
        try appendHandle.close()
        // 删除上一轮新增文件，验证缓存清理只返回消失路径。
        try FileManager.default.removeItem(at: addedURL)
        // 第三轮应只读取修改后的 child，并报告 added 已删除。
        let third = LocalTokenScanTargetDiscovery.discoverIndexed(
            threads: [parent],
            cacheEntries: secondCache,
            parserVersion: 1,
            roots: [root]
        )

        // 父日志命中、child 重读、deleted 不再枚举。
        #expect(third.metrics.cacheHitCount == 1)
        #expect(third.metrics.metadataReadFileCount == 1)
        #expect(third.changedCacheEntries.map(\.rolloutPath) == [childURL.standardizedFileURL.path])
        #expect(third.removedCachePaths == [addedURL.standardizedFileURL.path])
        // 修改后重新解析的子代理仍正确归属父会话。
        #expect(third.targets.first { $0.id == "child" }?.attributionThreadID == "parent")
    }

    @Test func indexedDiscoveryRestoresMultilevelAttributionEntirelyFromCache() throws {
        // 创建多级子代理专用根目录。
        let root = try discoveryRoot()
        // 测试结束后清理文件。
        defer { try? FileManager.default.removeItem(at: root) }
        // 父日志对应唯一可见会话。
        let parentURL = root.appendingPathComponent("parent.jsonl")
        // 中间层子代理指向可见父会话。
        let middleURL = root.appendingPathComponent("middle.jsonl")
        // 叶子子代理只指向中间层。
        let leafURL = root.appendingPathComponent("leaf.jsonl")
        // 写入空父日志。
        try Data().write(to: parentURL)
        // 写入中间父子关系。
        try subagentData(id: "middle", parentID: "parent").write(to: middleURL)
        // 写入叶子父子关系。
        try subagentData(id: "leaf", parentID: "middle").write(to: leafURL)
        // 可见列表只包含最上层父会话。
        let parent = discoveryThread(id: "parent", url: parentURL)

        // 首轮读取三个文件并建立完整父链缓存。
        let first = LocalTokenScanTargetDiscovery.discoverIndexed(
            threads: [parent],
            cacheEntries: [:],
            parserVersion: 1,
            roots: [root]
        )
        // 持久化模拟后再次发现，父链必须完全来自缓存。
        let second = LocalTokenScanTargetDiscovery.discoverIndexed(
            threads: [parent],
            cacheEntries: applying(first, to: [:]),
            parserVersion: 1,
            roots: [root]
        )

        // 暖缓存不能再次读取任一日志前缀。
        #expect(second.metrics.cacheHitCount == 3)
        #expect(second.metrics.metadataReadFileCount == 0)
        // 中间层和叶子层最终都归属顶层可见父会话。
        #expect(second.targets.first { $0.id == "middle" }?.attributionThreadID == "parent")
        #expect(second.targets.first { $0.id == "leaf" }?.attributionThreadID == "parent")
    }

    @Test func indexedDiscoveryInvalidatesEveryEntryWhenParserVersionChanges() throws {
        // 创建版本失效测试根目录。
        let root = try discoveryRoot()
        // 测试完成后清理。
        defer { try? FileManager.default.removeItem(at: root) }
        // 父日志和子日志共同验证正负缓存均按版本失效。
        let parentURL = root.appendingPathComponent("parent.jsonl")
        let childURL = root.appendingPathComponent("child.jsonl")
        // 写入可信负缓存来源。
        try Data().write(to: parentURL)
        // 写入可信正缓存来源。
        try subagentData(id: "child", parentID: "parent").write(to: childURL)
        // 创建可见父会话。
        let parent = discoveryThread(id: "parent", url: parentURL)
        // 第一版解析器建立缓存。
        let first = LocalTokenScanTargetDiscovery.discoverIndexed(
            threads: [parent],
            cacheEntries: [:],
            parserVersion: 1,
            roots: [root]
        )
        // 第二版解析器必须忽略全部旧版本条目。
        let second = LocalTokenScanTargetDiscovery.discoverIndexed(
            threads: [parent],
            cacheEntries: applying(first, to: [:]),
            parserVersion: 2,
            roots: [root]
        )

        // 版本变化后没有缓存命中，两个文件都重新读取。
        #expect(second.metrics.cacheHitCount == 0)
        #expect(second.metrics.metadataReadFileCount == 2)
        #expect(second.changedCacheEntries.count == 2)
        #expect(second.changedCacheEntries.allSatisfy { $0.parserVersion == 2 })
    }

    @Test func indexedDiscoveryDoesNotWriteNegativeCacheOnFailureAndKeepsKnownChild() throws {
        // 创建包含故障 JSONL 候选项的根目录。
        let root = try discoveryRoot()
        // 测试完成后移除目录。
        defer { try? FileManager.default.removeItem(at: root) }
        // 正常父日志使根目录进入发现范围。
        let parentURL = root.appendingPathComponent("parent.jsonl")
        // 用 .jsonl 目录稳定模拟无法作为普通日志读取的候选项。
        let failedURL = root.appendingPathComponent("failed.jsonl", isDirectory: true)
        // 写入空父日志。
        try Data().write(to: parentURL)
        // 创建非普通文件候选项。
        try FileManager.default.createDirectory(at: failedURL, withIntermediateDirectories: true)
        // 可见父会话用于解析旧缓存中的子代理归属。
        let parent = discoveryThread(id: "parent", url: parentURL)
        // 旧正缓存让失败路径仍能保守恢复 child 目标。
        let failedEntry = TokenDiscoveryCacheEntry(
            rolloutPath: failedURL.standardizedFileURL.path,
            fileSize: 1,
            fileModificationTimeNS: 1,
            subagentID: "child",
            parentThreadID: "parent",
            parserVersion: 1
        )
        // 执行发现时故障路径不能被覆盖为负缓存。
        let result = LocalTokenScanTargetDiscovery.discoverIndexed(
            threads: [parent],
            cacheEntries: [failedEntry.rolloutPath: failedEntry],
            parserVersion: 1,
            roots: [root]
        )

        // 非普通 JSONL 被明确计入失败。
        #expect(result.metrics.failedReadCount == 1)
        // 故障路径不能出现在成功缓存更新中。
        #expect(!result.changedCacheEntries.contains { $0.rolloutPath == failedEntry.rolloutPath })
        // 本轮仍看到了该路径，因此也不能把它误判为已删除。
        #expect(!result.removedCachePaths.contains(failedEntry.rolloutPath))
        // 已知正关系被保留，使后续 Token 扫描可以将 child 标记失败。
        #expect(result.targets.first { $0.id == "child" }?.attributionThreadID == "parent")
        // 旧关系只作占位，本轮必须排除出可信覆盖直到前缀重新读取成功。
        #expect(result.uncertainTargetIDs == ["child"])
    }

    @Test func scanStopsWhenCancellationIsRequested() throws {
        let file = try fixture(data: Data("ignored\n".utf8))
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(throws: CancellationError.self) {
            try RolloutTokenScanner.scan(url: file, isCancelled: { true })
        }
    }

    @Test func scansCompleteTokenCheckpoints() throws {
        let calendar = localCalendar
        let completeLines = [
            #"{"timestamp":"2026-07-13T15:59:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20,"reasoning_output_tokens":10,"total_tokens":120}}}}"#,
            #"{"timestamp":"2026-07-13T15:59:30.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20,"reasoning_output_tokens":10,"total_tokens":120}}}}"#,
            #"{"timestamp":"2026-07-13T16:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":90,"output_tokens":30,"total_tokens":180}}}}"#,
            #"{"timestamp":"2026-07-13T16:00:30.000Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#,
            #"{"timestamp":"2026-07-13T16:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160,"cached_input_tokens":70,"output_tokens":40,"reasoning_output_tokens":30,"total_tokens":200}}}}"#,
            #"{"timestamp":"2026-07-13T16:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":60,"output_tokens":35,"reasoning_output_tokens":25,"total_tokens":190}}}}"#,
        ]
        let completeData = Data((completeLines.joined(separator: "\n") + "\n").utf8)
        let unfinishedLine =
            #"{"timestamp":"2026-07-13T16:03:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":999,"cached_input_tokens":999,"output_tokens":999,"reasoning_output_tokens":999,"total_tokens":999}}}}"#
        let url = try fixture(data: completeData + Data(unfinishedLine.utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try RolloutTokenScanner.scan(
            url: url,
            fromOffset: 0,
            baseline: .empty,
            calendar: calendar
        )

        let offset: Int64 = result.offset
        let dailyUsage: [Int64: TokenUsageBreakdown] = result.dailyUsage
        let latestEventTimestamp: Int64? = result.latestEventTimestamp

        #expect(offset == Int64(completeData.count))
        #expect(result.maximum == usage(160, 80, 40, 30, 200))
        #expect(latestEventTimestamp == unixSeconds("2026-07-13T16:02:00.000Z"))
        #expect(result.observedCheckpoint)

        let firstDay = dayStart("2026-07-13T15:59:00.000Z", calendar: calendar)
        let secondDay = dayStart("2026-07-13T16:01:00.000Z", calendar: calendar)
        #expect(
            dailyUsage == [
                firstDay: usage(100, 80, 20, 10, 120),
                secondDay: usage(60, 0, 20, 20, 80),
            ])
    }

    @Test func preservesSecondLevelDeltasAlongsideDailyTotals() throws {
        let lines = [
            #"{"timestamp":"2026-07-18T03:24:51.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20,"reasoning_output_tokens":10,"total_tokens":120}}}}"#,
            #"{"timestamp":"2026-07-18T03:24:52.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":130,"cached_input_tokens":90,"output_tokens":30,"reasoning_output_tokens":15,"total_tokens":160}}}}"#,
            #"{"timestamp":"2026-07-18T03:24:52.900Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":100,"output_tokens":40,"reasoning_output_tokens":20,"total_tokens":190}}}}"#,
        ]
        let url = try fixture(data: Data((lines.joined(separator: "\n") + "\n").utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try RolloutTokenScanner.scan(url: url, calendar: localCalendar)
        let beforeReset = unixSeconds("2026-07-18T03:24:51.000Z")
        let resetSecond = unixSeconds("2026-07-18T03:24:52.000Z")

        #expect(
            result.timedUsage == [
                beforeReset: usage(100, 80, 20, 10, 120),
                resetSecond: usage(50, 20, 20, 10, 70),
            ])
        #expect(result.dailyUsage.values.reduce(.zero, +) == usage(150, 100, 40, 20, 190))
    }

    @Test func resumesFromCommittedOffsetAndBaseline() throws {
        let firstLine =
            #"{"timestamp":"2026-07-13T15:59:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":5,"output_tokens":2,"reasoning_output_tokens":1,"total_tokens":12}}}}"#
            + "\n"
        let url = try fixture(data: Data(firstLine.utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try RolloutTokenScanner.scan(url: url, calendar: localCalendar)

        let secondLine =
            #"{"timestamp":"2026-07-13T16:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":15,"cached_input_tokens":8,"output_tokens":4,"reasoning_output_tokens":1,"total_tokens":19}}}}"#
            + "\n"
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(secondLine.utf8))
        try handle.close()

        let resumed = try RolloutTokenScanner.scan(
            url: url,
            fromOffset: first.offset,
            baseline: first.state,
            calendar: localCalendar
        )

        #expect(resumed.offset == first.offset + Int64(secondLine.utf8.count))
        #expect(resumed.maximum == usage(15, 8, 4, 1, 19))
        #expect(resumed.dailyUsage.values.reduce(.zero, +) == usage(15, 8, 4, 1, 19))
    }

    @Test func reboundBelowHistoricalMaximumAddsNoUsage() throws {
        let lines = [
            #"{"timestamp":"2026-07-13T15:59:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":100}}}}"#,
            #"{"timestamp":"2026-07-13T16:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":50}}}}"#,
            #"{"timestamp":"2026-07-13T16:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":80}}}}"#,
        ]
        let url = try fixture(data: Data((lines.joined(separator: "\n") + "\n").utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try RolloutTokenScanner.scan(url: url, calendar: localCalendar)

        #expect(result.maximum == usage(100, 0, 0, 0, 100))
        #expect(result.dailyUsage.values.reduce(.zero, +) == usage(100, 0, 0, 0, 100))
    }

    @Test func persistedMaximumPreventsIncrementalDoubleCount() throws {
        let previousTimestamp = unixSeconds("2026-07-13T15:59:00Z")
        let day = dayStart("2026-07-13T15:59:00Z", calendar: localCalendar)
        let baseline = TokenScanState(
            maximum: usage(100, 0, 0, 0, 100),
            dailyUsage: [day: usage(100, 0, 0, 0, 100)],
            latestEventTimestamp: previousTimestamp,
            observedCheckpoint: true
        )
        let line =
            #"{"timestamp":"2026-07-13T16:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":80}}}}"#
            + "\n"
        let url = try fixture(data: Data(line.utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try RolloutTokenScanner.scan(
            url: url,
            fromOffset: 0,
            baseline: baseline,
            calendar: localCalendar
        )

        #expect(result.maximum == usage(100, 0, 0, 0, 100))
        #expect(result.dailyUsage == baseline.dailyUsage)
    }

    @Test func ignoresMalformedCompleteLine() throws {
        let malformed = #"{"type":"event_msg","payload":{"type":"token_count""# + "\n"
        let valid =
            #"{"timestamp":"2026-07-13T16:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":5,"output_tokens":2,"reasoning_output_tokens":1,"total_tokens":12}}}}"#
            + "\n"
        let data = Data((malformed + valid).utf8)
        let url = try fixture(data: data)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try RolloutTokenScanner.scan(url: url, calendar: localCalendar)

        #expect(result.offset == Int64(data.count))
        #expect(result.maximum == usage(10, 5, 2, 1, 12))
    }

    @Test func decidesWhetherToReuseAppendOrRebuildCache() {
        let earlierNanoseconds: Int64 = 100
        let laterNanoseconds: Int64 = 200

        #expect(decision(fileSize: 100, modificationTime: earlierNanoseconds) == .reuse)
        #expect(decision(fileSize: 101, modificationTime: laterNanoseconds) == .append)
        #expect(decision(fileSize: 99, modificationTime: laterNanoseconds) == .rebuild)
        #expect(
            decision(rolloutPath: "/new", fileSize: 100, modificationTime: earlierNanoseconds)
                == .rebuild)
        #expect(
            decision(fileSize: 100, modificationTime: earlierNanoseconds, parserVersion: 2)
                == .rebuild)
        #expect(decision(fileSize: 100, modificationTime: laterNanoseconds) == .rebuild)
    }

    @Test func quotaCycleStartTimestampPreservesNonMidnightBoundary() {
        let window = CodexRateLimitWindow(
            usedPercent: 6,
            windowDurationMins: 10_080,
            resetsAt: unixSeconds("2026-07-22T14:30:00Z")
        )

        let startTimestamp = QuotaCycleWindow.startTimestamp(window: window)

        #expect(startTimestamp == unixSeconds("2026-07-15T14:30:00Z"))
    }

    @Test func quotaCycleTokenUsageFiltersExactBoundaryAndCoveredThreads() {
        let now = unixSeconds("2026-07-15T14:31:00Z")
        let window = CodexRateLimitWindow(
            usedPercent: 40,
            windowDurationMins: 10_080,
            resetsAt: unixSeconds("2026-07-22T14:30:00Z")
        )
        let timedUsage = [
            timed("covered", "2026-07-15T14:29:59Z", 10),
            timed("covered", "2026-07-15T14:30:00Z", 20),
            timed("covered", "2026-07-15T14:31:00Z", 30),
            timed("covered", "2026-07-15T14:31:01Z", 40),
            timed("uncovered", "2026-07-15T14:30:30Z", 100),
            timed("unknown", "2026-07-15T14:30:30Z", 1_000),
        ]

        let total = QuotaCycleTokenUsage.totalTokens(
            timedUsage: timedUsage,
            coveredThreadIDs: ["covered", "unknown"],
            knownThreadIDs: ["covered", "uncovered"],
            window: window,
            now: now
        )

        #expect(total == 50)
    }

    @Test func quotaCycleTokenUsageRequiresCompleteWindowMetadata() {
        let missingReset = CodexRateLimitWindow(
            usedPercent: 40,
            windowDurationMins: 10_080,
            resetsAt: nil
        )

        let total = QuotaCycleTokenUsage.totalTokens(
            timedUsage: [],
            coveredThreadIDs: [],
            knownThreadIDs: [],
            window: missingReset,
            now: 1_000
        )

        #expect(total == nil)
    }

    private var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
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

    private func timestamp(_ value: String) -> Date {
        try! Date(value, strategy: .iso8601)
    }

    private func unixSeconds(_ value: String) -> Int64 {
        Int64(timestamp(value).timeIntervalSince1970)
    }

    private func dayStart(_ value: String, calendar: Calendar) -> Int64 {
        Int64(calendar.startOfDay(for: timestamp(value)).timeIntervalSince1970)
    }

    private func timed(
        _ threadID: String,
        _ date: String,
        _ totalTokens: Int64
    ) -> ThreadTokenTimedUsage {
        ThreadTokenTimedUsage(
            threadID: threadID,
            eventAt: unixSeconds(date),
            usage: usage(0, 0, 0, 0, totalTokens)
        )
    }

    private func fixture(data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jsonl")
        try data.write(to: url)
        return url
    }

    private func discoveryRoot() throws -> URL {
        // 每个测试使用独立 UUID 根目录，避免并发测试互相污染。
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        // 创建完整目录层级供日志写入。
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 返回可直接传给发现器的根 URL。
        return root
    }

    private func discoveryThread(id: String, url: URL) -> CodexThread {
        // 生成只包含发现逻辑所需字段的可见会话。
        CodexThread(
            id: id,
            name: id,
            preview: "",
            cwd: url.deletingLastPathComponent().path,
            createdAt: 1,
            updatedAt: 2,
            recencyAt: nil,
            gitInfo: nil,
            path: url.path
        )
    }

    private func subagentData(id: String, parentID: String) -> Data {
        // 构造与 Codex rollout 一致的最小子代理 session_meta 行。
        let line =
            #"{"timestamp":"2026-07-20T00:00:00Z","type":"session_meta","payload":{"id":"\#(id)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\#(parentID)"}}}}}"#
        // 返回 UTF-8 数据，便于测试直接写入 JSONL。
        return Data(line.utf8)
    }

    private func applying(
        _ result: TokenDiscoveryResult,
        to cache: [String: TokenDiscoveryCacheEntry]
    ) -> [String: TokenDiscoveryCacheEntry] {
        // 从上一轮缓存副本开始应用增量。
        var updated = cache
        // 先移除已经从完整枚举根目录消失的路径。
        for path in result.removedCachePaths {
            updated.removeValue(forKey: path)
        }
        // 再写入新增或变化项，使最新属性覆盖旧值。
        for entry in result.changedCacheEntries {
            updated[entry.rolloutPath] = entry
        }
        // 返回模拟持久化后的完整缓存。
        return updated
    }

    private func decision(
        rolloutPath: String = "/rollout",
        fileSize: Int64,
        modificationTime: Int64,
        parserVersion: Int64 = 1
    ) -> TokenCacheDecision {
        TokenCacheDecision.decide(
            rolloutPath: rolloutPath,
            fileSize: fileSize,
            modificationTime: modificationTime,
            parserVersion: parserVersion,
            cachedRolloutPath: "/rollout",
            cachedFileSize: 100,
            cachedModificationTime: 100,
            cachedParserVersion: 1
        )
    }
}
