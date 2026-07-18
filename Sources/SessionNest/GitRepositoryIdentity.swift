import Foundation

struct GitRepositoryIdentity: Equatable, Sendable {
    let workingTreePath: String
    let canonicalProjectPath: String
    let commonGitDirectory: String
}

struct GitRemoteIdentity: Hashable, Sendable {
    let host: String
    let repositoryPath: String

    static func normalize(_ value: String) -> GitRemoteIdentity? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let host: String
        let path: String
        if value.contains("://") {
            guard
                let components = URLComponents(string: value),
                let scheme = components.scheme?.lowercased(),
                ["git", "http", "https", "ssh"].contains(scheme),
                let parsedHost = components.host,
                !parsedHost.isEmpty
            else { return nil }
            host = parsedHost
            path = components.path
        } else {
            guard let separator = value.firstIndex(of: ":") else { return nil }
            let authority = value[..<separator]
            let parsedHost = authority.split(separator: "@").last.map(String.init) ?? ""
            guard !parsedHost.isEmpty else { return nil }
            host = parsedHost
            path = String(value[value.index(after: separator)...])
        }

        var repositoryPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if repositoryPath.lowercased().hasSuffix(".git") {
            repositoryPath.removeLast(4)
        }
        guard !repositoryPath.isEmpty else { return nil }
        return GitRemoteIdentity(
            host: host.lowercased(),
            repositoryPath: repositoryPath
        )
    }
}

struct ThreadProjectIdentityIndex: Sendable {
    private let canonicalPathByWorkingDirectory: [String: String]
    private let canonicalPathByThreadID: [String: String]

    static let empty = ThreadProjectIdentityIndex(
        canonicalPathByWorkingDirectory: [:],
        canonicalPathByThreadID: [:]
    )

    static func build(
        threads: [CodexThread],
        fileManager: FileManager = .default
    ) -> ThreadProjectIdentityIndex {
        let uniqueWorkingDirectories: Set<String> = Set(
            threads.compactMap { thread -> String? in
                guard CodexScratchWorkspaceDetector.sessionRoot(for: thread.cwd) == nil else {
                    return nil
                }
                return ProjectDirectoryTree.normalizedPath(thread.cwd)
            }
        )
        var canonicalPathByWorkingDirectory: [String: String] = [:]
        for workingDirectory in uniqueWorkingDirectories {
            if let identity = GitRepositoryIdentityResolver.resolve(
                workingDirectory: workingDirectory,
                fileManager: fileManager
            ) {
                canonicalPathByWorkingDirectory[workingDirectory] = identity.canonicalProjectPath
            }
        }

        var canonicalPathsByRemote: [GitRemoteIdentity: Set<String>] = [:]
        for thread in threads {
            let workingDirectory = ProjectDirectoryTree.normalizedPath(thread.cwd)
            guard
                CodexScratchWorkspaceDetector.sessionRoot(for: workingDirectory) == nil,
                let canonicalPath = canonicalPathByWorkingDirectory[workingDirectory],
                let originURL = thread.gitInfo?.originUrl,
                let remote = GitRemoteIdentity.normalize(originURL)
            else { continue }
            canonicalPathsByRemote[remote, default: []].insert(canonicalPath)
        }
        let uniqueCanonicalPathByRemote = canonicalPathsByRemote.compactMapValues { paths in
            paths.count == 1 ? paths.first : nil
        }

        var canonicalPathByThreadID: [String: String] = [:]
        for thread in threads {
            let workingDirectory = ProjectDirectoryTree.normalizedPath(thread.cwd)
            if let canonicalPath = canonicalPathByWorkingDirectory[workingDirectory] {
                canonicalPathByThreadID[thread.id] = canonicalPath
                continue
            }
            guard
                Self.isCodexManagedWorktreePath(workingDirectory),
                let originURL = thread.gitInfo?.originUrl,
                let remote = GitRemoteIdentity.normalize(originURL),
                let canonicalPath = uniqueCanonicalPathByRemote[remote]
            else { continue }
            canonicalPathByThreadID[thread.id] = canonicalPath
        }

        return ThreadProjectIdentityIndex(
            canonicalPathByWorkingDirectory: canonicalPathByWorkingDirectory,
            canonicalPathByThreadID: canonicalPathByThreadID
        )
    }

