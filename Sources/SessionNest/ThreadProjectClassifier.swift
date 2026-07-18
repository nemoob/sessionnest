import Foundation

enum ThreadProjectScanner {
    static func directChildGitRepositories(
        in rootPath: String,
        fileManager: FileManager = .default
    ) throws -> [String] {
        let children = try fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: rootPath, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return
            try children
            .filter { child in
                let values = try child.resourceValues(forKeys: [.isDirectoryKey])
                return values.isDirectory == true
                    && fileManager.fileExists(atPath: child.appendingPathComponent(".git").path)
            }
            .map { ProjectDirectoryTree.normalizedPath($0.path) }
            .sorted()
    }

    static func scratchGitRepositories(
        in rootPath: String,
        evidence: ThreadProjectEvidence,
        fileManager: FileManager = .default
    ) throws -> [String] {
        let rootPath = ProjectDirectoryTree.normalizedPath(rootPath)
        var repositories: Set<String> = []
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: rootPath, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            if isGitRepository(rootPath, fileManager: fileManager) {
                repositories.insert(rootPath)
            }
            repositories.formUnion(
                try directChildGitRepositories(in: rootPath, fileManager: fileManager)
            )
        }

        let evidencePaths =
            evidence.filePaths
            .union(evidence.commandWorkingDirectories)
            .union(evidence.commandActionPaths)
        for path in evidencePaths
        where (path as NSString).isAbsolutePath
            && ProjectDirectoryTree.contains(path: path, in: rootPath)
        {
            if let repository = nearestGitRepository(
                containing: path,
                boundedBy: rootPath,
                fileManager: fileManager
            ) {
                repositories.insert(repository)
            }
        }

        return repositories.sorted()
    }

    private static func nearestGitRepository(
        containing path: String,
        boundedBy rootPath: String,
        fileManager: FileManager
    ) -> String? {
        let rootPath = ProjectDirectoryTree.normalizedPath(rootPath)
        let normalizedPath = ProjectDirectoryTree.normalizedPath(path)
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: normalizedPath, isDirectory: &isDirectory)
        var candidate =
            exists && !isDirectory.boolValue
            ? URL(fileURLWithPath: normalizedPath).deletingLastPathComponent().path
            : normalizedPath

        while ProjectDirectoryTree.contains(path: candidate, in: rootPath) {
            if isGitRepository(candidate, fileManager: fileManager) {
                return ProjectDirectoryTree.normalizedPath(candidate)
            }
            if candidate == rootPath { break }
            let parent = URL(fileURLWithPath: candidate).deletingLastPathComponent().path
            if parent == candidate { break }
            candidate = parent
        }
        return nil
    }

    private static func isGitRepository(
        _ path: String,
        fileManager: FileManager
    ) -> Bool {
        fileManager.fileExists(
            atPath: URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent(".git").path
        )
    }
}

enum ThreadProjectClassifier {
    static func classify(
        evidence: ThreadProjectEvidence,
        candidates: [String]
    ) -> String? {
        let candidates = Set(candidates.map(ProjectDirectoryTree.normalizedPath)).sorted()
        let scored = candidates.map { ($0, score(candidate: $0, evidence: evidence)) }.sorted {
            lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 > rhs.1
        }

        guard let top = scored.first,
            top.1 >= 3,
            top.1 > (scored.dropFirst().first?.1 ?? 0)
        else { return nil }
        return top.0
    }

    private static func score(candidate: String, evidence: ThreadProjectEvidence) -> Int {
        var score = 0
        for path in evidence.filePaths
        where (path as NSString).isAbsolutePath
            && ProjectDirectoryTree.contains(path: path, in: candidate)
        {
            score += 10
        }
        for path in evidence.commandWorkingDirectories
        where (path as NSString).isAbsolutePath
            && ProjectDirectoryTree.contains(path: path, in: candidate)
        {
            score += 8
        }
        for path in evidence.commandActionPaths
        where (path as NSString).isAbsolutePath
            && ProjectDirectoryTree.contains(path: path, in: candidate)
        {
            score += 6
        }
        for message in evidence.userMessages where matches(candidate: candidate, text: message) {
            score += 3
        }
        for message in evidence.agentMessages where matches(candidate: candidate, text: message) {
            score += 1
        }
        return score
    }

    private static func matches(candidate: String, text: String) -> Bool {
        contains(token: candidate, in: text)
            || contains(token: URL(fileURLWithPath: candidate).lastPathComponent, in: text)
    }

    private static func contains(token: String, in text: String) -> Bool {
        guard !token.isEmpty else { return false }
        var start = text.startIndex
        while let range = text.range(of: token, range: start..<text.endIndex) {
            let hasTokenBefore =
                range.lowerBound > text.startIndex
                && isTokenCharacter(text[text.index(before: range.lowerBound)])
            let hasTokenAfter =
                range.upperBound < text.endIndex
                && isTokenCharacter(text[range.upperBound])
            if !hasTokenBefore && !hasTokenAfter { return true }
            start = range.upperBound
        }
        return false
    }

    private static func isTokenCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-"
    }
}
