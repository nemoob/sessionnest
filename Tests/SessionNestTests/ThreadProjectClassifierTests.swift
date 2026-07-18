import Foundation
import Testing

@testable import SessionNest

@Suite("ThreadProjectClassifierTests")
struct ThreadProjectClassifierTests {
    private let candidates = [
        "/work/codex/sample-app",
        "/work/codex/sample-api",
    ]

    @Test func scansOnlyDirectChildGitRepositories() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: root) }

        let sampleApp = root.appendingPathComponent("sample-app")
        let sampleAPI = root.appendingPathComponent("sample-api")
        let src = root.appendingPathComponent("src")
        try fileManager.createDirectory(
            at: sampleApp.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sampleAPI, withIntermediateDirectories: true)
        #expect(
            fileManager.createFile(
                atPath: sampleAPI.appendingPathComponent(".git").path, contents: Data()))
        try fileManager.createDirectory(at: src, withIntermediateDirectories: true)

        let repositories = try ThreadProjectScanner.directChildGitRepositories(
            in: root.path,
            fileManager: fileManager
        )

        #expect(repositories == [sampleAPI.path, sampleApp.path].sorted())
    }

    @Test func classifiesFilePath() {
        #expect(classify(filePath: "/work/codex/sample-app/a.swift") == "/work/codex/sample-app")
    }

    @Test func classifiesCommandWorkingDirectory() {
        #expect(classify(commandCWD: "/work/codex/sample-api") == "/work/codex/sample-api")
    }

    @Test func classifiesCommandActionPath() {
        #expect(
            classify(actionPath: "/work/codex/sample-app/Sources") == "/work/codex/sample-app")
    }

    @Test func classifiesUserMessage() {
        #expect(classify(userText: "Update sample-app") == "/work/codex/sample-app")
    }

    @Test func leavesAgentMessageAloneUnclassified() {
        #expect(classify(agentText: "Possibly sample-app") == nil)
    }

    @Test func rejectsPathPrefixWithoutComponentBoundary() {
        #expect(classify(filePath: "/work/codex/sample-app2/a.swift") == nil)
    }

    @Test func ignoresRelativePathEvidence() {
        let candidate = FileManager.default.currentDirectoryPath + "/sample-app"
        let evidence = ThreadProjectEvidence(
            filePaths: ["sample-app/a.swift"],
            commandWorkingDirectories: ["sample-app"],
            commandActionPaths: ["sample-app/Sources"],
            userMessages: [],
            agentMessages: []
        )

        #expect(
            ThreadProjectClassifier.classify(evidence: evidence, candidates: [candidate]) == nil)
    }

    @Test func leavesTiedProjectsUnclassified() {
        #expect(classify(userText: "sample-app sample-api") == nil)
    }

    @Test func canonicalizesLinkedWorktreeCandidateToMainRepository() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: root) }

        let main = root.appendingPathComponent("DBBridge")
        let linked = root.appendingPathComponent("workspace/DBBridge")
        let linkedGitDirectory = main.appendingPathComponent(".git/worktrees/DBBridge2")
        try fileManager.createDirectory(at: linkedGitDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: linked, withIntermediateDirectories: true)
        try Data("../..\n".utf8).write(to: linkedGitDirectory.appendingPathComponent("commondir"))
        try Data("gitdir: \(linkedGitDirectory.path)\n".utf8).write(
            to: linked.appendingPathComponent(".git")
        )

        let result = ThreadProjectClassifier.classify(
            evidence: ThreadProjectEvidence(
                filePaths: [linked.appendingPathComponent("main.go").path],
                commandWorkingDirectories: [],
                commandActionPaths: [],
                userMessages: [],
                agentMessages: []
            ),
            candidates: [linked.path],
            fileManager: fileManager
        )

        #expect(result == main.path)
    }

    private func classify(
        filePath: String? = nil,
        commandCWD: String? = nil,
        actionPath: String? = nil,
        userText: String? = nil,
        agentText: String? = nil
    ) -> String? {
        ThreadProjectClassifier.classify(
            evidence: ThreadProjectEvidence(
                filePaths: set(filePath),
                commandWorkingDirectories: set(commandCWD),
                commandActionPaths: set(actionPath),
                userMessages: set(userText),
                agentMessages: set(agentText)
            ),
            candidates: candidates
        )
    }

    private func set(_ value: String?) -> Set<String> {
        value.map { [$0] } ?? []
    }
}
