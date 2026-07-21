import Foundation
import SQLite3
import Testing

@testable import SessionNest

@Test func metadataPersistsFavoritesCollectionsAndTags() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try MetadataStore(databaseURL: directory.appendingPathComponent("manager.sqlite"))

    let collection = try await store.createCollection(name: "Sample Work")
    let tag = try await store.createTag(name: "Bug Fix", colorHex: "#B66B52")
    try await store.setFavorite(threadID: "t1", isFavorite: true)
    try await store.assign(threadID: "t1", collectionID: collection.id)
    try await store.setTags(threadID: "t1", tagIDs: [tag.id])

    let metadata = try await store.loadMetadata()
    let tagIDs = try await store.loadThreadTags()
    let collections = try await store.loadCollections()
    let tags = try await store.loadTags()
    #expect(
        metadata["t1"]
            == ThreadMetadata(threadID: "t1", isFavorite: true, collectionID: collection.id))
    #expect(tagIDs["t1"] == [tag.id])
    #expect(collections == [collection])
    #expect(tags == [tag])
}

@Test func projectCachePersistsEveryResolutionKind() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try MetadataStore(databaseURL: directory.appendingPathComponent("manager.sqlite"))

    let project = ThreadProjectCache(
        threadID: "project",
        resolution: .project(path: "/work/codex/sample-app"),
        analyzedUpdatedAt: 10,
        classifierVersion: 1
    )
    let workingDirectory = ThreadProjectCache(
        threadID: "working-directory",
        resolution: .workingDirectory(path: "/work/codex"),
        analyzedUpdatedAt: 20,
        classifierVersion: 1
    )
    let noProject = ThreadProjectCache(
        threadID: "no-project",
        resolution: .noProject,
        analyzedUpdatedAt: 30,
        classifierVersion: 1
    )

    try await store.saveThreadProject(project)
    try await store.saveThreadProject(workingDirectory)
    try await store.saveThreadProject(noProject)

    let projects = try await store.loadThreadProjects()
    #expect(projects[project.threadID] == project)
    #expect(projects[workingDirectory.threadID] == workingDirectory)
    #expect(projects[noProject.threadID] == noProject)
}

@Test func legacyProjectCacheMigratesAndRequiresReanalysis() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let databaseURL = directory.appendingPathComponent("manager.sqlite")
    var database: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
    guard let database else { return }
    #expect(
        sqlite3_exec(
            database,
            """
            CREATE TABLE thread_projects (
              thread_id TEXT PRIMARY KEY,
              project_path TEXT,
              analyzed_updated_at INTEGER NOT NULL
            );
            INSERT INTO thread_projects VALUES ('legacy', '/work/legacy', 10);
            """,
            nil,
            nil,
            nil
        ) == SQLITE_OK
    )
    sqlite3_close(database)

    let store = try MetadataStore(databaseURL: databaseURL)
    let projects = try await store.loadThreadProjects()
    #expect(projects["legacy"] == nil)

    var migratedDatabase: OpaquePointer?
    #expect(
        sqlite3_open_v2(databaseURL.path, &migratedDatabase, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
    )
    guard let migratedDatabase else { return }
    defer { sqlite3_close(migratedDatabase) }
    #expect(tableColumns("thread_projects", in: migratedDatabase).contains("resolution_kind"))
    #expect(tableColumns("thread_projects", in: migratedDatabase).contains("classifier_version"))
}

@Test func invalidProjectCacheRowsRequireReanalysis() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let databaseURL = directory.appendingPathComponent("manager.sqlite")
    let store = try MetadataStore(databaseURL: databaseURL)

    var database: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
    guard let database else { return }
    #expect(
        sqlite3_exec(
            database,
            """
            INSERT INTO thread_projects
              (thread_id, project_path, analyzed_updated_at, resolution_kind, classifier_version)
            VALUES
              ('missing-path', NULL, 10, 'project', 1),
              ('unexpected-path', '/work/value', 10, 'no_project', 1),
              ('unknown-kind', '/work/value', 10, 'unknown', 1);
            """,
            nil,
            nil,
            nil
        ) == SQLITE_OK
    )
    sqlite3_close(database)

    let projects = try await store.loadThreadProjects()
    #expect(projects.isEmpty)
}

