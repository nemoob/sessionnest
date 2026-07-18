import Foundation
import Testing

@testable import SessionNest

@Test func decodesThreadListResponse() throws {
    let data = Data(
        #"{"data":[{"id":"t1","name":"Title","preview":"Preview","cwd":"/tmp/repo","createdAt":1,"updatedAt":2,"recencyAt":3,"gitInfo":{"branch":"test","originUrl":"ssh://git@example.com/team/repo.git","sha":null}}],"nextCursor":null,"backwardsCursor":null}"#
            .utf8)
    let page = try JSONDecoder().decode(ThreadPage.self, from: data)
    #expect(page.data.count == 1)
    #expect(page.data[0].displayTitle == "Title")
    #expect(page.data[0].gitInfo?.originUrl == "ssh://git@example.com/team/repo.git")
    #expect(page.nextCursor == nil)
}

@Test func locatorUsesFirstExecutableCandidate() {
    let a = URL(fileURLWithPath: "/first/codex")
    let b = URL(fileURLWithPath: "/second/codex")
    let result = CodexExecutableLocator.resolve(candidates: [a, b]) { $0 == b.path }
    #expect(result == b)
}

@Test func readThreadEvidenceDecodesProjectSignals() async throws {
    let fake = try FakeCodex(
        scriptBody: """
            while IFS= read -r line; do
                printf '%s\\n' "$line" >> "$log"
                id="$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')"
                case "$line" in
                    *'"method":"initialize"'*)
                        printf '{"id":%s,"result":{}}\\n' "$id"
                        ;;
                    *'thread'*'read'*)
                        printf '{"id":%s,"result":{"thread":{"turns":[{"items":[{"type":"userMessage","content":[{"text":"Update sample-app"}]},{"type":"agentMessage","text":"Working on sample-api"},{"type":"commandExecution","cwd":"/work/codex/sample-api","commandActions":[{"path":"/work/codex/sample-api/Sources"}]},{"type":"fileChange","changes":[{"path":"/work/codex/sample-app/a.swift"}]},{"type":"unknown","cwd":"/ignored/cwd","text":"ignored text","content":"ignored content","changes":{"path":"/ignored/change"},"commandActions":["/ignored/action"]}]}]}}}\\n' "$id"
                        ;;
                esac
            done
            """)
    defer { fake.remove() }
    let client = try CodexClient(executableURL: fake.executableURL)
    defer { Task { await client.stop() } }

    try await client.start()
    let evidence = try await client.readThreadEvidence(threadID: "thread-1")
    await client.stop()

    #expect(
        evidence
            == ThreadProjectEvidence(
                filePaths: ["/work/codex/sample-app/a.swift"],
                commandWorkingDirectories: ["/work/codex/sample-api"],
                commandActionPaths: ["/work/codex/sample-api/Sources"],
                userMessages: ["Update sample-app"],
                agentMessages: ["Working on sample-api"]
            ))
    #expect(fake.log.replacingOccurrences(of: #"\/"#, with: "/").contains("thread/read"))
    #expect(fake.log.contains(#""includeTurns":true"#))
}

