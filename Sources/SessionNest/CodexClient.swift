import Foundation

struct ThreadPage: Decodable, Sendable {
    let data: [CodexThread]
    let nextCursor: String?
}

struct CodexAccountSnapshot: Decodable, Equatable, Sendable {
    let type: String
    let email: String?
    let planType: String?
}

struct CodexRateLimitSnapshot: Decodable, Equatable, Sendable {
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
    let planType: String?

    var weeklyWindow: CodexRateLimitWindow? {
        [primary, secondary]
            .compactMap { $0 }
            .first { $0.windowDurationMins == 10_080 }
    }
}

struct CodexRateLimitWindow: Decodable, Equatable, Sendable {
    let usedPercent: Double
    let windowDurationMins: Int64?
    let resetsAt: Int64?

    var remainingPercent: Int {
        min(100, max(0, Int((100 - usedPercent).rounded())))
    }
}

enum CodexClientError: LocalizedError, Sendable {
    case executableNotFound
    case processStopped(String)
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound: "找不到支持 App Server 的 Codex CLI"
        case .processStopped(let message): "Codex App Server 已停止：\(message)"
        case .invalidResponse: "Codex App Server 返回了无法识别的数据"
        case .server(let message): message
        }
    }
}

enum CodexExecutableLocator {
    static let defaultCandidates = [
        URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
        URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Codex.app/Contents/Resources/codex"),
    ]

    static func resolve(
        candidates: [URL] = defaultCandidates,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> URL? {
        candidates.first { isExecutable($0.path) }
    }
}

actor CodexClient {
    private let executableURL: URL
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?
    private var startTask: Task<Void, any Error>?
    private var isInitialized = false
    private var initializationAttempt = 0
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var nextRequestID = 1
    private var stderrTail = Data()
    private var runToken = 0
    private var stdoutReachedEOF = false
    private var stderrReachedEOF = false
    private var terminationReason: String?

    init(executableURL: URL? = CodexExecutableLocator.resolve()) throws {
        guard let executableURL else {
            throw CodexClientError.executableNotFound
        }
        self.executableURL = executableURL
    }

    func start() async throws {
        if isInitialized { return }

        let task: Task<Void, any Error>
        let attempt: Int
        if let existingTask = startTask {
            task = existingTask
            attempt = initializationAttempt
        } else {
            initializationAttempt += 1
            attempt = initializationAttempt
            task = Task {
                try await self.startProcessAndInitialize(attempt: attempt)
            }
            startTask = task
        }

        do {
            try await task.value
            if initializationAttempt == attempt {
                startTask = nil
            }
        } catch {
            if initializationAttempt == attempt {
                startTask = nil
            }
            throw error
        }
    }

    private func startProcessAndInitialize(attempt: Int) async throws {
        do {
            try Task.checkCancellation()

            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            runToken += 1
            let token = runToken

            process.executableURL = executableURL
            process.arguments = ["app-server", "--listen", "stdio://"]
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                Task {
                    await self?.processTerminated(token: token, reason: "进程已退出（状态 \(status)）")
                }
            }

            self.process = process
            self.inputPipe = inputPipe
            self.outputPipe = outputPipe
            self.errorPipe = errorPipe
            stderrTail.removeAll(keepingCapacity: true)
            stdoutReachedEOF = false
            stderrReachedEOF = false
            terminationReason = nil

            try process.run()

            startReaders(
                output: outputPipe.fileHandleForReading,
                error: errorPipe.fileHandleForReading,
                token: token
            )

            let _: EmptyResult = try await request(
                method: "initialize",
                params: InitializeParams(),
                result: EmptyResult.self
            )
            try sendInitializedNotification()
            try Task.checkCancellation()
            guard initializationAttempt == attempt else { throw CancellationError() }
            isInitialized = true
        } catch {
            if initializationAttempt == attempt {
                abortCurrentProcess(failingWith: error)
            }
            throw error
        }
    }

    func readRateLimits() async throws -> CodexRateLimitSnapshot {
        let params: String? = nil
        let result = try await request(
            method: "account/rateLimits/read",
            params: params,
            result: RateLimitsReadResult.self
        )
        return result.rateLimits
    }

    func readAccount() async throws -> CodexAccountSnapshot? {
        let result = try await request(
            method: "account/read",
            params: AccountReadParams(refreshToken: false),
            result: AccountReadResult.self
        )
        return result.account
    }

    func listThreads(archived: Bool, searchTerm: String?) async throws -> [CodexThread] {
        var threads: [CodexThread] = []
        var cursor: String?

        repeat {
            let page = try await request(
                method: "thread/list",
                params: ThreadListParams(
                    archived: archived, cursor: cursor, searchTerm: searchTerm),
                result: ThreadPage.self
            )
            threads.append(contentsOf: page.data)
            cursor = page.nextCursor
        } while cursor != nil

        return threads
    }