@Test func projectCacheDoesNotOverwriteNewerAnalysisWithStaleResult() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try MetadataStore(databaseURL: directory.appendingPathComponent("manager.sqlite"))

    let newer = ThreadProjectCache(
        threadID: "known",
        resolution: .project(path: "/work/codex/newer"),
        analyzedUpdatedAt: 20,
        classifierVersion: 1
    )
    try await store.saveThreadProject(newer)
    try await store.saveThreadProject(
        ThreadProjectCache(
            threadID: "known",
            resolution: .project(path: "/work/codex/stale"),
            analyzedUpdatedAt: 10,
            classifierVersion: 1
        ))

    #expect(try await store.loadThreadProjects()["known"] == newer)
}

@Test func tokenUsageCachePersistsAppendAndRebuild() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = try MetadataStore(databaseURL: directory.appendingPathComponent("manager.sqlite"))
    let zeroDay: Int64 = 1_752_336_000
    let firstDay: Int64 = 1_752_422_400
    let secondDay: Int64 = 1_752_508_800

    try await store.saveThreadTokenScan(
        threadID: "measured",
        rolloutPath: "/rollout/first.jsonl",
        fileSize: 400,
        fileModificationTimeNS: 500,
        parserVersion: 1,
        result: tokenScanResult(
            offset: 350,
            maximum: tokenUsage(100, 60, 30, 20, 130),
            dailyUsage: [
                zeroDay: .zero,
                firstDay: tokenUsage(40, 30, 10, 5, 50),
                secondDay: tokenUsage(60, 30, 20, 15, 80),
            ],
            latestEventTimestamp: nil
        ),
        rebuild: false
    )

    #expect(
        try await store.loadThreadTokenCache()["measured"]
            == ThreadTokenCache(
                threadID: "measured",
                rolloutPath: "/rollout/first.jsonl",
                fileSize: 400,
                fileModificationTimeNS: 500,
                scannedOffset: 350,
                maximum: tokenUsage(100, 60, 30, 20, 130),
                latestEventTimestamp: nil,
                parserVersion: 1
            ))
    #expect(
        try await store.loadThreadTokenDailyUsage() == [
            ThreadTokenDailyUsage(
                threadID: "measured",
                dayStart: firstDay,
                usage: tokenUsage(40, 30, 10, 5, 50)
            ),
            ThreadTokenDailyUsage(
                threadID: "measured",
                dayStart: secondDay,
                usage: tokenUsage(60, 30, 20, 15, 80)
            ),
        ])

    try await store.saveThreadTokenScan(
        threadID: "measured",
        rolloutPath: "/rollout/first.jsonl",
        fileSize: 600,
        fileModificationTimeNS: 700,
        parserVersion: 1,
        result: tokenScanResult(
            offset: 550,
            maximum: tokenUsage(125, 70, 40, 25, 165),
            dailyUsage: [secondDay: tokenUsage(25, 10, 10, 5, 35)],
            latestEventTimestamp: 1_752_560_000
        ),
        rebuild: false
    )

    #expect(
        try await store.loadThreadTokenCache()["measured"]
            == ThreadTokenCache(
                threadID: "measured",
                rolloutPath: "/rollout/first.jsonl",
                fileSize: 600,
                fileModificationTimeNS: 700,
                scannedOffset: 550,
                maximum: tokenUsage(125, 70, 40, 25, 165),
                latestEventTimestamp: 1_752_560_000,
                parserVersion: 1
            ))
    #expect(
        try await store.loadThreadTokenDailyUsage() == [
            ThreadTokenDailyUsage(
                threadID: "measured",
                dayStart: firstDay,
                usage: tokenUsage(40, 30, 10, 5, 50)
            ),
            ThreadTokenDailyUsage(
                threadID: "measured",
                dayStart: secondDay,
                usage: tokenUsage(85, 40, 30, 20, 115)
            ),
        ])

    try await store.saveThreadTokenScan(
        threadID: "measured",
        rolloutPath: "/rollout/rebuilt.jsonl",
        fileSize: 200,
        fileModificationTimeNS: 800,
        parserVersion: 2,
        result: tokenScanResult(
            offset: 190,
            maximum: tokenUsage(10, 4, 3, 2, 13),
            dailyUsage: [secondDay: tokenUsage(10, 4, 3, 2, 13)],
            latestEventTimestamp: 1_752_570_000
        ),
        rebuild: true
    )

    #expect(
        try await store.loadThreadTokenCache()["measured"]
            == ThreadTokenCache(
                threadID: "measured",
                rolloutPath: "/rollout/rebuilt.jsonl",
                fileSize: 200,
                fileModificationTimeNS: 800,
                scannedOffset: 190,
                maximum: tokenUsage(10, 4, 3, 2, 13),
                latestEventTimestamp: 1_752_570_000,
                parserVersion: 2
            ))
    #expect(
        try await store.loadThreadTokenDailyUsage() == [
            ThreadTokenDailyUsage(
                threadID: "measured",
                dayStart: secondDay,
                usage: tokenUsage(10, 4, 3, 2, 13)
            )
        ])
}

