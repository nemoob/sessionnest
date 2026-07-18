import Foundation
import Testing

@testable import SessionNest

@Suite("GitRepositoryIdentityTests")
struct GitRepositoryIdentityTests {
    @Test func linkedWorktreeResolvesToMainWorkingTree() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: root) }

        let main = root.appendingPathComponent("DBBridge")
        let commonGitDirectory = main.appendingPathComponent(".git")
        let linked = root.appendingPathComponent("linked/DBBridge")
        let linkedGitDirectory = commonGitDirectory.appendingPathComponent("worktrees/DBBridge2")
        try fileManager.createDirectory(
            at: linkedGitDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: linked, withIntermediateDirectories: true)
        try Data("../..\n".utf8).write(to: linkedGitDirectory.appendingPathComponent("commondir"))
        try Data("gitdir: \(linkedGitDirectory.path)\n".utf8).write(
            to: linked.appendingPathComponent(".git")
        )

        let mainIdentity = GitRepositoryIdentityResolver.resolve(
            workingDirectory: main.path,
            fileManager: fileManager
        )
        let linkedIdentity = GitRepositoryIdentityResolver.resolve(
            workingDirectory: linked.path,
            fileManager: fileManager
        )

        #expect(mainIdentity?.canonicalProjectPath == main.path)
        #expect(linkedIdentity?.canonicalProjectPath == main.path)
        #expect(linkedIdentity?.commonGitDirectory == commonGitDirectory.path)
    }

    @Test func remoteIdentityNormalizesEquivalentGitLabURLs() {
        let values = [
            "http://gitlab.example.com/database/dbbridge.git",
            "ssh://git@gitlab.example.com:10022/database/dbbridge.git",
            "git@gitlab.example.com:database/dbbridge.git",
        ]

        #expect(Set(values.compactMap(GitRemoteIdentity.normalize)).count == 1)
    }

    @Test func missingCodexWorktreeUsesUniqueRemoteCanonicalPath() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: root) }

        let main = root.appendingPathComponent("DBBridge")
        try fileManager.createDirectory(
            at: main.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let missing = root.appendingPathComponent(".codex/worktrees/abcd/DBBridge")
        let threads = [
            thread(
                "main",
                cwd: main.path,
                originURL: "ssh://git@gitlab.example.com:10022/database/dbbridge.git"
            ),
            thread(
                "missing",
                cwd: missing.path,
                originURL: "http://gitlab.example.com/database/dbbridge.git"
            ),
        ]

        let index = ThreadProjectIdentityIndex.build(
            threads: threads,
            fileManager: fileManager
        )

        #expect(index.canonicalProjectPath(for: threads[0]) == main.path)
        #expect(index.canonicalProjectPath(for: threads[1]) == main.path)
    }

    @Test func worktreeContainerWithoutRepositoryComponentDoesNotUseRemoteFallback() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: root) }

        let main = root.appendingPathComponent("DBBridge")
        try fileManager.createDirectory(
            at: main.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let threads = [
            thread(
                "main",
                cwd: main.path,
                originURL: "ssh://git@gitlab.example.com/database/dbbridge.git"
            ),
            thread(
                "container",
                cwd: root.appendingPathComponent(".codex/worktrees/abcd").path,
                originURL: "ssh://git@gitlab.example.com/database/dbbridge.git"
            ),
        ]

        let index = ThreadProjectIdentityIndex.build(
            threads: threads,
            fileManager: fileManager
        )

        #expect(index.canonicalProjectPath(for: threads[1]) == nil)
    }

    @Test func scratchRepositoryDoesNotMakeRemoteFallbackAmbiguous() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: root) }

        let main = root.appendingPathComponent("DBBridge")
        let scratch = root.appendingPathComponent("Codex/2026-07-18/session/DBBridge")
        try fileManager.createDirectory(
            at: main.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: scratch.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let remote = "ssh://git@gitlab.example.com/database/dbbridge.git"
        let threads = [
            thread("main", cwd: main.path, originURL: remote),
            thread("scratch", cwd: scratch.path, originURL: remote),
            thread(
                "missing",
                cwd: root.appendingPathComponent(".codex/worktrees/abcd/DBBridge").path,
                originURL: remote
            ),
        ]

        let index = ThreadProjectIdentityIndex.build(
            threads: threads,
            fileManager: fileManager
        )

        #expect(index.canonicalProjectPath(for: threads[2]) == main.path)
    }

    @Test func ambiguousRemoteKeepsIndependentClonesSeparate() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: root) }

        let first = root.appendingPathComponent("first/DBBridge")
        let second = root.appendingPathComponent("second/DBBridge")
        for repository in [first, second] {
            try fileManager.createDirectory(
                at: repository.appendingPathComponent(".git"),
                withIntermediateDirectories: true
            )
        }
        let remote = "ssh://git@gitlab.example.com/database/dbbridge.git"
        let threads = [
            thread("first", cwd: first.path, originURL: remote),
            thread("second", cwd: second.path, originURL: remote),
            thread(
                "missing",
                cwd: root.appendingPathComponent(".codex/worktrees/abcd/DBBridge").path,
                originURL: remote
            ),
        ]

        let index = ThreadProjectIdentityIndex.build(
            threads: threads,
            fileManager: fileManager
        )

        #expect(index.canonicalProjectPath(for: threads[0]) == first.path)
        #expect(index.canonicalProjectPath(for: threads[1]) == second.path)
        #expect(index.canonicalProjectPath(for: threads[2]) == nil)
    }

    @Test func relativeGitDirectoryResolvesLinkedWorktree() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: root) }

        let main = root.appendingPathComponent("DBBridge")
        let linked = root.appendingPathComponent("linked/DBBridge")
        let linkedGitDirectory = main.appendingPathComponent(".git/worktrees/DBBridge2")
        try fileManager.createDirectory(at: linkedGitDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: linked, withIntermediateDirectories: true)
        try Data("../..\n".utf8).write(to: linkedGitDirectory.appendingPathComponent("commondir"))
        try Data("gitdir: ../../DBBridge/.git/worktrees/DBBridge2\n".utf8).write(
            to: linked.appendingPathComponent(".git")
        )

        let identity = GitRepositoryIdentityResolver.resolve(
            workingDirectory: linked.path,
            fileManager: fileManager
        )

        #expect(identity?.canonicalProjectPath == main.path)
    }

    private func thread(
        _ id: String,
        cwd: String,
        originURL: String
    ) -> CodexThread {
        CodexThread(
            id: id,
            name: id,
            preview: id,
            cwd: cwd,
            createdAt: 1,
            updatedAt: 1,
            recencyAt: nil,
            gitInfo: GitInfo(branch: nil, originUrl: originURL)
        )
    }
}
