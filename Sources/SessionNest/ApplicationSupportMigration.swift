import Foundation
import SQLite3

enum ApplicationSupportMigration {
    typealias Backup = (URL, URL) throws -> Void
    typealias ItemExists = (URL) throws -> Bool
    typealias RemoveItem = (URL) throws -> Void

    static func prepareDatabase(
        destinationURL: URL,
        legacyURL: URL,
        backup: Backup = SQLiteDatabaseBackup.copy,
        itemExists: ItemExists = FileSystemItemInspection.exists,
        removeItem: RemoveItem = FileSystemItemOperations.removeItem
    ) throws -> URL {
        let fileManager = FileManager.default
        guard try !itemExists(destinationURL) else {
            return destinationURL
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard try itemExists(legacyURL) else {
            return destinationURL
        }

        let temporaryURL = destinationURL.appendingPathExtension("migrating")
        do {
            if try itemExists(temporaryURL) {
                try removeItem(temporaryURL)
            }
            try backup(legacyURL, temporaryURL)
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            return destinationURL
        } catch {
            let migrationError = error
            do {
                if try itemExists(temporaryURL) {
                    try removeItem(temporaryURL)
                }
            } catch {
                throw ApplicationSupportMigrationError.migrationAndCleanupFailed(
                    migration: migrationError,
                    cleanup: error
                )
            }
            throw migrationError
        }
    }
}

private enum ApplicationSupportMigrationError: LocalizedError {
    case migrationAndCleanupFailed(migration: Error, cleanup: Error)

    var errorDescription: String? {
        switch self {
        case .migrationAndCleanupFailed(let migration, let cleanup):
            "元数据迁移失败：\(migration.localizedDescription)；同时无法清理临时数据库：\(cleanup.localizedDescription)"
        }
    }
}

private enum FileSystemItemOperations {
    static func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

private enum FileSystemItemInspection {
    static func exists(at url: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch {
            guard isNotFound(error) else { throw error }
            return false
        }
    }

    private static func isNotFound(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
            nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError
        {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
            nsError.code == Int(POSIXErrorCode.ENOENT.rawValue)
        {
            return true
        }
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isNotFound(underlyingError)
        }
        return false
    }
}

enum SQLiteDatabaseBackup {
    static func copy(from sourceURL: URL, to destinationURL: URL) throws {
        let source = try open(
            sourceURL,
            flags: SQLITE_OPEN_READONLY,
            operation: "打开旧数据库"
        )
        defer { sqlite3_close(source) }

        let destination = try open(
            destinationURL,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            operation: "创建迁移数据库"
        )
        defer { sqlite3_close(destination) }

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw error(operation: "初始化备份", database: destination)
        }

        let stepResult = sqlite3_backup_step(backup, -1)
        let stepMessage = String(cString: sqlite3_errmsg(destination))
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE else {
            throw SQLiteDatabaseBackupError.sqlite(
                operation: "复制数据库",
                code: stepResult,
                message: stepMessage
            )
        }
        guard finishResult == SQLITE_OK else {
            throw error(
                operation: "完成备份",
                database: destination,
                fallbackCode: finishResult
            )
        }
    }

    private static func open(
        _ url: URL,
        flags: Int32,
        operation: String
    ) throws -> OpaquePointer {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let migrationError = error(
                operation: operation,
                database: database,
                fallbackCode: result
            )
            if let database {
                sqlite3_close(database)
            }
            throw migrationError
        }
        return database
    }

    private static func error(
        operation: String,
        database: OpaquePointer?,
        fallbackCode: Int32? = nil
    ) -> SQLiteDatabaseBackupError {
        let code = database.map(sqlite3_errcode) ?? fallbackCode ?? SQLITE_ERROR
        let message =
            database.map { String(cString: sqlite3_errmsg($0)) }
            ?? String(cString: sqlite3_errstr(code))
        return .sqlite(operation: operation, code: code, message: message)
    }
}

private enum SQLiteDatabaseBackupError: LocalizedError {
    case sqlite(operation: String, code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let operation, let code, let message):
            "元数据迁移失败（\(operation)，SQLite \(code)）：\(message)"
        }
    }
}