@Test func tokenTimedUsageFiltersExactBoundariesAndRebuildsPerThread() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let databaseURL = directory.appendingPathComponent("manager.sqlite")
    let store = try MetadataStore(databaseURL: databaseURL)
    let beforeBoundary: Int64 = 1_768_700_691
    let boundary: Int64 = 1_768_700_692
    let later: Int64 = 1_768_700_700

    try await store.saveThreadTokenScan(
        threadID: "measured",
        rolloutPath: "/rollout/measured.jsonl",
        fileSize: 300,
        fileModificationTimeNS: 400,
        parserVersion: 2,
        result: tokenScanResult(
            offset: 250,
            maximum: tokenUsage(30, 12, 8, 4, 38),
            dailyUsage: [
                1_768_694_400: tokenUsage(30, 12, 8, 4, 38)
            ],
            timedUsage: [
                beforeBoundary: tokenUsage(10, 4, 2, 1, 12),
                boundary: tokenUsage(20, 8, 6, 3, 26),
            ],
            latestEventTimestamp: boundary
        ),
        rebuild: false
    )
    try await store.saveThreadTokenScan(
        threadID: "other",
        rolloutPath: "/rollout/other.jsonl",
        fileSize: 100,
        fileModificationTimeNS: 200,
        parserVersion: 2,
        result: tokenScanResult(
            offset: 90,
            maximum: tokenUsage(5, 2, 1, 0, 6),
            dailyUsage: [1_768_694_400: tokenUsage(5, 2, 1, 0, 6)],
            timedUsage: [boundary: tokenUsage(5, 2, 1, 0, 6)],
            latestEventTimestamp: boundary
        ),
        rebuild: false
    )

    #expect(
        try await store.loadThreadTokenTimedUsage(startingAt: boundary, endingAt: boundary) == [
            ThreadTokenTimedUsage(
                threadID: "measured",
                eventAt: boundary,
                usage: tokenUsage(20, 8, 6, 3, 26)
            ),
            ThreadTokenTimedUsage(
                threadID: "other",
                eventAt: boundary,
                usage: tokenUsage(5, 2, 1, 0, 6)
            ),
        ])

    try await store.saveThreadTokenScan(
        threadID: "measured",
        rolloutPath: "/rollout/rebuilt.jsonl",
        fileSize: 150,
        fileModificationTimeNS: 500,
        parserVersion: 2,
        result: tokenScanResult(
            offset: 140,
            maximum: tokenUsage(7, 3, 2, 1, 9),
            dailyUsage: [1_768_694_400: tokenUsage(7, 3, 2, 1, 9)],
            timedUsage: [later: tokenUsage(7, 3, 2, 1, 9)],
            latestEventTimestamp: later
        ),
        rebuild: true
    )

    #expect(
        try await store.loadThreadTokenTimedUsage(
            startingAt: beforeBoundary,
            endingAt: later
        ) == [
            ThreadTokenTimedUsage(
                threadID: "measured",
                eventAt: later,
                usage: tokenUsage(7, 3, 2, 1, 9)
            ),
            ThreadTokenTimedUsage(
                threadID: "other",
                eventAt: boundary,
                usage: tokenUsage(5, 2, 1, 0, 6)
            ),
        ])

    var database: OpaquePointer?
    #expect(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    guard let database else { return }
    defer { sqlite3_close(database) }
    #expect(
        tableColumns("thread_token_daily", in: database) == [
            "thread_id", "day_start", "input_tokens", "cached_input_tokens",
            "output_tokens", "reasoning_output_tokens", "total_tokens",
        ])
    #expect(
        tableColumns("thread_token_timed", in: database) == [
            "thread_id", "event_at", "input_tokens", "cached_input_tokens",
            "output_tokens", "reasoning_output_tokens", "total_tokens",
        ])
}

