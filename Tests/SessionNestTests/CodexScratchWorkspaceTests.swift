import Foundation
import Testing

@testable import SessionNest

@Suite("CodexScratchWorkspaceTests")
struct CodexScratchWorkspaceTests {
    @Test func detectsSessionRootFromExactPath() {
        #expect(
            CodexScratchWorkspaceDetector.sessionRoot(
                for: "/Users/me/Documents/Codex/2026-07-18/session-name"
            ) == "/Users/me/Documents/Codex/2026-07-18/session-name"
        )
    }

    @Test func detectsSessionRootFromDeeperWorkingDirectory() {
        #expect(
            CodexScratchWorkspaceDetector.sessionRoot(
                for: "/Users/me/Documents/Codex/2026-07-18/session-name/Sources/App"
            ) == "/Users/me/Documents/Codex/2026-07-18/session-name"
        )
    }

    @Test func acceptsValidLeapDay() {
        #expect(
            CodexScratchWorkspaceDetector.sessionRoot(
                for: "/tmp/Codex/2024-02-29/leap-session"
            ) == "/tmp/Codex/2024-02-29/leap-session"
        )
    }

    @Test func selectsNearestValidCodexSequence() {
        #expect(
            CodexScratchWorkspaceDetector.sessionRoot(
                for: "/tmp/Codex/2026-01-01/outer/Codex/2026-07-18/inner/Sources"
            ) == "/tmp/Codex/2026-01-01/outer/Codex/2026-07-18/inner"
        )
    }

    @Test func standardizesParentComponentsBeforeMatching() {
        #expect(
            CodexScratchWorkspaceDetector.sessionRoot(
                for: "/tmp/Codex/2026-07-18/old/../session/Sources"
            ) == "/tmp/Codex/2026-07-18/session"
        )
    }

    @Test func rejectsSimilarDirectoryNames() {
        #expect(
            CodexScratchWorkspaceDetector.sessionRoot(
                for: "/tmp/MyCodex/2026-07-18/session"
            ) == nil
        )
        #expect(
            CodexScratchWorkspaceDetector.sessionRoot(
                for: "/tmp/Codex2/2026-07-18/session"
            ) == nil
        )
    }

    @Test func rejectsInvalidDate() {
        #expect(
            CodexScratchWorkspaceDetector.sessionRoot(
                for: "/tmp/Codex/2025-02-29/session"
            ) == nil
        )
        #expect(
            CodexScratchWorkspaceDetector.sessionRoot(
                for: "/tmp/Codex/2026-13-01/session"
            ) == nil
        )
    }

    @Test func rejectsMissingSessionComponent() {
        #expect(
            CodexScratchWorkspaceDetector.sessionRoot(
                for: "/tmp/Codex/2026-07-18"
            ) == nil
        )
    }

    @Test func rejectsRelativePath() {
        #expect(
            CodexScratchWorkspaceDetector.sessionRoot(
                for: "Codex/2026-07-18/session"
            ) == nil
        )
    }

    @Test func discoversDirectAndEvidenceDerivedRepositoriesWithinSession() throws {
        let fileManager = FileManager.default
        let fixture = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: fixture) }
        let session = fixture.appendingPathComponent("Codex/2026-07-18/session")
        let direct = session.appendingPathComponent("direct")
        let deep = session.appendingPathComponent("nested/deep")
        let deepFile = deep.appendingPathComponent("Sources/App.swift")
        let outside = fixture.appendingPathComponent("outside")
        try fileManager.createDirectory(
            at: direct.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: deep.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: deepFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        #expect(fileManager.createFile(atPath: deepFile.path, contents: Data()))
        try fileManager.createDirectory(
            at: outside.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )

        let repositories = try ThreadProjectScanner.scratchGitRepositories(
            in: session.path,
            evidence: ThreadProjectEvidence(
                filePaths: [deepFile.path, outside.appendingPathComponent("file.txt").path],
                commandWorkingDirectories: [],
                commandActionPaths: [],
                userMessages: [],
                agentMessages: []
            ),
            fileManager: fileManager
        )

        #expect(repositories == [deep.path, direct.path].sorted())
    }

    @Test func discoversSessionRootWhenItIsARepository() throws {
        let fileManager = FileManager.default
        let fixture = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: fixture) }
        let session = fixture.appendingPathComponent("Codex/2026-07-18/session")
        try fileManager.createDirectory(
            at: session.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )

        let repositories = try ThreadProjectScanner.scratchGitRepositories(
            in: session.path,
            evidence: ThreadProjectEvidence(
                filePaths: [],
                commandWorkingDirectories: [session.path],
                commandActionPaths: [],
                userMessages: [],
                agentMessages: []
            ),
            fileManager: fileManager
        )

        #expect(repositories == [session.path])
    }

    @Test func missingScratchDirectoryHasNoRepositoryCandidates() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Codex/2026-07-18/session")

        #expect(
            try ThreadProjectScanner.scratchGitRepositories(
                in: missing.path,
                evidence: ThreadProjectEvidence(
                    filePaths: [],
                    commandWorkingDirectories: [],
                    commandActionPaths: [],
                    userMessages: [],
                    agentMessages: []
                )
            ).isEmpty
        )
    }
}