    func canonicalProjectPath(for thread: CodexThread) -> String? {
        canonicalPathByThreadID[thread.id]
            ?? canonicalPathByWorkingDirectory[ProjectDirectoryTree.normalizedPath(thread.cwd)]
    }

    private static func isCodexManagedWorktreePath(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).pathComponents
        guard let codexIndex = components.lastIndex(of: ".codex") else { return false }
        return components.indices.contains(codexIndex + 3)
            && components[codexIndex + 1] == "worktrees"
    }
}

enum GitRepositoryIdentityResolver {
    static func resolve(
        workingDirectory: String,
        fileManager: FileManager = .default
    ) -> GitRepositoryIdentity? {
        var isDirectory: ObjCBool = false
        let normalizedWorkingDirectory = normalizedPath(workingDirectory)
        guard
            fileManager.fileExists(
                atPath: normalizedWorkingDirectory,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue
        else { return nil }

        var candidate = normalizedWorkingDirectory
        while true {
            let dotGit = URL(fileURLWithPath: candidate, isDirectory: true)
                .appendingPathComponent(".git")
            if let identity = identity(
                workingTreePath: candidate,
                dotGit: dotGit,
                fileManager: fileManager
            ) {
                return identity
            }

            let parent = URL(fileURLWithPath: candidate).deletingLastPathComponent().path
            if parent == candidate { return nil }
            candidate = parent
        }
    }

    private static func identity(
        workingTreePath: String,
        dotGit: URL,
        fileManager: FileManager
    ) -> GitRepositoryIdentity? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue {
            return GitRepositoryIdentity(
                workingTreePath: normalizedPath(workingTreePath),
                canonicalProjectPath: normalizedPath(workingTreePath),
                commonGitDirectory: normalizedPath(dotGit.path)
            )
        }

        guard
            let contents = try? Data(contentsOf: dotGit),
            let gitDirectoryValue = String(decoding: contents, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init),
            gitDirectoryValue.hasPrefix("gitdir:")
        else { return nil }

        let gitDirectoryPath = String(gitDirectoryValue.dropFirst("gitdir:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gitDirectoryPath.isEmpty else { return nil }
        let gitDirectory = resolvedPath(
            gitDirectoryPath,
            relativeTo: dotGit.deletingLastPathComponent()
        )

        var gitDirectoryIsDirectory: ObjCBool = false
        guard
            fileManager.fileExists(atPath: gitDirectory, isDirectory: &gitDirectoryIsDirectory),
            gitDirectoryIsDirectory.boolValue
        else { return nil }

        let commonDirectoryFile = URL(fileURLWithPath: gitDirectory, isDirectory: true)
            .appendingPathComponent("commondir")
        let commonGitDirectory: String
        if let data = try? Data(contentsOf: commonDirectoryFile) {
            let value = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            commonGitDirectory = resolvedPath(
                value,
                relativeTo: URL(fileURLWithPath: gitDirectory, isDirectory: true)
            )
        } else {
            commonGitDirectory = normalizedPath(gitDirectory)
        }

        let canonicalProjectPath =
            URL(fileURLWithPath: commonGitDirectory).lastPathComponent == ".git"
            ? URL(fileURLWithPath: commonGitDirectory).deletingLastPathComponent().path
            : workingTreePath
        return GitRepositoryIdentity(
            workingTreePath: normalizedPath(workingTreePath),
            canonicalProjectPath: normalizedPath(canonicalProjectPath),
            commonGitDirectory: normalizedPath(commonGitDirectory)
        )
    }

    private static func resolvedPath(_ path: String, relativeTo base: URL) -> String {
        let url =
            (path as NSString).isAbsolutePath
            ? URL(fileURLWithPath: path)
            : base.appendingPathComponent(path)
        return normalizedPath(url.path)
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