@Test func v012TokenSchemaUpgradesAdditivelyAndRemainsLegacyReadable() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let databaseURL = directory.appendingPathComponent("manager.sqlite")
    try executeSQLite(
        """
        CREATE TABLE thread_token_usage (
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
        CREATE TABLE thread_token_daily (
          thread_id TEXT NOT NULL,
          day_start INTEGER NOT NULL,
          input_tokens INTEGER NOT NULL,
          cached_input_tokens INTEGER NOT NULL,
          output_tokens INTEGER NOT NULL,
          reasoning_output_tokens INTEGER NOT NULL,
          total_tokens INTEGER NOT NULL,
          PRIMARY KEY (thread_id, day_start)
        );
        INSERT INTO thread_token_usage VALUES
          ('legacy', '/rollout/legacy.jsonl', 200, 300, 180, 40, 30, 10, 5, 50, 400, 1);
        INSERT INTO thread_token_daily VALUES
          ('legacy', 100, 40, 30, 10, 5, 50);
        """,
        at: databaseURL
    )

    let store = try MetadataStore(databaseURL: databaseURL)
    #expect(try await store.loadThreadTokenCache()["legacy"]?.maximum.totalTokens == 50)
    #expect(try await store.loadThreadTokenDailyUsage().map(\.usage.totalTokens) == [50])
    #expect(try await store.loadThreadTokenTimedUsage(startingAt: 0, endingAt: 1_000).isEmpty)

    var database: OpaquePointer?
    #expect(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    guard let database else { return }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    #expect(
        sqlite3_prepare_v2(
            database,
            """
            SELECT u.thread_id, u.total_tokens, d.day_start, d.total_tokens
            FROM thread_token_usage AS u
            JOIN thread_token_daily AS d ON d.thread_id = u.thread_id
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK
    )
    guard let statement else { return }
    defer { sqlite3_finalize(statement) }
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    #expect(String(cString: sqlite3_column_text(statement, 0)) == "legacy")
    #expect(sqlite3_column_int64(statement, 1) == 50)
    #expect(sqlite3_column_int64(statement, 2) == 100)
    #expect(sqlite3_column_int64(statement, 3) == 50)
    #expect(sqlite3_step(statement) == SQLITE_DONE)
}

@Test func tokenUsageCacheDoesNotFabricateUncoveredThreads() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = try MetadataStore(databaseURL: directory.appendingPathComponent("manager.sqlite"))

    #expect(try await store.loadThreadTokenCache().isEmpty)
    #expect(try await store.loadThreadTokenDailyUsage().isEmpty)
}

@Test func tokenUsageUnobservedAppendDoesNotCreateOrOverwriteCache() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = try MetadataStore(databaseURL: directory.appendingPathComponent("manager.sqlite"))
    let day: Int64 = 1_752_422_400

    try await store.saveThreadTokenScan(
        threadID: "uncovered",
        rolloutPath: "/rollout/empty.jsonl",
        fileSize: 100,
        fileModificationTimeNS: 200,
        parserVersion: 1,
        result: tokenScanResult(
            offset: 90,
            maximum: .zero,
            dailyUsage: [:],
            latestEventTimestamp: nil,
            observedCheckpoint: false
        ),
        rebuild: false
    )

    #expect(try await store.loadThreadTokenCache().isEmpty)
    #expect(try await store.loadThreadTokenDailyUsage().isEmpty)

    try await store.saveThreadTokenScan(
        threadID: "measured",
        rolloutPath: "/rollout/original.jsonl",
        fileSize: 300,
        fileModificationTimeNS: 400,
        parserVersion: 1,
        result: tokenScanResult(
            offset: 250,
            maximum: tokenUsage(10, 5, 2, 1, 12),
            dailyUsage: [day: tokenUsage(10, 5, 2, 1, 12)],
            latestEventTimestamp: 1_752_430_000
        ),
        rebuild: false
    )
    let originalCache = try await store.loadThreadTokenCache()
    let originalDailyUsage = try await store.loadThreadTokenDailyUsage()

    try await store.saveThreadTokenScan(
        threadID: "measured",
        rolloutPath: "/rollout/ignored.jsonl",
        fileSize: 500,
        fileModificationTimeNS: 600,
        parserVersion: 2,
        result: tokenScanResult(
            offset: 450,
            maximum: tokenUsage(99, 88, 77, 66, 176),
            dailyUsage: [day: tokenUsage(99, 88, 77, 66, 176)],
            latestEventTimestamp: 1_752_440_000,
            observedCheckpoint: false
        ),
        rebuild: false
    )

    #expect(try await store.loadThreadTokenCache() == originalCache)
    #expect(try await store.loadThreadTokenDailyUsage() == originalDailyUsage)
}

@Test func tokenUsageUnobservedRebuildRemovesExistingCache() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = try MetadataStore(databaseURL: directory.appendingPathComponent("manager.sqlite"))

    try await store.saveThreadTokenScan(
        threadID: "measured",
        rolloutPath: "/rollout/original.jsonl",
        fileSize: 300,
        fileModificationTimeNS: 400,
        parserVersion: 1,
        result: tokenScanResult(
            offset: 250,
            maximum: tokenUsage(10, 5, 2, 1, 12),
            dailyUsage: [1_752_422_400: tokenUsage(10, 5, 2, 1, 12)],
            latestEventTimestamp: 1_752_430_000
        ),
        rebuild: false
    )

    try await store.saveThreadTokenScan(
        threadID: "measured",
        rolloutPath: "/rollout/rebuilt.jsonl",
        fileSize: 100,
        fileModificationTimeNS: 500,
        parserVersion: 2,
        result: tokenScanResult(
            offset: 90,
            maximum: .zero,
            dailyUsage: [:],
            latestEventTimestamp: nil,
            observedCheckpoint: false
        ),
        rebuild: true
    )

    #expect(try await store.loadThreadTokenCache().isEmpty)
    #expect(try await store.loadThreadTokenDailyUsage().isEmpty)
}

@Test func tokenUsageScanRollsBackSummaryWhenDailyWriteFails() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let databaseURL = directory.appendingPathComponent("manager.sqlite")
    let store = try MetadataStore(databaseURL: databaseURL)
    let originalDay: Int64 = 1_752_422_400
    try await store.saveThreadTokenScan(
        threadID: "measured",
        rolloutPath: "/rollout/original.jsonl",
        fileSize: 100,
        fileModificationTimeNS: 200,
        parserVersion: 1,
        result: tokenScanResult(
            offset: 90,
            maximum: tokenUsage(10, 5, 2, 1, 12),
            dailyUsage: [originalDay: tokenUsage(10, 5, 2, 1, 12)],
            latestEventTimestamp: 1_752_430_000
        ),
        rebuild: false
    )
    let originalCache = try await store.loadThreadTokenCache()
    let originalDailyUsage = try await store.loadThreadTokenDailyUsage()
    try executeSQLite(
        """
        CREATE TRIGGER fail_token_daily
        BEFORE INSERT ON thread_token_daily
        BEGIN
          SELECT RAISE(ABORT, 'forced daily failure');
        END;
        """,
        at: databaseURL
    )

    do {
        try await store.saveThreadTokenScan(
            threadID: "measured",
            rolloutPath: "/rollout/rebuilt.jsonl",
            fileSize: 300,
            fileModificationTimeNS: 400,
            parserVersion: 2,
            result: tokenScanResult(
                offset: 250,
                maximum: tokenUsage(20, 10, 4, 2, 24),
                dailyUsage: [1_752_508_800: tokenUsage(20, 10, 4, 2, 24)],
                latestEventTimestamp: 1_752_520_000
            ),
            rebuild: true
        )
        Issue.record("Expected daily write failure")
    } catch {
        #expect(error is MetadataStoreError)
    }

    #expect(try await store.loadThreadTokenCache() == originalCache)
    #expect(try await store.loadThreadTokenDailyUsage() == originalDailyUsage)
}

@Test func quotaUsageSamplesKeepLatestCapturePerBucketAndOrderTheRequestedCycle() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = try MetadataStore(databaseURL: directory.appendingPathComponent("manager.sqlite"))
    let cycleResetsAt: Int64 = 1_784_678_400

    try await store.saveQuotaUsageSample(
        QuotaUsageSample(cycleResetsAt: cycleResetsAt, capturedAt: 1_784_600_500, usedPercent: 20))
    try await store.saveQuotaUsageSample(
        QuotaUsageSample(cycleResetsAt: cycleResetsAt, capturedAt: 1_784_600_900, usedPercent: 35))
    try await store.saveQuotaUsageSample(
        QuotaUsageSample(cycleResetsAt: cycleResetsAt, capturedAt: 1_784_600_700, usedPercent: 25))
    try await store.saveQuotaUsageSample(
        QuotaUsageSample(cycleResetsAt: cycleResetsAt, capturedAt: 1_784_601_000, usedPercent: 50))
    try await store.saveQuotaUsageSample(
        QuotaUsageSample(
            cycleResetsAt: cycleResetsAt + 604_800,
            capturedAt: 1_784_600_200,
            usedPercent: 75
        ))

    #expect(
        try await store.loadQuotaUsageSamples(cycleResetsAt: cycleResetsAt) == [
            QuotaUsageSample(
                cycleResetsAt: cycleResetsAt, capturedAt: 1_784_600_900, usedPercent: 35),
            QuotaUsageSample(
                cycleResetsAt: cycleResetsAt, capturedAt: 1_784_601_000, usedPercent: 50),
        ])
}

@Test func quotaUsageSamplesRejectInvalidValuesAndClampPercentages() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = try MetadataStore(databaseURL: directory.appendingPathComponent("manager.sqlite"))
    let cycleResetsAt: Int64 = 1_784_678_400

    await #expect(throws: MetadataStoreError.invalidQuotaUsageSample) {
        try await store.saveQuotaUsageSample(
            QuotaUsageSample(cycleResetsAt: 0, capturedAt: 1_784_600_000, usedPercent: 10))
    }
    await #expect(throws: MetadataStoreError.invalidQuotaUsageSample) {
        try await store.saveQuotaUsageSample(
            QuotaUsageSample(cycleResetsAt: cycleResetsAt, capturedAt: 0, usedPercent: 10))
    }
    await #expect(throws: MetadataStoreError.invalidQuotaUsageSample) {
        try await store.saveQuotaUsageSample(
            QuotaUsageSample(
                cycleResetsAt: cycleResetsAt,
                capturedAt: 1_784_600_000,
                usedPercent: .nan
            ))
    }
    await #expect(throws: MetadataStoreError.invalidQuotaUsageSample) {
        try await store.saveQuotaUsageSample(
            QuotaUsageSample(
                cycleResetsAt: cycleResetsAt,
                capturedAt: 1_784_600_000,
                usedPercent: .infinity
            ))
    }

    try await store.saveQuotaUsageSample(
        QuotaUsageSample(cycleResetsAt: cycleResetsAt, capturedAt: 1_784_600_000, usedPercent: -5))
    try await store.saveQuotaUsageSample(
        QuotaUsageSample(cycleResetsAt: cycleResetsAt, capturedAt: 1_784_600_600, usedPercent: 120))

    #expect(
        try await store.loadQuotaUsageSamples(cycleResetsAt: cycleResetsAt) == [
            QuotaUsageSample(
                cycleResetsAt: cycleResetsAt, capturedAt: 1_784_600_000, usedPercent: 0),
            QuotaUsageSample(
                cycleResetsAt: cycleResetsAt, capturedAt: 1_784_600_600, usedPercent: 100),
        ])
}

@Test func quotaUsageSchemaIsAddedWithoutLosingExistingMetadata() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let databaseURL = directory.appendingPathComponent("manager.sqlite")
    try executeSQLite(
        """
        CREATE TABLE thread_meta (
          thread_id TEXT PRIMARY KEY,
          is_favorite INTEGER NOT NULL DEFAULT 0,
          collection_id TEXT
        );
        INSERT INTO thread_meta (thread_id, is_favorite) VALUES ('existing', 1);
        """,
        at: databaseURL
    )

    let store = try MetadataStore(databaseURL: databaseURL)
    let cycleResetsAt: Int64 = 1_784_678_400
    try await store.saveQuotaUsageSample(
        QuotaUsageSample(cycleResetsAt: cycleResetsAt, capturedAt: 1_784_600_000, usedPercent: 25))

    #expect(
        try await store.loadMetadata()["existing"]
            == ThreadMetadata(threadID: "existing", isFavorite: true, collectionID: nil))
    #expect(
        try await store.loadQuotaUsageSamples(cycleResetsAt: cycleResetsAt)
            == [
                QuotaUsageSample(
                    cycleResetsAt: cycleResetsAt,
                    capturedAt: 1_784_600_000,
                    usedPercent: 25
                )
            ])
}

private func tokenUsage(
    _ inputTokens: Int64,
    _ cachedInputTokens: Int64,
    _ outputTokens: Int64,
    _ reasoningOutputTokens: Int64,
    _ totalTokens: Int64
) -> TokenUsageBreakdown {
    TokenUsageBreakdown(
        inputTokens: inputTokens,
        cachedInputTokens: cachedInputTokens,
        outputTokens: outputTokens,
        reasoningOutputTokens: reasoningOutputTokens,
        totalTokens: totalTokens
    )
}

private func tokenScanResult(
    offset: Int64,
    maximum: TokenUsageBreakdown,
    dailyUsage: [Int64: TokenUsageBreakdown],
    timedUsage: [Int64: TokenUsageBreakdown] = [:],
    latestEventTimestamp: Int64?,
    observedCheckpoint: Bool = true
) -> TokenScanResult {
    TokenScanResult(
        offset: offset,
        state: TokenScanState(
            maximum: maximum,
            dailyUsage: dailyUsage,
            timedUsage: timedUsage,
            latestEventTimestamp: latestEventTimestamp,
            observedCheckpoint: observedCheckpoint
        )
    )
}

private func executeSQLite(_ sql: String, at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
        throw MetadataStoreError.sqlite("Unable to open test database")
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw MetadataStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
}

private func tableColumns(_ table: String, in database: OpaquePointer) -> Set<String> {
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
