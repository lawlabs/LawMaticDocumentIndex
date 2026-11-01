import Foundation
import SQLite

/// Идентичность файла на диске. `PRAGMA data_version` не меняется, если sqlite
/// заменили атомарным rename: открытое соединение остаётся на старом inode.
public struct DocumentIndexFileStamp: Equatable, Sendable {
    public var identifier: String
    public var size: Int64
    public var modifiedAt: Date?
}

public struct DocumentIndexSnapshotInfo: Equatable, Sendable {
    public var generation: String?
    public var applicationID: Int32
    public var userVersion: Int32
    public var hasWALSidecar: Bool
    public var stamp: DocumentIndexFileStamp
    public var capabilities: DocumentIndexReaderCapabilities
}

/// Проверка и публикация переносимого снимка. Не открывает долгоживущее соединение.
public enum DocumentIndexSnapshot {
    public struct InspectOptions: Sendable {
        public var requireStandalone: Bool
        public var runIntegrityCheck: Bool

        public init(requireStandalone: Bool = false, runIntegrityCheck: Bool = false) {
            self.requireStandalone = requireStandalone
            self.runIntegrityCheck = runIntegrityCheck
        }

        /// Живой файл Finder: WAL допустим.
        public static let live = InspectOptions(requireStandalone: false, runIntegrityCheck: false)
        /// Публикуемый `VACUUM INTO`: без WAL/SHM и с integrity_check.
        public static let publishedExport = InspectOptions(requireStandalone: true, runIntegrityCheck: true)
    }

    public static func manifestURL(forDatabase url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(DocumentIndexSchema.manifestFileName)
    }

    public static func sidecarURLs(forDatabase url: URL) -> (wal: URL, shm: URL) {
        (
            URL(fileURLWithPath: url.path + "-wal"),
            URL(fileURLWithPath: url.path + "-shm")
        )
    }

    public static func fileStamp(at url: URL) throws -> DocumentIndexFileStamp {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw DocumentIndexError.databaseMissing(path: url.path)
        }
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ])
        guard let size = values.fileSize, size > 0 else {
            throw DocumentIndexError.invalidArgument("файл индекса пустой или ещё копируется")
        }
        let identifier: String
        if let resourceId = values.fileResourceIdentifier {
            identifier = String(describing: resourceId)
        } else {
            identifier = "\(url.standardizedFileURL.path)|\(size)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return DocumentIndexFileStamp(
            identifier: identifier,
            size: Int64(size),
            modifiedAt: values.contentModificationDate
        )
    }

    public static func requireSQLiteHeader(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 16) ?? Data()
        guard prefix.starts(with: Data("SQLite format 3".utf8)) else {
            throw DocumentIndexError.invalidArgument(
                "файл не является готовой базой SQLite — снимок ещё копируется или повреждён"
            )
        }
    }

    public static func inspect(
        _ url: URL,
        options: InspectOptions = .live
    ) throws -> DocumentIndexSnapshotInfo {
        let stamp = try fileStamp(at: url)
        try requireSQLiteHeader(url)

        let sidecars = sidecarURLs(forDatabase: url)
        let hasWAL = FileManager.default.fileExists(atPath: sidecars.wal.path)
            || FileManager.default.fileExists(atPath: sidecars.shm.path)
        if options.requireStandalone, hasWAL {
            throw DocumentIndexError.invalidArgument(
                "рядом со снимком есть WAL/SHM — это живая база, не переносимый снимок"
            )
        }

        let db = try SQLite.Connection(url.path, readonly: true)
        try db.execute("PRAGMA foreign_keys = ON;")
        let applicationID = Int32(truncatingIfNeeded: try pragmaInt64(db, "application_id"))
        let userVersion = Int32(truncatingIfNeeded: try pragmaInt64(db, "user_version"))
        if applicationID != DocumentIndexSchema.applicationID
            || userVersion != DocumentIndexSchema.userVersion {
            throw DocumentIndexError.incompatibleDatabase(
                applicationID: applicationID,
                userVersion: userVersion
            )
        }
        if try pragmaInt64(db, "page_count") == 0 {
            throw DocumentIndexError.invalidArgument("файл индекса пустой или ещё копируется")
        }
        guard try db.scalar("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'documents'") != nil else {
            throw DocumentIndexError.invalidArgument("в файле нет таблицы documents — снимок не готов")
        }
        if options.runIntegrityCheck {
            var issues: [String] = []
            for row in try db.prepare("PRAGMA integrity_check") {
                if let line = row[0] as? String, line != "ok" {
                    issues.append(line)
                }
            }
            if !issues.isEmpty {
                throw DocumentIndexError.integrityCheckFailed(issues)
            }
        }
        var generation: String?
        for row in try db.prepare(
            "SELECT value FROM index_metadata WHERE key = ?",
            DocumentIndexSchema.MetadataKey.indexGeneration
        ) {
            generation = row[0] as? String
        }
        return DocumentIndexSnapshotInfo(
            generation: generation,
            applicationID: applicationID,
            userVersion: userVersion,
            hasWALSidecar: hasWAL,
            stamp: stamp,
            capabilities: try DocumentIndexStore.readCapabilities(db)
        )
    }

    private static func pragmaInt64(_ db: SQLite.Connection, _ name: String) throws -> Int64 {
        let value = try db.scalar("PRAGMA \(name)")
        if let int64 = value as? Int64 { return int64 }
        if let int = value as? Int { return Int64(int) }
        return 0
    }

    /// Атомарная публикация на том же томе. Недописанный temp не становится `dest`.
    public static func publishAtomically(from temp: URL, to dest: URL) throws {
        if FileManager.default.fileExists(atPath: dest.path) {
            _ = try FileManager.default.replaceItemAt(
                dest,
                withItemAt: temp,
                backupItemName: nil,
                options: []
            )
        } else {
            try FileManager.default.moveItem(at: temp, to: dest)
        }
        let sidecars = sidecarURLs(forDatabase: dest)
        for extra in [sidecars.wal, sidecars.shm] {
            if FileManager.default.fileExists(atPath: extra.path) {
                throw DocumentIndexError.invalidArgument(
                    "публикация снимка оставила \(extra.lastPathComponent)"
                )
            }
        }
    }
}
