import Foundation
import SQLite3
import Testing

@testable import SessionNest

@Test func migrationCreatesFreshDestinationPathWhenLegacyIsMissing() throws {
    let urls = try makeMigrationURLs()
    defer { try? FileManager.default.removeItem(at: urls.root) }

    let result = try ApplicationSupportMigration.prepareDatabase(
        destinationURL: urls.destination,
        legacyURL: urls.legacy
    )

    #expect(result == urls.destination)
    #expect(
        FileManager.default.fileExists(atPath: urls.destination.deletingLastPathComponent().path))
    #expect(!FileManager.default.fileExists(atPath: urls.destination.path))
}

@Test func migrationPropagatesLegacyInspectionFailure() throws {
    let urls = try makeMigrationURLs()
    defer { try? FileManager.default.removeItem(at: urls.root) }

    do {
        _ = try ApplicationSupportMigration.prepareDatabase(
            destinationURL: urls.destination,
            legacyURL: urls.legacy,
            backup: { _, _ in Issue.record("Backup must not run after inspection failure") },
            itemExists: { url in
                if url == urls.legacy {
                    throw MigrationTestError.inspectionFailed
                }
                return false
            }
        )
        Issue.record("Expected legacy inspection failure")
    } catch MigrationTestError.inspectionFailed {
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(!FileManager.default.fileExists(atPath: urls.destination.path))
}

@Test func migrationCopiesLegacyDatabaseIncludingLiveWALData() async throws {
    let urls = try makeMigrationURLs()
    defer { try? FileManager.default.removeItem(at: urls.root) }

    let legacyStore = try MetadataStore(databaseURL: urls.legacy)
    try enableWAL(at: urls.legacy)
    try await legacyStore.setFavorite(threadID: "legacy-thread", isFavorite: true)
    #expect(FileManager.default.fileExists(atPath: urls.legacy.path + "-wal"))

    let result = try ApplicationSupportMigration.prepareDatabase(
        destinationURL: urls.destination,
        legacyURL: urls.legacy
    )
    let migratedStore = try MetadataStore(databaseURL: result)

    #expect(try await migratedStore.loadMetadata()["legacy-thread"]?.isFavorite == true)
    withExtendedLifetime(legacyStore) {}
}

@Test func migrationNeverOverwritesExistingDestination() throws {
    let urls = try makeMigrationURLs()
    defer { try? FileManager.default.removeItem(at: urls.root) }
    try FileManager.default.createDirectory(
        at: urls.destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let marker = Data("existing-destination".utf8)
    try marker.write(to: urls.destination)
    try FileManager.default.createDirectory(
        at: urls.legacy.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("legacy".utf8).write(to: urls.legacy)

    let result = try ApplicationSupportMigration.prepareDatabase(
        destinationURL: urls.destination,
        legacyURL: urls.legacy
    )

    #expect(result == urls.destination)
    #expect(try Data(contentsOf: urls.destination) == marker)
}

@Test func migrationFailureLeavesNoDestinationDatabase() throws {
    let urls = try makeMigrationURLs()
    defer { try? FileManager.default.removeItem(at: urls.root) }
    try FileManager.default.createDirectory(
        at: urls.legacy.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("legacy".utf8).write(to: urls.legacy)

    #expect(throws: MigrationTestError.self) {
        try ApplicationSupportMigration.prepareDatabase(
            destinationURL: urls.destination,
            legacyURL: urls.legacy,
            backup: { _, temporaryURL in
                try Data("partial-backup".utf8).write(to: temporaryURL)
                throw MigrationTestError.backupFailed
            }
        )
    }

    #expect(!FileManager.default.fileExists(atPath: urls.destination.path))
    #expect(!FileManager.default.fileExists(atPath: urls.temporary.path))
}

@Test func migrationSurfacesBackupAndCleanupFailures() throws {
    let urls = try makeMigrationURLs()
    defer { try? FileManager.default.removeItem(at: urls.root) }
    try FileManager.default.createDirectory(
        at: urls.legacy.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("legacy".utf8).write(to: urls.legacy)

    do {
        _ = try ApplicationSupportMigration.prepareDatabase(
            destinationURL: urls.destination,
            legacyURL: urls.legacy,
            backup: { _, temporaryURL in
                try Data("partial-backup".utf8).write(to: temporaryURL)
                throw MigrationTestError.backupFailed
            },
            removeItem: { url in
                #expect(url == urls.temporary)
                throw MigrationTestError.cleanupFailed
            }
        )
        Issue.record("Expected migration and cleanup failure")
    } catch {
        #expect(error.localizedDescription.contains("backup failed"))
        #expect(error.localizedDescription.contains("cleanup failed"))
    }

    #expect(!FileManager.default.fileExists(atPath: urls.destination.path))
    #expect(FileManager.default.fileExists(atPath: urls.temporary.path))
}

private struct MigrationURLs {
    let root: URL
    let destination: URL
    let legacy: URL

    var temporary: URL {
        destination.deletingLastPathComponent().appendingPathComponent("manager.sqlite.migrating")
    }
}

private enum MigrationTestError: LocalizedError {
    case backupFailed
    case cleanupFailed
    case inspectionFailed

    var errorDescription: String? {
        switch self {
        case .backupFailed:
            "backup failed"
        case .cleanupFailed:
            "cleanup failed"
        case .inspectionFailed:
            "inspection failed"
        }
    }
}

private func makeMigrationURLs() throws -> MigrationURLs {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return MigrationURLs(
        root: root,
        destination:
            root
            .appendingPathComponent("SessionNest", isDirectory: true)
            .appendingPathComponent("manager.sqlite"),
        legacy:
            root
            .appendingPathComponent("Codex Sessions", isDirectory: true)
            .appendingPathComponent("manager.sqlite")
    )
}

private func enableWAL(at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
        if let database {
            sqlite3_close(database)
        }
        throw MigrationTestError.backupFailed
    }
    defer { sqlite3_close(database) }

    guard sqlite3_exec(database, "PRAGMA journal_mode = WAL", nil, nil, nil) == SQLITE_OK else {
        throw MigrationTestError.backupFailed
    }
}