    func readThreadEvidence(threadID: String) async throws -> ThreadProjectEvidence {
        let result = try await request(
            method: "thread/read",
            params: ThreadReadParams(threadId: threadID),
            result: ThreadReadResult.self
        )
        var evidence = ThreadProjectEvidence.empty
        for item in result.thread.turns.flatMap(\.items) {
            evidence.add(item)
        }
        return evidence
    }

    func archive(threadID: String) async throws {
        let _: EmptyResult = try await request(
            method: "thread/archive",
            params: ThreadIDParams(threadId: threadID),
            result: EmptyResult.self
        )
    }

    func unarchive(threadID: String) async throws {
        let _: EmptyResult = try await request(
            method: "thread/unarchive",
            params: ThreadIDParams(threadId: threadID),
            result: EmptyResult.self
        )
    }

    func stop() {
        let stoppedError = CodexClientError.processStopped(stoppedMessage(reason: "已主动停止"))
        initializationAttempt += 1
        startTask?.cancel()
        startTask = nil
        abortCurrentProcess(failingWith: stoppedError)
    }

    private func startReaders(output: FileHandle, error: FileHandle, token: Int) {
        outputTask = Task.detached { [weak self] in
            var buffer = Data()
            while !Task.isCancelled {
                let chunk = output.availableData
                guard !chunk.isEmpty else { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if !line.isEmpty {
                        await self?.handleResponseLine(line, token: token)
                    }
                }
            }
            await self?.stdoutFinished(token: token)
        }

        errorTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                let chunk = error.availableData
                guard !chunk.isEmpty else { break }
                await self?.appendStderr(chunk, token: token)
            }
            await self?.stderrFinished(token: token)
        }
    }

    private func request<Params: Encodable, Result: Decodable>(
        method: String,
        params: Params,
        result: Result.Type
    ) async throws -> Result {
        guard let input = inputPipe?.fileHandleForWriting, process?.isRunning == true else {
            throw CodexClientError.processStopped(stoppedMessage(reason: "进程未运行"))
        }

        let id = nextRequestID
        nextRequestID += 1
        var payload = try JSONEncoder().encode(
            RequestMessage(id: id, method: method, params: params))
        payload.append(0x0A)

        let responseData = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, any Error>) in
            pending[id] = continuation
            do {
                try input.write(contentsOf: payload)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }

        do {
            return try JSONDecoder().decode(result, from: responseData)
        } catch {
            throw CodexClientError.invalidResponse
        }
    }

    private func sendInitializedNotification() throws {
        guard let input = inputPipe?.fileHandleForWriting, process?.isRunning == true else {
            throw CodexClientError.processStopped(stoppedMessage(reason: "进程未运行"))
        }
        var payload = try JSONEncoder().encode(NotificationMessage(method: "initialized"))
        payload.append(0x0A)
        try input.write(contentsOf: payload)
    }

    private func handleResponseLine(_ data: Data, token: Int) {
        guard token == runToken,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = (object["id"] as? NSNumber)?.intValue
        else {
            return
        }
        guard let continuation = pending.removeValue(forKey: id) else { return }

        if let error = object["error"] as? [String: Any] {
            let message =
                error["message"] as? String ?? CodexClientError.invalidResponse.localizedDescription
            continuation.resume(throwing: CodexClientError.server(message))
            return
        }
        guard let result = object["result"], JSONSerialization.isValidJSONObject(result),
            let resultData = try? JSONSerialization.data(withJSONObject: result)
        else {
            continuation.resume(throwing: CodexClientError.invalidResponse)
            return
        }
        continuation.resume(returning: resultData)
    }

    private func appendStderr(_ data: Data, token: Int) {
        guard token == runToken else { return }
        stderrTail.append(data)
        if stderrTail.count > 8_192 {
            stderrTail.removeFirst(stderrTail.count - 8_192)
        }
    }

    private func processTerminated(token: Int, reason: String) {
        guard token == runToken else { return }
        terminationReason = reason
        finishStoppedProcessIfDrained(token: token)
    }

    private func stdoutFinished(token: Int) {
        guard token == runToken else { return }
        stdoutReachedEOF = true
        if process?.isRunning == true {
            process?.terminate()
        }
        finishStoppedProcessIfDrained(token: token)
    }

    private func stderrFinished(token: Int) {
        guard token == runToken else { return }
        stderrReachedEOF = true
        finishStoppedProcessIfDrained(token: token)
    }

    private func finishStoppedProcessIfDrained(token: Int) {
        guard token == runToken,
            stdoutReachedEOF,
            stderrReachedEOF,
            let terminationReason
        else { return }
        let error = CodexClientError.processStopped(stoppedMessage(reason: terminationReason))
        failPending(with: error)
        isInitialized = false
        clearProcessState()
    }

    private func abortCurrentProcess(failingWith error: any Error) {
        let runningProcess = process
        runToken += 1
        failPending(with: error)
        isInitialized = false
        if runningProcess?.isRunning == true {
            runningProcess?.terminate()
        }
        clearProcessState()
    }

    private func stoppedMessage(reason: String) -> String {
        let tail = String(decoding: stderrTail, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? reason : "\(reason)\n\(tail)"
    }

    private func failPending(with error: any Error) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func clearProcessState() {
        outputTask?.cancel()
        errorTask?.cancel()
        try? inputPipe?.fileHandleForWriting.close()
        try? outputPipe?.fileHandleForReading.close()
        try? errorPipe?.fileHandleForReading.close()
        outputTask = nil
        errorTask = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        process = nil
    }
}

