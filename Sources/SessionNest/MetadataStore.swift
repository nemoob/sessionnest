import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum MetadataStoreError: Error, Equatable, Sendable {
    case sqlite(String)
}

struct ThreadTokenCache: Equatable, Sendable {
    let threadID: String
    let rolloutPath: String
    let fileSize: Int64
    let fileModificationTimeNS: Int64
    let scannedOffset: Int64
    let maximum: TokenUsageBreakdown
    let latestEventTimestamp: Int64?
    let parserVersion: Int64
    let lastReconciledAt: Int64?
}

struct ThreadTokenDailyUsage: Codable, Equatable, Sendable {
    let threadID: String
    let dayStart: Int64
    let usage: TokenUsageBreakdown
}

struct ThreadTokenTimedUsage: Equatable, Sendable {
    let threadID: String
    let eventAt: Int64
    let usage: TokenUsageBreakdown
}

actor MetadataStore {
    static let schemaVersion: Int32 = 1

    nonisolated(unsafe) private let database: OpaquePointer

    init(databaseURL: URL) throws {
        let databaseExisted = FileManager.default.fileExists(atPath: databaseURL.path)
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var database: OpaquePointer?
        let result = sqlite3_open(databaseURL.path, &database)
        guard result == SQLITE_OK, let database else {
            let message =
                database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            if let database {
                sqlite3_close(database)
            }
            throw MetadataStoreError.sqlite(message)
        }

        do {
            let previousSchemaVersion = try Self.schemaVersion(in: database)
            if databaseExisted, previousSchemaVersion < Self.schemaVersion {
                _ = try ApplicationSupportMigration.prepareDatabase(
                    destinationURL: Self.schemaMigrationBackupURL(for: databaseURL),
                    legacyURL: databaseURL
                )
            }
            try Self.createSchema(
                in: database,
                previousSchemaVersion: previousSchemaVersion
            )
        } catch {
            sqlite3_close(database)
            throw error
        }
        self.database = database
    }

    static func schemaMigrationBackupURL(for databaseURL: URL) -> URL {
        databaseURL.appendingPathExtension("pre-v\(schemaVersion).backup")
    }

    deinit {
        sqlite3_close(database)
    }

    func loadMetadata() throws -> [String: ThreadMetadata] {
        let statement = try prepare(
            "SELECT thread_id, is_favorite, collection_id FROM thread_meta"
        )
        defer { sqlite3_finalize(statement) }

        var metadata: [String: ThreadMetadata] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let threadID = text(at: 0, in: statement)
                metadata[threadID] = ThreadMetadata(
                    threadID: threadID,
                    isFavorite: sqlite3_column_int(statement, 1) != 0,
                    collectionID: optionalText(at: 2, in: statement)
                )
            case SQLITE_DONE:
                return metadata
            default:
                throw sqliteError()
            }
        }
    }

    func loadCollections() throws -> [SessionCollection] {
        let statement = try prepare(
            "SELECT id, name, sort_order FROM collections ORDER BY sort_order, id"
        )
        defer { sqlite3_finalize(statement) }

        var collections: [SessionCollection] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                collections.append(
                    SessionCollection(
                        id: text(at: 0, in: statement),
                        name: text(at: 1, in: statement),
                        sortOrder: Int(sqlite3_column_int64(statement, 2))
                    )
                )
            case SQLITE_DONE:
                return collections
            default:
                throw sqliteError()
            }
        }
    }

    func loadSavedViews() throws -> [SavedSessionView] {
        let statement = try prepare(
            """
            SELECT id, name, selection_kind, selection_value, query, time_filter,
                   session_sort_order, sort_order
            FROM saved_views
            ORDER BY sort_order, id
            """
        )
        defer { sqlite3_finalize(statement) }

        var savedViews: [SavedSessionView] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard
                    let selection = Self.savedViewSelection(
                        kind: text(at: 2, in: statement),
                        value: optionalText(at: 3, in: statement)
                    ),
                    let timeFilter = SessionTimeFilter(
                        statisticsPersistenceScope: text(at: 5, in: statement)
                    ),
                    let sortOrder = Self.savedViewSortOrder(text(at: 6, in: statement))
                else { continue }
                savedViews.append(
                    SavedSessionView(
                        id: text(at: 0, in: statement),
                        name: text(at: 1, in: statement),
                        selection: selection,
                        query: text(at: 4, in: statement),
                        timeFilter: timeFilter,
                        sortOrder: sortOrder,
                        position: Int(sqlite3_column_int64(statement, 7))
                    )
                )
            case SQLITE_DONE:
                return savedViews
            default:
                throw sqliteError()
            }
        }
    }

    func loadTags() throws -> [SessionTag] {
        let statement = try prepare(
            "SELECT id, name, color_hex, sort_order FROM tags ORDER BY sort_order, id"
        )
        defer { sqlite3_finalize(statement) }

        var tags: [SessionTag] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                tags.append(
                    SessionTag(
                        id: text(at: 0, in: statement),
                        name: text(at: 1, in: statement),
                        colorHex: text(at: 2, in: statement),
                        sortOrder: Int(sqlite3_column_int64(statement, 3))
                    )
                )
            case SQLITE_DONE:
                return tags
            default:
                throw sqliteError()
            }
        }
    }

    func loadThreadTags() throws -> [String: Set<String>] {
        let statement = try prepare("SELECT thread_id, tag_id FROM thread_tags")
        defer { sqlite3_finalize(statement) }

        var threadTags: [String: Set<String>] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                threadTags[text(at: 0, in: statement), default: []]
                    .insert(text(at: 1, in: statement))
            case SQLITE_DONE:
                return threadTags
            default:
                throw sqliteError()
            }
        }
    }

    func loadThreadProjects() throws -> [String: ThreadProjectCache] {
        let statement = try prepare(
            """
            SELECT thread_id, project_path, analyzed_updated_at,
                   resolution_kind, classifier_version
            FROM thread_projects
            """
        )
        defer { sqlite3_finalize(statement) }

        var projects: [String: ThreadProjectCache] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let threadID = text(at: 0, in: statement)
                let projectPath = optionalText(at: 1, in: statement)
                guard
                    let resolution = Self.projectResolution(
                        kind: text(at: 3, in: statement),
                        path: projectPath
                    )
                else { continue }
                projects[threadID] = ThreadProjectCache(
                    threadID: threadID,
                    resolution: resolution,
                    analyzedUpdatedAt: sqlite3_column_int64(statement, 2),
                    classifierVersion: sqlite3_column_int64(statement, 4)
                )
            case SQLITE_DONE:
                return projects
            default:
                throw sqliteError()
            }
        }
    }

    func loadThreadTokenCache() throws -> [String: ThreadTokenCache] {
        let statement = try prepare(
            """
            SELECT thread_id, rollout_path, file_size, file_mtime_ns, scanned_offset,
                   input_tokens, cached_input_tokens, output_tokens,
                   reasoning_output_tokens, total_tokens, last_event_at, parser_version,
                   last_reconciled_at
            FROM thread_token_usage
            """
        )
        defer { sqlite3_finalize(statement) }

        var cache: [String: ThreadTokenCache] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let threadID = text(at: 0, in: statement)
                cache[threadID] = ThreadTokenCache(
                    threadID: threadID,
                    rolloutPath: text(at: 1, in: statement),
                    fileSize: sqlite3_column_int64(statement, 2),
                    fileModificationTimeNS: sqlite3_column_int64(statement, 3),
                    scannedOffset: sqlite3_column_int64(statement, 4),
                    maximum: TokenUsageBreakdown(
                        inputTokens: sqlite3_column_int64(statement, 5),
                        cachedInputTokens: sqlite3_column_int64(statement, 6),
                        outputTokens: sqlite3_column_int64(statement, 7),
                        reasoningOutputTokens: sqlite3_column_int64(statement, 8),
                        totalTokens: sqlite3_column_int64(statement, 9)
                    ),
                    latestEventTimestamp: sqlite3_column_type(statement, 10) == SQLITE_NULL
                        ? nil
                        : sqlite3_column_int64(statement, 10),
                    parserVersion: sqlite3_column_int64(statement, 11),
                    lastReconciledAt: sqlite3_column_type(statement, 12) == SQLITE_NULL
                        ? nil
                        : sqlite3_column_int64(statement, 12)
                )
            case SQLITE_DONE:
                return cache
            default:
                throw sqliteError()
            }
        }
    }

    func loadTokenDiscoveryCache() throws -> [String: TokenDiscoveryCacheEntry] {
        // 发现缓存以日志路径为主键，允许在尚未解析出会话 ID 时复用文件检查结果。
        let statement = try prepare(
            """
            SELECT rollout_path, file_size, file_mtime_ns, subagent_id,
                   parent_thread_id, parser_version
            FROM token_discovery_cache
            """
        )
        // 查询结束后统一释放 SQLite 语句资源。
        defer { sqlite3_finalize(statement) }

        // 返回字典便于目录枚举按路径进行常数时间命中判断。
        var cache: [String: TokenDiscoveryCacheEntry] = [:]
        // 持续读取全部缓存行，直到 SQLite 明确返回完成状态。
        while true {
            // 每次 step 只处理一行或结束状态，异常状态直接向上抛出。
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                // 路径同时作为缓存记录内容和返回字典的稳定键。
                let rolloutPath = text(at: 0, in: statement)
                // 可空的子代理和父会话字段共同表达正缓存；两者为空表达负缓存。
                cache[rolloutPath] = TokenDiscoveryCacheEntry(
                    rolloutPath: rolloutPath,
                    fileSize: sqlite3_column_int64(statement, 1),
                    fileModificationTimeNS: sqlite3_column_int64(statement, 2),
                    subagentID: optionalText(at: 3, in: statement),
                    parentThreadID: optionalText(at: 4, in: statement),
                    parserVersion: sqlite3_column_int64(statement, 5)
                )
            case SQLITE_DONE:
                // 完整读取后一次性返回，避免调用方看到半份缓存。
                return cache
            default:
                // 保留 SQLite 原始错误信息，便于定位数据库损坏或语句问题。
                throw sqliteError()
            }
        }
    }

    func updateTokenDiscoveryCache(
        changedEntries: [TokenDiscoveryCacheEntry],
        removedPaths: Set<String>
    ) throws {
        // 没有变更时不启动事务，避免温刷新产生无意义的数据库写入和唤醒。
        guard !changedEntries.isEmpty || !removedPaths.isEmpty else { return }

        // 删除和写入必须原子完成，保证下次扫描不会读取到半更新索引。
        try execute("BEGIN")
        do {
            // 仅在存在已消失文件时准备删除语句，减少纯更新场景的 SQLite 工作。
            if !removedPaths.isEmpty {
                // 预编译一次删除语句，并在循环中复用绑定槽位。
                let deleteStatement = try prepare(
                    "DELETE FROM token_discovery_cache WHERE rollout_path = ?"
                )
                do {
                    // 路径集合天然去重，确保每个失效缓存最多删除一次。
                    for rolloutPath in removedPaths {
                        // 清理上一次执行状态和参数，避免路径绑定在循环间串用。
                        guard sqlite3_reset(deleteStatement) == SQLITE_OK,
                            sqlite3_clear_bindings(deleteStatement) == SQLITE_OK
                        else {
                            throw sqliteError()
                        }
                        // 使用参数绑定删除指定日志路径，避免路径字符影响 SQL。
                        try bind(rolloutPath, to: 1, in: deleteStatement)
                        // 单条删除完成后再处理下一路径，任一失败都会回滚整个批次。
                        try finish(deleteStatement)
                    }
                } catch {
                    // 异常路径也必须释放已准备的删除语句。
                    sqlite3_finalize(deleteStatement)
                    throw error
                }
                // 正常完成批量删除后释放语句资源。
                sqlite3_finalize(deleteStatement)
            }

            // 仅在存在新增或变化文件时准备 UPSERT 语句。
            if !changedEntries.isEmpty {
                // 路径冲突时覆盖全部判定字段，使文件变化和解析器升级立即生效。
                let upsertStatement = try prepare(
                    """
                    INSERT INTO token_discovery_cache (
                      rollout_path, file_size, file_mtime_ns, subagent_id,
                      parent_thread_id, parser_version
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(rollout_path) DO UPDATE SET
                      file_size = excluded.file_size,
                      file_mtime_ns = excluded.file_mtime_ns,
                      subagent_id = excluded.subagent_id,
                      parent_thread_id = excluded.parent_thread_id,
                      parser_version = excluded.parser_version
                    """
                )
                do {
                    // 按发现结果逐条更新，正缓存与字段为空的负缓存使用同一写入路径。
                    for entry in changedEntries {
                        // 清理上一次执行状态和参数，确保可空字段不会残留旧值。
                        guard sqlite3_reset(upsertStatement) == SQLITE_OK,
                            sqlite3_clear_bindings(upsertStatement) == SQLITE_OK
                        else {
                            throw sqliteError()
                        }
                        // 路径作为稳定主键，决定本行是新增还是覆盖。
                        try bind(entry.rolloutPath, to: 1, in: upsertStatement)
                        // 文件大小用于发现层快速判断日志是否变化。
                        try bind(entry.fileSize, to: 2, in: upsertStatement)
                        // 纳秒修改时间与大小共同降低内容变化漏判概率。
                        try bind(entry.fileModificationTimeNS, to: 3, in: upsertStatement)
                        // 子代理字段为空时持久化为 NULL，明确表示负缓存。
                        try bind(entry.subagentID, to: 4, in: upsertStatement)
                        // 父会话字段与子代理字段同步持久化，恢复完整归属关系。
                        try bind(entry.parentThreadID, to: 5, in: upsertStatement)
                        // 解析器版本变化会使旧缓存失效，因此必须随记录保存。
                        try bind(entry.parserVersion, to: 6, in: upsertStatement)
                        // 完成本行 UPSERT；任一失败都会回滚删除和其他写入。
                        try finish(upsertStatement)
                    }
                } catch {
                    // 异常路径也必须释放已准备的 UPSERT 语句。
                    sqlite3_finalize(upsertStatement)
                    throw error
                }
                // 正常完成批量写入后释放语句资源。
                sqlite3_finalize(upsertStatement)
            }

            // 删除与写入全部成功后提交，向后续扫描一次性公开新索引。
            try execute("COMMIT")
        } catch {
            // 保存原始事务错误，避免回滚失败覆盖真正的写入原因。
            let transactionError = error
            // 尽力回滚本轮修改，使之前已提交的缓存继续保持可用。
            try? execute("ROLLBACK")
            // 将最初的读写错误交给调用方处理或降级。
            throw transactionError
        }
    }

    func loadThreadTokenDailyUsage() throws -> [ThreadTokenDailyUsage] {
        let statement = try prepare(
            """
            SELECT thread_id, day_start, input_tokens, cached_input_tokens,
                   output_tokens, reasoning_output_tokens, total_tokens
            FROM thread_token_daily
            ORDER BY thread_id, day_start
            """
        )
        defer { sqlite3_finalize(statement) }

        var dailyUsage: [ThreadTokenDailyUsage] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                dailyUsage.append(
                    ThreadTokenDailyUsage(
                        threadID: text(at: 0, in: statement),
                        dayStart: sqlite3_column_int64(statement, 1),
                        usage: TokenUsageBreakdown(
                            inputTokens: sqlite3_column_int64(statement, 2),
                            cachedInputTokens: sqlite3_column_int64(statement, 3),
                            outputTokens: sqlite3_column_int64(statement, 4),
                            reasoningOutputTokens: sqlite3_column_int64(statement, 5),
                            totalTokens: sqlite3_column_int64(statement, 6)
                        )
                    ))
            case SQLITE_DONE:
                return dailyUsage
            default:
                throw sqliteError()
            }
        }
    }

    func loadStatisticsSnapshots(inputKey: String) throws -> [String: StatisticsSnapshot] {
        let statement = try prepare(
            """
            SELECT scope, snapshot_json
            FROM statistics_snapshots
            WHERE input_key = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(inputKey, to: 1, in: statement)

        var snapshots: [String: StatisticsSnapshot] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let scope = text(at: 0, in: statement)
                guard let data = data(at: 1, in: statement),
                    let snapshot = try? JSONDecoder().decode(
                        StatisticsSnapshot.self,
                        from: data
                    )
                else { continue }
                snapshots[scope] = snapshot
            case SQLITE_DONE:
                return snapshots
            default:
                throw sqliteError()
            }
        }
    }

    func saveStatisticsSnapshot(
        _ snapshot: StatisticsSnapshot,
        scope: String,
        inputKey: String
    ) throws {
        let data = try JSONEncoder().encode(snapshot)
        let statement = try prepare(
            """
            INSERT INTO statistics_snapshots (scope, input_key, snapshot_json)
            VALUES (?, ?, ?)
            ON CONFLICT(scope) DO UPDATE SET
              input_key = excluded.input_key,
              snapshot_json = excluded.snapshot_json
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(scope, to: 1, in: statement)
        try bind(inputKey, to: 2, in: statement)
        try bind(data, to: 3, in: statement)
        try finish(statement)
    }

    func loadThreadTokenTimedUsage(
        startingAt start: Int64,
        endingAt end: Int64
    ) throws -> [ThreadTokenTimedUsage] {
        let statement = try prepare(
            """
            SELECT thread_id, event_at, input_tokens, cached_input_tokens,
                   output_tokens, reasoning_output_tokens, total_tokens
            FROM thread_token_timed
            WHERE event_at >= ? AND event_at <= ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(start, to: 1, in: statement)
        try bind(end, to: 2, in: statement)

        var timedUsage: [ThreadTokenTimedUsage] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                timedUsage.append(
                    ThreadTokenTimedUsage(
                        threadID: text(at: 0, in: statement),
                        eventAt: sqlite3_column_int64(statement, 1),
                        usage: TokenUsageBreakdown(
                            inputTokens: sqlite3_column_int64(statement, 2),
                            cachedInputTokens: sqlite3_column_int64(statement, 3),
                            outputTokens: sqlite3_column_int64(statement, 4),
                            reasoningOutputTokens: sqlite3_column_int64(statement, 5),
                            totalTokens: sqlite3_column_int64(statement, 6)
                        )
                    ))
            case SQLITE_DONE:
                return timedUsage
            default:
                throw sqliteError()
            }
        }
    }

    func loadThreadTokenTimedDailyUsage(
        startingAt start: Int64,
        endingAt end: Int64,
        calendar: Calendar
    ) throws -> [ThreadTokenDailyUsage] {
        guard start <= end else { return [] }

        // 用 Calendar 生成真实本地日边界，避免夏令时日期被固定 24 小时切错。
        var ranges: [(dayStart: Int64, start: Int64, end: Int64)] = []
        var day = calendar.startOfDay(
            for: Date(timeIntervalSince1970: TimeInterval(start))
        )
        while Int64(day.timeIntervalSince1970) <= end {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else {
                throw MetadataStoreError.sqlite("Unable to resolve local Token day range")
            }
            let dayStart = Int64(day.timeIntervalSince1970)
            let nextDayStart = Int64(nextDay.timeIntervalSince1970)
            guard nextDayStart > dayStart else {
                throw MetadataStoreError.sqlite("Invalid local Token day range")
            }
            ranges.append(
                (
                    dayStart: dayStart,
                    start: max(start, dayStart),
                    end: min(end, nextDayStart - 1)
                ))
            day = nextDay
        }

        // 常量日期范围与 event_at 索引连接，SQLite 只返回每会话每日一行汇总。
        let values = Array(repeating: "(?, ?, ?)", count: ranges.count).joined(separator: ", ")
        let statement = try prepare(
            """
            WITH day_ranges(day_start, range_start, range_end) AS (
              VALUES \(values)
            )
            SELECT timed.thread_id, day_ranges.day_start,
                   SUM(timed.input_tokens), SUM(timed.cached_input_tokens),
                   SUM(timed.output_tokens), SUM(timed.reasoning_output_tokens),
                   SUM(timed.total_tokens)
            FROM day_ranges
            JOIN thread_token_timed AS timed
              ON timed.event_at >= day_ranges.range_start
             AND timed.event_at <= day_ranges.range_end
            GROUP BY timed.thread_id, day_ranges.day_start
            """
        )
        defer { sqlite3_finalize(statement) }
        for (offset, range) in ranges.enumerated() {
            let firstIndex = Int32(offset * 3 + 1)
            try bind(range.dayStart, to: firstIndex, in: statement)
            try bind(range.start, to: firstIndex + 1, in: statement)
            try bind(range.end, to: firstIndex + 2, in: statement)
        }

        var dailyUsage: [ThreadTokenDailyUsage] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                dailyUsage.append(
                    ThreadTokenDailyUsage(
                        threadID: text(at: 0, in: statement),
                        dayStart: sqlite3_column_int64(statement, 1),
                        usage: TokenUsageBreakdown(
                            inputTokens: sqlite3_column_int64(statement, 2),
                            cachedInputTokens: sqlite3_column_int64(statement, 3),
                            outputTokens: sqlite3_column_int64(statement, 4),
                            reasoningOutputTokens: sqlite3_column_int64(statement, 5),
                            totalTokens: sqlite3_column_int64(statement, 6)
                        )
                    ))
            case SQLITE_DONE:
                return dailyUsage
            default:
                throw sqliteError()
            }
        }
    }

    func pruneThreadTokenTimedUsage(before cutoff: Int64) throws -> Int {
        // 秒级明细只承担近期精确统计，按传入边界删除更早记录。
        let statement = try prepare("DELETE FROM thread_token_timed WHERE event_at < ?")
        // 无论删除成功或失败都释放 SQLite 语句资源。
        defer { sqlite3_finalize(statement) }
        // 将保留边界绑定到参数，避免把时间值拼进 SQL。
        try bind(cutoff, to: 1, in: statement)
        // 单条 DELETE 由 SQLite 原子执行，失败时直接向上抛错。
        try finish(statement)
        // 返回本次实际删除行数，供上层记录清理效果和跳过无变化场景。
        return Int(sqlite3_changes(database))
    }

    func saveThreadProject(_ project: ThreadProjectCache) throws {
        let stored = Self.storedProjectResolution(project.resolution)
        let statement = try prepare(
            """
            INSERT INTO thread_projects (
              thread_id, project_path, analyzed_updated_at,
              resolution_kind, classifier_version
            )
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(thread_id) DO UPDATE SET
              project_path = excluded.project_path,
              analyzed_updated_at = excluded.analyzed_updated_at
              ,resolution_kind = excluded.resolution_kind
              ,classifier_version = excluded.classifier_version
            WHERE excluded.classifier_version > thread_projects.classifier_version
               OR (
                 excluded.classifier_version = thread_projects.classifier_version
                 AND excluded.analyzed_updated_at >= thread_projects.analyzed_updated_at
               )
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(project.threadID, to: 1, in: statement)
        if let projectPath = stored.path {
            try bind(projectPath, to: 2, in: statement)
        } else if sqlite3_bind_null(statement, 2) != SQLITE_OK {
            throw sqliteError()
        }
        guard sqlite3_bind_int64(statement, 3, project.analyzedUpdatedAt) == SQLITE_OK else {
            throw sqliteError()
        }
        try bind(stored.kind, to: 4, in: statement)
        guard sqlite3_bind_int64(statement, 5, project.classifierVersion) == SQLITE_OK else {
            throw sqliteError()
        }
        try finish(statement)
    }

    func saveThreadTokenScan(
        threadID: String,
        rolloutPath: String,
        fileSize: Int64,
        fileModificationTimeNS: Int64,
        parserVersion: Int64,
        result: TokenScanResult,
        rebuild: Bool,
        timedUsageCutoff: Int64? = nil,
        reconciledAt: Int64? = nil,
        recalculationRange: TokenUsageRecalculationRange? = nil
    ) throws {
        guard result.observedCheckpoint || rebuild else { return }

        try execute("BEGIN")
        do {
            if rebuild {
                for (table, timestampColumn) in [
                    ("thread_token_daily", "day_start"),
                    ("thread_token_timed", "event_at"),
                ] {
                    let deleteStatement = try prepare(
                        recalculationRange == nil
                            ? "DELETE FROM \(table) WHERE thread_id = ?"
                            : """
                            DELETE FROM \(table)
                            WHERE thread_id = ? AND \(timestampColumn) >= ? AND \(timestampColumn) < ?
                            """
                    )
                    do {
                        try bind(threadID, to: 1, in: deleteStatement)
                        if let recalculationRange {
                            try bind(recalculationRange.startDay, to: 2, in: deleteStatement)
                            try bind(
                                recalculationRange.endDayExclusive,
                                to: 3,
                                in: deleteStatement
                            )
                        }
                        try finish(deleteStatement)
                    } catch {
                        sqlite3_finalize(deleteStatement)
                        throw error
                    }
                    sqlite3_finalize(deleteStatement)
                }

            }

            let cacheStatement = try prepare(
                """
                INSERT INTO thread_token_usage (
                  thread_id, rollout_path, file_size, file_mtime_ns, scanned_offset,
                  input_tokens, cached_input_tokens, output_tokens,
                  reasoning_output_tokens, total_tokens, last_event_at, parser_version,
                  last_reconciled_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(thread_id) DO UPDATE SET
                  rollout_path = excluded.rollout_path,
                  file_size = excluded.file_size,
                  file_mtime_ns = excluded.file_mtime_ns,
                  scanned_offset = excluded.scanned_offset,
                  input_tokens = excluded.input_tokens,
                  cached_input_tokens = excluded.cached_input_tokens,
                  output_tokens = excluded.output_tokens,
                  reasoning_output_tokens = excluded.reasoning_output_tokens,
                  total_tokens = excluded.total_tokens,
                  last_event_at = excluded.last_event_at,
                  parser_version = excluded.parser_version,
                  last_reconciled_at = COALESCE(
                    excluded.last_reconciled_at,
                    thread_token_usage.last_reconciled_at
                  )
                """
            )
            do {
                try bind(threadID, to: 1, in: cacheStatement)
                try bind(rolloutPath, to: 2, in: cacheStatement)
                try bind(fileSize, to: 3, in: cacheStatement)
                try bind(fileModificationTimeNS, to: 4, in: cacheStatement)
                try bind(result.offset, to: 5, in: cacheStatement)
                try bind(result.maximum, startingAt: 6, in: cacheStatement)
                try bind(result.latestEventTimestamp, to: 11, in: cacheStatement)
                try bind(parserVersion, to: 12, in: cacheStatement)
                try bind(reconciledAt, to: 13, in: cacheStatement)
                try finish(cacheStatement)
            } catch {
                sqlite3_finalize(cacheStatement)
                throw error
            }
            sqlite3_finalize(cacheStatement)

            let dailyStatement = try prepare(
                """
                INSERT INTO thread_token_daily (
                  thread_id, day_start, input_tokens, cached_input_tokens,
                  output_tokens, reasoning_output_tokens, total_tokens
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(thread_id, day_start) DO UPDATE SET
                  input_tokens = thread_token_daily.input_tokens + excluded.input_tokens,
                  cached_input_tokens = thread_token_daily.cached_input_tokens + excluded.cached_input_tokens,
                  output_tokens = thread_token_daily.output_tokens + excluded.output_tokens,
                  reasoning_output_tokens = thread_token_daily.reasoning_output_tokens + excluded.reasoning_output_tokens,
                  total_tokens = thread_token_daily.total_tokens + excluded.total_tokens
                """
            )
            do {
                for (dayStart, usage) in result.dailyUsage
                where !usage.isZero
                    && (recalculationRange.map { $0.contains(dayStart) } ?? true)
                {
                    guard sqlite3_reset(dailyStatement) == SQLITE_OK,
                        sqlite3_clear_bindings(dailyStatement) == SQLITE_OK
                    else {
                        throw sqliteError()
                    }
                    try bind(threadID, to: 1, in: dailyStatement)
                    try bind(dayStart, to: 2, in: dailyStatement)
                    try bind(usage, startingAt: 3, in: dailyStatement)
                    try finish(dailyStatement)
                }
            } catch {
                sqlite3_finalize(dailyStatement)
                throw error
            }
            sqlite3_finalize(dailyStatement)

            let timedStatement = try prepare(
                """
                INSERT INTO thread_token_timed (
                  thread_id, event_at, input_tokens, cached_input_tokens,
                  output_tokens, reasoning_output_tokens, total_tokens
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(thread_id, event_at) DO UPDATE SET
                  input_tokens = thread_token_timed.input_tokens + excluded.input_tokens,
                  cached_input_tokens = thread_token_timed.cached_input_tokens + excluded.cached_input_tokens,
                  output_tokens = thread_token_timed.output_tokens + excluded.output_tokens,
                  reasoning_output_tokens = thread_token_timed.reasoning_output_tokens + excluded.reasoning_output_tokens,
                  total_tokens = thread_token_timed.total_tokens + excluded.total_tokens
                """
            )
            do {
                for (eventAt, usage) in result.timedUsage
                where !usage.isZero
                    && (recalculationRange.map { $0.contains(eventAt) } ?? true)
                {
                    // 重扫可能重新产出全部历史事件，只写入保留边界内的秒级明细。
                    if let timedUsageCutoff, eventAt < timedUsageCutoff {
                        // 日汇总已在上方完整保存，过期秒级记录可以安全跳过。
                        continue
                    }
                    // 复用预编译语句前清理上一次循环的执行状态和绑定值。
                    guard sqlite3_reset(timedStatement) == SQLITE_OK,
                        sqlite3_clear_bindings(timedStatement) == SQLITE_OK
                    else {
                        throw sqliteError()
                    }
                    // 秒级明细继续归属原始日志目标，后续统计再处理父子会话归属。
                    try bind(threadID, to: 1, in: timedStatement)
                    // 保留原始事件秒级时间，确保额度周期边界可以精确过滤。
                    try bind(eventAt, to: 2, in: timedStatement)
                    // 一次写入所有 Token 分量，保持日汇总与秒级明细口径一致。
                    try bind(usage, startingAt: 3, in: timedStatement)
                    // 完成本行写入；相同会话和秒的增量由 UPSERT 累加。
                    try finish(timedStatement)
                }
            } catch {
                sqlite3_finalize(timedStatement)
                throw error
            }
            sqlite3_finalize(timedStatement)
            try execute("COMMIT")
        } catch {
            let transactionError = error
            try? execute("ROLLBACK")
            throw transactionError
        }
    }

    func setFavorite(threadID: String, isFavorite: Bool) throws {
        try setFavorite(threadIDs: [threadID], isFavorite: isFavorite)
    }

    func setFavorite(threadIDs: Set<String>, isFavorite: Bool) throws {
        guard !threadIDs.isEmpty else { return }
        let statement = try prepare(
            """
            INSERT INTO thread_meta (thread_id, is_favorite) VALUES (?, ?)
            ON CONFLICT(thread_id) DO UPDATE SET is_favorite = excluded.is_favorite
            """
        )
        defer { sqlite3_finalize(statement) }

        try execute("BEGIN")
        do {
            for threadID in threadIDs.sorted() {
                guard sqlite3_reset(statement) == SQLITE_OK,
                    sqlite3_clear_bindings(statement) == SQLITE_OK
                else {
                    throw sqliteError()
                }
                try bind(threadID, to: 1, in: statement)
                guard sqlite3_bind_int(statement, 2, isFavorite ? 1 : 0) == SQLITE_OK else {
                    throw sqliteError()
                }
                try finish(statement)
            }
            try execute("COMMIT")
        } catch {
            let transactionError = error
            try? execute("ROLLBACK")
            throw transactionError
        }
    }

    func createCollection(name: String) throws -> SessionCollection {
        let id = UUID().uuidString.lowercased()
        let sortOrder = try nextSortOrder(in: "collections")
        let statement = try prepare(
            "INSERT INTO collections (id, name, sort_order) VALUES (?, ?, ?)"
        )
        defer { sqlite3_finalize(statement) }

        try bind(id, to: 1, in: statement)
        try bind(name, to: 2, in: statement)
        guard sqlite3_bind_int64(statement, 3, Int64(sortOrder)) == SQLITE_OK else {
            throw sqliteError()
        }
        try finish(statement)
        return SessionCollection(id: id, name: name, sortOrder: sortOrder)
    }

    func createSavedView(
        name: String,
        selection: SidebarSelection,
        query: String,
        timeFilter: SessionTimeFilter,
        sortOrder: SessionSortOrder
    ) throws -> SavedSessionView {
        guard let storedSelection = Self.storedSavedViewSelection(selection) else {
            throw MetadataStoreError.sqlite("Unsupported saved view selection")
        }
        let id = UUID().uuidString.lowercased()
        let position = try nextSortOrder(in: "saved_views")
        let statement = try prepare(
            """
            INSERT INTO saved_views (
              id, name, selection_kind, selection_value, query, time_filter,
              session_sort_order, sort_order
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(id, to: 1, in: statement)
        try bind(name, to: 2, in: statement)
        try bind(storedSelection.kind, to: 3, in: statement)
        try bind(storedSelection.value, to: 4, in: statement)
        try bind(query, to: 5, in: statement)
        try bind(timeFilter.statisticsPersistenceScope, to: 6, in: statement)
        try bind(Self.storedSavedViewSortOrder(sortOrder), to: 7, in: statement)
        try bind(Int64(position), to: 8, in: statement)
        try finish(statement)
        return SavedSessionView(
            id: id,
            name: name,
            selection: selection,
            query: query,
            timeFilter: timeFilter,
            sortOrder: sortOrder,
            position: position
        )
    }

    func deleteSavedView(id: String) throws {
        let statement = try prepare("DELETE FROM saved_views WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id, to: 1, in: statement)
        try finish(statement)
    }

    func assign(threadID: String, collectionID: String?) throws {
        let statement = try prepare(
            """
            INSERT INTO thread_meta (thread_id, collection_id) VALUES (?, ?)
            ON CONFLICT(thread_id) DO UPDATE SET collection_id = excluded.collection_id
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(threadID, to: 1, in: statement)
        if let collectionID {
            try bind(collectionID, to: 2, in: statement)
        } else if sqlite3_bind_null(statement, 2) != SQLITE_OK {
            throw sqliteError()
        }
        try finish(statement)
    }

    func createTag(name: String, colorHex: String) throws -> SessionTag {
        let id = UUID().uuidString.lowercased()
        let sortOrder = try nextSortOrder(in: "tags")
        let statement = try prepare(
            "INSERT INTO tags (id, name, color_hex, sort_order) VALUES (?, ?, ?, ?)"
        )
        defer { sqlite3_finalize(statement) }

        try bind(id, to: 1, in: statement)
        try bind(name, to: 2, in: statement)
        try bind(colorHex, to: 3, in: statement)
        guard sqlite3_bind_int64(statement, 4, Int64(sortOrder)) == SQLITE_OK else {
            throw sqliteError()
        }
        try finish(statement)
        return SessionTag(id: id, name: name, colorHex: colorHex, sortOrder: sortOrder)
    }

    func setTags(threadID: String, tagIDs: Set<String>) throws {
        try execute("BEGIN")
        do {
            let deleteStatement = try prepare("DELETE FROM thread_tags WHERE thread_id = ?")
            do {
                try bind(threadID, to: 1, in: deleteStatement)
                try finish(deleteStatement)
            } catch {
                sqlite3_finalize(deleteStatement)
                throw error
            }
            sqlite3_finalize(deleteStatement)

            for tagID in tagIDs {
                let insertStatement = try prepare(
                    "INSERT INTO thread_tags (thread_id, tag_id) VALUES (?, ?)"
                )
                do {
                    try bind(threadID, to: 1, in: insertStatement)
                    try bind(tagID, to: 2, in: insertStatement)
                    try finish(insertStatement)
                } catch {
                    sqlite3_finalize(insertStatement)
                    throw error
                }
                sqlite3_finalize(insertStatement)
            }
            try execute("COMMIT")
        } catch {
            do {
                try execute("ROLLBACK")
            } catch {
                throw error
            }
            throw error
        }
    }

    private static func createSchema(
        in database: OpaquePointer,
        previousSchemaVersion: Int32
    ) throws {
        let schema = """
            CREATE TABLE IF NOT EXISTS collections (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL UNIQUE,
              sort_order INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS tags (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL UNIQUE,
              color_hex TEXT NOT NULL,
              sort_order INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS saved_views (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL UNIQUE,
              selection_kind TEXT NOT NULL,
              selection_value TEXT,
              query TEXT NOT NULL,
              time_filter TEXT NOT NULL,
              session_sort_order TEXT NOT NULL,
              sort_order INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS thread_meta (
              thread_id TEXT PRIMARY KEY,
              is_favorite INTEGER NOT NULL DEFAULT 0,
              collection_id TEXT REFERENCES collections(id) ON DELETE SET NULL
            );
            CREATE TABLE IF NOT EXISTS thread_tags (
              thread_id TEXT NOT NULL,
              tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
              PRIMARY KEY(thread_id, tag_id)
            );
            CREATE TABLE IF NOT EXISTS thread_projects (
              thread_id TEXT PRIMARY KEY,
              project_path TEXT,
              analyzed_updated_at INTEGER NOT NULL,
              resolution_kind TEXT NOT NULL DEFAULT 'legacy',
              classifier_version INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS thread_token_usage (
              thread_id TEXT PRIMARY KEY,
              rollout_path TEXT NOT NULL,
              file_size INTEGER NOT NULL,
              file_mtime_ns INTEGER NOT NULL,
              scanned_offset INTEGER NOT NULL,
              input_tokens INTEGER NOT NULL,
              cached_input_tokens INTEGER NOT NULL,
              output_tokens INTEGER NOT NULL,
              reasoning_output_tokens INTEGER NOT NULL,
              total_tokens INTEGER NOT NULL,
              last_event_at INTEGER,
              parser_version INTEGER NOT NULL,
              last_reconciled_at INTEGER
            );
            CREATE TABLE IF NOT EXISTS thread_token_daily (
              thread_id TEXT NOT NULL,
              day_start INTEGER NOT NULL,
              input_tokens INTEGER NOT NULL,
              cached_input_tokens INTEGER NOT NULL,
              output_tokens INTEGER NOT NULL,
              reasoning_output_tokens INTEGER NOT NULL,
              total_tokens INTEGER NOT NULL,
              PRIMARY KEY (thread_id, day_start)
            );
            CREATE TABLE IF NOT EXISTS thread_token_timed (
              thread_id TEXT NOT NULL,
              event_at INTEGER NOT NULL,
              input_tokens INTEGER NOT NULL,
              cached_input_tokens INTEGER NOT NULL,
              output_tokens INTEGER NOT NULL,
              reasoning_output_tokens INTEGER NOT NULL,
              total_tokens INTEGER NOT NULL,
              PRIMARY KEY (thread_id, event_at)
            );
            CREATE INDEX IF NOT EXISTS thread_token_timed_event_at
              ON thread_token_timed(event_at);
            CREATE TABLE IF NOT EXISTS token_discovery_cache (
              rollout_path TEXT PRIMARY KEY,
              file_size INTEGER NOT NULL,
              file_mtime_ns INTEGER NOT NULL,
              subagent_id TEXT,
              parent_thread_id TEXT,
              parser_version INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS statistics_snapshots (
              scope TEXT PRIMARY KEY,
              input_key TEXT NOT NULL,
              snapshot_json BLOB NOT NULL
            );
            """
        try execute("PRAGMA foreign_keys = ON", in: database)
        try execute("BEGIN IMMEDIATE", in: database)
        do {
            try execute(schema, in: database)
            try addColumnIfNeeded(
                "resolution_kind",
                definition: "TEXT NOT NULL DEFAULT 'legacy'",
                to: "thread_projects",
                in: database
            )
            try addColumnIfNeeded(
                "classifier_version",
                definition: "INTEGER NOT NULL DEFAULT 0",
                to: "thread_projects",
                in: database
            )
            try addColumnIfNeeded(
                "last_reconciled_at",
                definition: "INTEGER",
                to: "thread_token_usage",
                in: database
            )
            if previousSchemaVersion < schemaVersion {
                try execute("PRAGMA user_version = \(schemaVersion)", in: database)
            }
            try execute("COMMIT", in: database)
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private static func schemaVersion(in database: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            throw MetadataStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw MetadataStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        return sqlite3_column_int(statement, 0)
    }

    private static func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw MetadataStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func addColumnIfNeeded(
        _ column: String,
        definition: String,
        to table: String,
        in database: OpaquePointer
    ) throws {
        guard !tableColumns(table, in: database).contains(column) else { return }
        let sql = "ALTER TABLE \(table) ADD COLUMN \(column) \(definition)"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw MetadataStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func tableColumns(_ table: String, in database: OpaquePointer) -> Set<String> {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil)
                == SQLITE_OK,
            let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }

        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else { continue }
            columns.insert(String(cString: name))
        }
        return columns
    }

    private static func projectResolution(
        kind: String,
        path: String?
    ) -> ThreadProjectResolution? {
        switch (kind, path) {
        case ("project", .some(let path)) where !path.isEmpty:
            .project(path: path)
        case ("working_directory", .some(let path)) where !path.isEmpty:
            .workingDirectory(path: path)
        case ("no_project", .none):
            .noProject
        default:
            nil
        }
    }

    private static func savedViewSelection(
        kind: String,
        value: String?
    ) -> SidebarSelection? {
        switch (kind, value) {
        case ("recent", nil): .recent
        case ("favorites", nil): .favorites
        case ("unclassified", nil): .unclassified
        case ("no_project", nil): .noProject
        case ("archived", nil): .archived
        case ("project", .some(let value)): .project(value)
        case ("collection", .some(let value)): .collection(value)
        case ("tag", .some(let value)): .tag(value)
        default: nil
        }
    }

    private static func storedSavedViewSelection(
        _ selection: SidebarSelection
    ) -> (kind: String, value: String?)? {
        switch selection {
        case .recent: ("recent", nil)
        case .favorites: ("favorites", nil)
        case .unclassified: ("unclassified", nil)
        case .noProject: ("no_project", nil)
        case .archived: ("archived", nil)
        case .project(let path): ("project", path)
        case .collection(let id): ("collection", id)
        case .tag(let id): ("tag", id)
        case .quota, .statistics, .savedView: nil
        }
    }

    private static func savedViewSortOrder(_ value: String) -> SessionSortOrder? {
        switch value {
        case "recent": .recent
        case "oldest": .oldest
        case "title": .title
        default: nil
        }
    }

    private static func storedSavedViewSortOrder(_ sortOrder: SessionSortOrder) -> String {
        switch sortOrder {
        case .recent: "recent"
        case .oldest: "oldest"
        case .title: "title"
        }
    }

    private static func storedProjectResolution(
        _ resolution: ThreadProjectResolution
    ) -> (kind: String, path: String?) {
        switch resolution {
        case .project(let path): ("project", path)
        case .workingDirectory(let path): ("working_directory", path)
        case .noProject: ("no_project", nil)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            throw sqliteError()
        }
        return statement
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else {
            throw sqliteError()
        }
    }

    private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) throws {
        // 非空文本沿用统一的瞬时绑定策略，确保 Swift 字符串生命周期安全。
        if let value {
            try bind(value, to: index, in: statement)
        } else if sqlite3_bind_null(statement, index) != SQLITE_OK {
            // 空值必须显式绑定 NULL，失败时保留 SQLite 错误上下文。
            throw sqliteError()
        }
    }

    private func bind(_ value: Int64, to index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw sqliteError()
        }
    }

    private func bind(_ value: Int64?, to index: Int32, in statement: OpaquePointer) throws {
        if let value {
            try bind(value, to: index, in: statement)
        } else if sqlite3_bind_null(statement, index) != SQLITE_OK {
            throw sqliteError()
        }
    }

    private func bind(_ value: Data, to index: Int32, in statement: OpaquePointer) throws {
        let result = value.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), sqliteTransient)
        }
        guard result == SQLITE_OK else { throw sqliteError() }
    }

    private func bind(
        _ usage: TokenUsageBreakdown,
        startingAt index: Int32,
        in statement: OpaquePointer
    ) throws {
        try bind(usage.inputTokens, to: index, in: statement)
        try bind(usage.cachedInputTokens, to: index + 1, in: statement)
        try bind(usage.outputTokens, to: index + 2, in: statement)
        try bind(usage.reasoningOutputTokens, to: index + 3, in: statement)
        try bind(usage.totalTokens, to: index + 4, in: statement)
    }

    private func finish(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError()
        }
    }

    private func nextSortOrder(in table: String) throws -> Int {
        let statement = try prepare(
            "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM \(table)"
        )
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw sqliteError()
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError()
        }
    }

    private func sqliteError() -> MetadataStoreError {
        .sqlite(String(cString: sqlite3_errmsg(database)))
    }

    private func text(at index: Int32, in statement: OpaquePointer) -> String {
        String(cString: sqlite3_column_text(statement, index))
    }

    private func optionalText(at index: Int32, in statement: OpaquePointer) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return text(at: index, in: statement)
    }

    private func data(at index: Int32, in statement: OpaquePointer) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: count)
    }
}
