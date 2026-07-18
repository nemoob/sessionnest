import Foundation

struct GitInfo: Codable, Equatable, Sendable {
    let branch: String?
}

struct CodexThread: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String?
    let preview: String
    let cwd: String
    let createdAt: Int64
    let updatedAt: Int64
    let recencyAt: Int64?
    let gitInfo: GitInfo?
    let path: String?

    init(
        id: String,
        name: String?,
        preview: String,
        cwd: String,
        createdAt: Int64,
        updatedAt: Int64,
        recencyAt: Int64?,
        gitInfo: GitInfo?,
        path: String? = nil
    ) {
        self.id = id
        self.name = name
        self.preview = preview
        self.cwd = cwd
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.recencyAt = recencyAt
        self.gitInfo = gitInfo
        self.path = path
    }

    var displayTitle: String {
        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cleanName.isEmpty { return cleanName }
        let firstLine = preview.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return firstLine.isEmpty ? "未命名会话" : firstLine
    }

    var activityTimestamp: Int64 {
        recencyAt ?? updatedAt
    }

    var openURL: URL? {
        URL(string: "codex://threads/\(id)")
    }
}

struct ThreadMetadata: Equatable, Sendable {
    let threadID: String
    var isFavorite: Bool
    var collectionID: String?
}

struct ThreadProjectEvidence: Equatable, Sendable {
    var filePaths: Set<String>
    var commandWorkingDirectories: Set<String>
    var commandActionPaths: Set<String>
    var userMessages: Set<String>
    var agentMessages: Set<String>
}

enum ThreadProjectResolution: Equatable, Sendable {
    case project(path: String)
    case workingDirectory(path: String)
    case noProject

    var projectPath: String? {
        switch self {
        case .project(let path), .workingDirectory(let path): path
        case .noProject: nil
        }
    }

    var isNoProject: Bool { self == .noProject }
}

struct ThreadProjectCache: Equatable, Sendable {
    let threadID: String
    let resolution: ThreadProjectResolution
    let analyzedUpdatedAt: Int64
    let classifierVersion: Int64

    var projectPath: String? { resolution.projectPath }
}

struct SessionCollection: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var sortOrder: Int
}

struct SessionTag: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var colorHex: String
    var sortOrder: Int
}