private struct InitializeParams: Encodable {
    let clientInfo = ClientInfo(name: "sessionnest", title: "SessionNest", version: "0.1.0")
    let capabilities = Capabilities(experimentalApi: false)
}

private struct ClientInfo: Encodable {
    let name: String
    let title: String
    let version: String
}

private struct Capabilities: Encodable {
    let experimentalApi: Bool
}

private struct ThreadIDParams: Encodable {
    let threadId: String
}

private struct RateLimitsReadResult: Decodable {
    let rateLimits: CodexRateLimitSnapshot
}

private struct AccountReadParams: Encodable {
    let refreshToken: Bool
}

private struct AccountReadResult: Decodable {
    let account: CodexAccountSnapshot?
}

private struct ThreadReadParams: Encodable {
    let threadId: String
    let includeTurns = true
}

private struct ThreadReadResult: Decodable {
    let thread: ThreadReadThread
}

private struct ThreadReadThread: Decodable {
    let turns: [ThreadReadTurn]
}

private struct ThreadReadTurn: Decodable {
    let items: [ThreadReadItem]
}

private struct ThreadReadItem: Decodable {
    let type: String
    let cwd: String?
    let text: String?
    let content: [ThreadReadText]?
    let changes: [ThreadReadPath]?
    let commandActions: [ThreadReadPath]?

    private enum CodingKeys: String, CodingKey {
        case type, cwd, text, content, changes, commandActions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        cwd =
            type == "commandExecution"
            ? try container.decodeIfPresent(String.self, forKey: .cwd) : nil
        text =
            type == "agentMessage" ? try container.decodeIfPresent(String.self, forKey: .text) : nil
        content =
            type == "userMessage"
            ? try container.decodeIfPresent([ThreadReadText].self, forKey: .content) : nil
        changes =
            type == "fileChange"
            ? try container.decodeIfPresent([ThreadReadPath].self, forKey: .changes) : nil
        commandActions =
            type == "commandExecution"
            ? try container.decodeIfPresent([ThreadReadPath].self, forKey: .commandActions)
            : nil
    }
}

private struct ThreadReadText: Decodable { let text: String? }
private struct ThreadReadPath: Decodable { let path: String? }

extension ThreadProjectEvidence {
    fileprivate static let empty = ThreadProjectEvidence(
        filePaths: [],
        commandWorkingDirectories: [],
        commandActionPaths: [],
        userMessages: [],
        agentMessages: []
    )

    fileprivate mutating func add(_ item: ThreadReadItem) {
        switch item.type {
        case "fileChange":
            filePaths.formUnion(item.changes?.compactMap(\.path) ?? [])
        case "commandExecution":
            if let cwd = item.cwd {
                commandWorkingDirectories.insert(cwd)
            }
            commandActionPaths.formUnion(item.commandActions?.compactMap(\.path) ?? [])
        case "userMessage":
            userMessages.formUnion(item.content?.compactMap(\.text) ?? [])
        case "agentMessage":
            if let text = item.text {
                agentMessages.insert(text)
            }
        default:
            break
        }
    }
}

private struct EmptyResult: Decodable {}

private struct ThreadListParams: Encodable {
    let archived: Bool
    let cursor: String?
    let limit = 100
    let searchTerm: String?
    let sortDirection = "desc"
    let sortKey = "recency_at"
    let useStateDbOnly = true
}

private struct RequestMessage<Params: Encodable>: Encodable {
    let id: Int
    let method: String
    let params: Params
}

private struct NotificationMessage: Encodable {
    let method: String
}