@Test func concurrentStartWaitsForSingleInitialization() async throws {
    let fake = try FakeCodex(
        scriptBody: """
            while IFS= read -r line; do
                printf '%s\\n' "$line" >> "$log"
                case "$line" in
                    *'"method":"initialize"'*)
                        sleep 0.2
                        : > "$marker"
                        id="$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')"
                        printf '{"id":%s,"result":{}}\\n' "$id"
                        ;;
                esac
            done
            """)
    defer { fake.remove() }
    let client = try CodexClient(executableURL: fake.executableURL)
    defer { Task { await client.stop() } }

    let first = Task { try await client.start() }
    try await waitUntil { fake.log.contains(#""method":"initialize""#) }
    let second = Task {
        try await client.start()
        return FileManager.default.fileExists(atPath: fake.markerURL.path)
    }

    let secondWaitedForInitialization = try await second.value
    try await first.value
    await client.stop()

    #expect(secondWaitedForInitialization)
    #expect(fake.log.components(separatedBy: #""method":"initialize""#).count - 1 == 1)
}

@Test func failedInitializationCleansUpAndCanRetry() async throws {
    let fake = try FakeCodex(
        scriptBody: """
            attempt=1
            if [ -f "$attempts" ]; then
                attempt=$(( $(cat "$attempts") + 1 ))
            fi
            printf '%s' "$attempt" > "$attempts"
            while IFS= read -r line; do
                printf '%s\\n' "$line" >> "$log"
                case "$line" in
                    *'"method":"initialize"'*)
                        id="$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')"
                        if [ "$attempt" -eq 1 ]; then
                            printf '{"id":%s,"error":{"message":"init failed"}}\\n' "$id"
                        else
                            printf '{"id":%s,"result":{}}\\n' "$id"
                        fi
                        ;;
                esac
            done
            """)
    defer { fake.remove() }
    let client = try CodexClient(executableURL: fake.executableURL)
    defer { Task { await client.stop() } }

    var firstStartFailed = false
    do {
        try await client.start()
    } catch {
        firstStartFailed = true
    }
    try await client.start()
    let attemptCount = fake.attempts
    await client.stop()

    #expect(firstStartFailed)
    #expect(attemptCount == "2")
}

@Test func responseEmittedImmediatelyBeforeExitIsDelivered() async throws {
    let fake = try FakeCodex(
        scriptBody: """
            while IFS= read -r line; do
                printf '%s\\n' "$line" >> "$log"
                case "$line" in
                    *'"method":"initialize"'*)
                        id="$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')"
                        printf '{"id":%s,"result":{}}\\n' "$id"
                        ;;
                    *'thread'*'list'*)
                        id="$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')"
                        printf '{"id":%s,"result":{"data":[{"id":"final","name":"Final","preview":"Preview","cwd":"/tmp/repo","createdAt":1,"updatedAt":2,"recencyAt":3,"gitInfo":null}],"nextCursor":null,"backwardsCursor":null}}\\n' "$id"
                        exit 0
                        ;;
                esac
            done
            """)
    defer { fake.remove() }
    let client = try CodexClient(executableURL: fake.executableURL)
    defer { Task { await client.stop() } }

    try await client.start()
    let threads = try await client.listThreads(archived: false, searchTerm: nil)
    await client.stop()

    #expect(threads.map(\.id) == ["final"])
}

@Test func stoppedProcessErrorIncludesDrainedStderrTail() async throws {
    let fake = try FakeCodex(
        scriptBody: """
            while IFS= read -r line; do
                case "$line" in
                    *'"method":"initialize"'*)
                        id="$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')"
                        printf '{"id":%s,"result":{}}\\n' "$id"
                        ;;
                    *'thread'*'list'*)
                        printf 'fatal-tail-marker\\n' >&2
                        exit 23
                        ;;
                esac
            done
            """)
    defer { fake.remove() }
    let client = try CodexClient(executableURL: fake.executableURL)
    defer { Task { await client.stop() } }

    try await client.start()
    var message = ""
    do {
        _ = try await client.listThreads(archived: false, searchTerm: nil)
    } catch {
        message = error.localizedDescription
    }
    await client.stop()

    #expect(message.contains("fatal-tail-marker"))
}

@Test func archiveUnarchiveAndRateLimitRequestsAcceptResponses() async throws {
    let fake = try FakeCodex(
        scriptBody: """
            while IFS= read -r line; do
                printf '%s\\n' "$line" >> "$log"
                id="$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')"
                case "$line" in
                    *'"method":"initialize"'*)
                        printf '{"id":%s,"result":{}}\\n' "$id"
                        ;;
                    *'thread'*'archive'*)
                        printf '{"id":%s,"result":{}}\\n' "$id"
                        ;;
                    *'account'*'rateLimits'*'read'*)
                        printf '{"id":%s,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":52,"windowDurationMins":10080,"resetsAt":1784508042},"secondary":null,"credits":null,"individualLimit":null,"planType":"pro","rateLimitReachedType":null}}}\\n' "$id"
                        ;;
                esac
            done
            """)
    defer { fake.remove() }
    let client = try CodexClient(executableURL: fake.executableURL)
    defer { Task { await client.stop() } }

    try await client.start()
    try await client.archive(threadID: "thread-1")
    try await client.unarchive(threadID: "thread-1")
    let snapshot = try await client.readRateLimits()
    await client.stop()

    #expect(snapshot.weeklyWindow?.usedPercent == 52)
    #expect(snapshot.weeklyWindow?.remainingPercent == 48)
    #expect(snapshot.weeklyWindow?.resetsAt == 1_784_508_042)
    #expect(fake.log.contains("account"))
    #expect(fake.log.contains("rateLimits"))
    #expect(fake.log.contains(#"thread\/archive"#))
    #expect(fake.log.contains(#"thread\/unarchive"#))
}

@Test func readsRateLimitsAndResetCreditsAsOneUsageSnapshot() async throws {
    let fake = try FakeCodex(
        scriptBody: """
            while IFS= read -r line; do
                id="$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')"
                case "$line" in
                    *'"method":"initialize"'*)
                        printf '{"id":%s,"result":{}}\\n' "$id"
                        ;;
                    *'account'*'rateLimits'*'read'*)
                        printf '{"id":%s,"result":{"rateLimits":{"primary":{"usedPercent":8,"windowDurationMins":10080,"resetsAt":1784949892},"planType":"pro"},"rateLimitResetCredits":{"availableCount":3,"credits":[{"id":"credit-2","resetType":"codexRateLimits","status":"available","grantedAt":1782935481,"expiresAt":1785527481,"title":"Full reset","description":"Second"},{"id":"credit-1","resetType":"codexRateLimits","status":"available","grantedAt":1782517319,"expiresAt":1785109319,"title":"Full reset","description":"First"}]}}}\\n' "$id"
                        ;;
                esac
            done
            """
    )
    defer { fake.remove() }
    let client = try CodexClient(executableURL: fake.executableURL)
    defer { Task { await client.stop() } }

    try await client.start()
    let usage = try await client.readUsageSnapshot()
    await client.stop()

    #expect(usage.rateLimits.weeklyWindow?.usedPercent == 8)
    #expect(usage.resetCredits?.availableCount == 3)
    #expect(usage.resetCredits?.credits.map(\.id) == ["credit-2", "credit-1"])
    #expect(usage.resetCredits?.credits[0].expiresAt == 1_785_527_481)
    #expect(usage.resetCredits?.credits[0].description == "Second")
}

@Test func usageSnapshotKeepsMissingResetCreditsUnknown() throws {
    let usage = try JSONDecoder().decode(
        CodexUsageSnapshot.self,
        from: Data(
            #"{"rateLimits":{"primary":{"usedPercent":8,"windowDurationMins":10080}}}"#
                .utf8
        )
    )

    #expect(usage.resetCredits == nil)
}

@Test func readsChatGPTAccountIdentity() async throws {
    let fake = try FakeCodex(
        scriptBody: """
            while IFS= read -r line; do
                printf '%s\\n' "$line" >> "$log"
                id="$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')"
                case "$line" in
                    *'"method":"initialize"'*)
                        printf '{"id":%s,"result":{}}\\n' "$id"
                        ;;
                    *'account'*'read'*)
                        printf '{"id":%s,"result":{"account":{"type":"chatgpt","email":"person@example.com","planType":"pro"},"requiresOpenaiAuth":true}}\\n' "$id"
                        ;;
                esac
            done
            """)
    defer { fake.remove() }
    let client = try CodexClient(executableURL: fake.executableURL)
    defer { Task { await client.stop() } }

    try await client.start()
    let account = try await client.readAccount()
    await client.stop()

    #expect(account?.type == "chatgpt")
    #expect(account?.email == "person@example.com")
    #expect(account?.planType == "pro")
    #expect(fake.log.contains(#"account\/read"#))
}

@Test func decodesAccountWithoutChatGPTFields() throws {
    let data = Data(#"{"type":"apiKey"}"#.utf8)
    let account = try JSONDecoder().decode(CodexAccountSnapshot.self, from: data)

    #expect(account.type == "apiKey")
    #expect(account.email == nil)
    #expect(account.planType == nil)
}

@Test func selectsSecondaryWeeklyRateLimitAndClampsRemainder() throws {
    let data = Data(
        #"{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1},"secondary":{"usedPercent":130,"windowDurationMins":10080,"resetsAt":2}}"#
            .utf8
    )
    let snapshot = try JSONDecoder().decode(CodexRateLimitSnapshot.self, from: data)

    #expect(snapshot.weeklyWindow?.resetsAt == 2)
    #expect(snapshot.weeklyWindow?.remainingPercent == 0)
}

@Test func selectsWeeklyRateLimitWindowFromSecondary() throws {
    let data = Data(
        #"{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":11},"secondary":{"usedPercent":52,"windowDurationMins":10080,"resetsAt":22}}"#
            .utf8
    )
    let snapshot = try JSONDecoder().decode(CodexRateLimitSnapshot.self, from: data)

    #expect(snapshot.weeklyWindow?.resetsAt == 22)
    #expect(snapshot.weeklyWindow?.remainingPercent == 48)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_INTEGRATION"] == "1"))
func liveClientListsThreadsAndRateLimits() async throws {
    let client = try CodexClient()
    defer { Task { await client.stop() } }
    try await client.start()
    let threads = try await client.listThreads(archived: false, searchTerm: nil)
    let rateLimits = try await client.readRateLimits()
    await client.stop()
    #expect(!threads.isEmpty)
    #expect(rateLimits.weeklyWindow != nil)
}

private struct FakeCodex {
    let directoryURL: URL
    let executableURL: URL
    let logURL: URL
    let markerURL: URL
    let attemptsURL: URL

    init(scriptBody: String) throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        self.directoryURL = directoryURL
        executableURL = directoryURL.appendingPathComponent("codex")
        logURL = directoryURL.appendingPathComponent("requests.log")
        markerURL = directoryURL.appendingPathComponent("initialized.marker")
        attemptsURL = directoryURL.appendingPathComponent("attempts")

        let script = """
            #!/bin/sh
            set -eu
            log=\(shellQuote(logURL.path))
            marker=\(shellQuote(markerURL.path))
            attempts=\(shellQuote(attemptsURL.path))
            \(scriptBody)
            """
        try Data(script.utf8).write(to: executableURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    }

    var log: String {
        (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }

    var attempts: String {
        (try? String(contentsOf: attemptsURL, encoding: .utf8)) ?? ""
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private enum FakeCodexTestError: Error {
    case timedOut
}

private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<1_000 {
        if condition() { return }
        try await ContinuousClock().sleep(for: .milliseconds(10))
    }
    throw FakeCodexTestError.timedOut
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}
