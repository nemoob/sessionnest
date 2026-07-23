import Foundation
import Testing

@testable import SessionNest

@Suite("SessionPerformanceBenchmarkTests", .serialized)
struct SessionPerformanceBenchmarkTests {
    @Test func tokenScannerProcessesTwentyThousandCheckpointsWithinBudget() throws {
        let checkpointCount = 20_000
        let data = syntheticRollout(checkpointCount: checkpointCount)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionNestBenchmark-\(UUID().uuidString)")
            .appendingPathExtension("jsonl")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let clock = ContinuousClock()
        let startedAt = clock.now
        let result = try RolloutTokenScanner.scan(url: url, calendar: utcCalendar)
        let elapsed = startedAt.duration(to: clock.now)

        print(
            "SessionNest benchmark: scanned \(checkpointCount) checkpoints "
                + "(\(data.count) bytes) in \(elapsed)"
        )
        #expect(result.offset == Int64(data.count))
        #expect(result.maximum.totalTokens == Int64(checkpointCount))
        #expect(
            result.dailyUsage.values.reduce(.zero, +).totalTokens
                == Int64(checkpointCount)
        )
        #expect(elapsed < .seconds(5))
    }

    @Test func tokenScannerProcessesSixteenMegabyteLineWithinBudget() throws {
        // 构造与真实 compacted 日志同量级的超长单行，覆盖跨越多个 64 KiB 块的场景。
        var data = Data(repeating: 0x61, count: 16 * 1024 * 1024)
        // 用换行提交无效长行，随后追加一个可校验的完整 Token 检查点。
        data.append(0x0A)
        data.append(
            Data(
                (#"{"timestamp":"2026-07-20T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":8,"cached_input_tokens":3,"output_tokens":2,"reasoning_output_tokens":1,"total_tokens":10}}}}"#
                    + "\n").utf8
            ))
        // 使用独立临时文件，测试结束后不保留大文件。
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionNestLongLineBenchmark-\(UUID().uuidString)")
            .appendingPathExtension("jsonl")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // 记录扫描耗时，防止未来重新引入按块从缓冲区头部搜索的平方级退化。
        let clock = ContinuousClock()
        let startedAt = clock.now
        let result = try RolloutTokenScanner.scan(url: url, calendar: utcCalendar)
        let elapsed = startedAt.duration(to: clock.now)

        print("SessionNest long-line benchmark: scanned \(data.count) bytes in \(elapsed)")
        #expect(result.offset == Int64(data.count))
        #expect(result.maximum == tokenUsage(8, 3, 2, 1, 10))
        #expect(elapsed < .seconds(5))
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func syntheticRollout(checkpointCount: Int) -> Data {
        var lines = [
            #"{"timestamp":"2026-07-20T00:00:00Z","type":"session_meta","payload":{"id":"benchmark","cwd":"/synthetic"}}"#
        ]
        lines.reserveCapacity(checkpointCount + 1)
        lines.append(
            contentsOf: (1...checkpointCount).map { checkpoint in
                let cached = checkpoint / 2
                return
                    #"{"timestamp":"2026-07-20T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(checkpoint),"cached_input_tokens":\#(cached),"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\#(checkpoint)}}}}"#
            })
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func tokenUsage(
        _ input: Int64,
        _ cached: Int64,
        _ output: Int64,
        _ reasoning: Int64,
        _ total: Int64
    ) -> TokenUsageBreakdown {
        TokenUsageBreakdown(
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            totalTokens: total
        )
    }
}
