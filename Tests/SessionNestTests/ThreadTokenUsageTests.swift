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
