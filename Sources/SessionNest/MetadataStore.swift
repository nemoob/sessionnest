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
}

struct ThreadTokenDailyUsage: Equatable, Sendable {
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
    nonisolated(unsafe) private let database: OpaquePointer

    init(databaseURL: URL) throws {
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
            try Self.createSchema(in: database)
        } catch {
            sqlite3_close(database)
            throw error
        }
        self.database = database
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
                   reasoning_output_tokens, total_tokens, last_event_at, parser_version
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
                    parserVersion: sqlite3_column_int64(statement, 11)
                )
            case SQLITE_DONE:
                return cache
            default:
                throw sqliteError()
            }
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
            ORDER BY thread_id, event_at
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
        rebuild: Bool
    ) throws {
        guard result.observedCheckpoint || rebuild else { return }

        try execute("BEGIN")
        do {
            if rebuild {
                for table in ["thread_token_daily", "thread_token_timed"] {
                    let deleteStatement = try prepare(
                        "DELETE FROM \(table) WHERE thread_id = ?"
                    )
                    do {
                        try bind(threadID, to: 1, in: deleteStatement)
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
                  reasoning_output_tokens, total_tokens, last_event_at, parser_version
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                  parser_version = excluded.parser_version
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
                for (dayStart, usage) in result.dailyUsage where !usage.isZero {
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
                for (eventAt, usage) in result.timedUsage where !usage.isZero {
                    guard sqlite3_reset(timedStatement) == SQLITE_OK,
                        sqlite3_clear_bindings(timedStatement) == SQLITE_OK
                    else {
                        throw sqliteError()
                    }
                    try bind(threadID, to: 1, in: timedStatement)
                    try bind(eventAt, to: 2, in: timedStatement)
                    try bind(usage, startingAt: 3, in: timedStatement)
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
        let statement = try prepare(
            """
            INSERT INTO thread_meta (thread_id, is_favorite) VALUES (?, ?)
            ON CONFLICT(thread_id) DO UPDATE SET is_favorite = excluded.is_favorite
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(threadID, to: 1, in: statement)
        guard sqlite3_bind_int(statement, 2, isFavorite ? 1 : 0) == SQLITE_OK else {
            throw sqliteError()
        }
        try finish(statement)
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

    private static func createSchema(in database: OpaquePointer) throws {
        let schema = """
            PRAGMA foreign_keys = ON;
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
              parser_version INTEGER NOT NULL
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
            """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw MetadataStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
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
}
