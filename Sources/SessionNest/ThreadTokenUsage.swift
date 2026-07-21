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

enum LocalTokenScanTargetDiscovery {
    static func discover(
        threads: [CodexThread],
        roots: [URL] = defaultRoots(),
        fileManager: FileManager = .default
    ) -> [TokenScanTarget] {
        let visibleThreadIDs = Set(threads.map(\.id))
        var targets = Dictionary(
            uniqueKeysWithValues: threads.compactMap { thread -> (String, TokenScanTarget)? in
                guard let path = thread.path else { return nil }
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
        var subagents: [String: (parentID: String, url: URL)] = [:]
        let normalizedRoots = roots.map { $0.standardizedFileURL.path }
        let hasThreadInRoots = targets.values.contains { target in
            let path = target.url.standardizedFileURL.path
            return normalizedRoots.contains { root in
                path == root || path.hasPrefix(root + "/")
            }
        }

        for root in roots where hasThreadInRoots {
            guard
                let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
                guard let metadata = subagentMetadata(at: url) else { continue }
                subagents[metadata.id] = (metadata.parentID, url)
            }
        }

        for (id, subagent) in subagents {
            var parentID = subagent.parentID
            var visited: Set<String> = [id]
            while !visibleThreadIDs.contains(parentID),
                let parent = subagents[parentID],
                visited.insert(parentID).inserted
            {
                parentID = parent.parentID
            }
            guard visibleThreadIDs.contains(parentID) else { continue }
            targets[id] = TokenScanTarget(
                id: id,
                attributionThreadID: parentID,
                url: subagent.url
            )
        }

        return targets.values.sorted { $0.id > $1.id }
    }

    private static func defaultRoots() -> [URL] {
        let environment = ProcessInfo.processInfo.environment
        let codexHome =
            environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return [
            codexHome.appendingPathComponent("sessions", isDirectory: true),
            codexHome.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
    }

    private static func subagentMetadata(at url: URL) -> (id: String, parentID: String)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024) else { return nil }

        for line in data.split(separator: 0x0A, maxSplits: 32) {
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
            return (id, parentID)
        }
        return nil
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
        var buffer = Data()
        var offset = fromOffset

        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if isCancelled() { throw CancellationError() }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                offset += Int64(buffer.distance(from: buffer.startIndex, to: newline) + 1)
                buffer.removeSubrange(buffer.startIndex...newline)
                scan(line: line, state: &state, phase: &phase, calendar: calendar)
            }
        }

        return TokenScanResult(offset: offset, state: state)
    }

    private static func scan(
        line: Data,
        state: inout TokenScanState,
        phase: inout ScanPhase,
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

        let delta = usage.positiveDelta(from: state.maximum)
        let timestampSeconds = Int64(timestamp.timeIntervalSince1970.rounded(.down))
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
