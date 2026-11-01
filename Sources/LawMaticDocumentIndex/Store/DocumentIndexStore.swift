import Foundation
import SQLite

public enum DocumentIndexOpenMode: Sendable {
    /// Единственный писатель (Finder). Создаёт файл и схему, если их нет.
    case readWrite
    /// Внешние клиенты (B2, Lite, MCP): `SQLITE_OPEN_READONLY`, ничего не создаёт и не чинит.
    case readOnly
}

public enum DocumentIndexError: Error, Sendable, Equatable, LocalizedError {
    case incompatibleDatabase(applicationID: Int32, userVersion: Int32)
    case databaseMissing(path: String)
    case notOpen
    case readOnly
    case notFound(String)
    case invalidArgument(String)
    case integrityCheckFailed([String])
    /// Commit относился к предыдущему поколению файла (сброс/замена базы).
    case staleWriterGeneration

    public var errorDescription: String? {
        switch self {
        case let .incompatibleDatabase(applicationID, userVersion):
            return "несовместимая база (application_id=\(applicationID), user_version=\(userVersion))"
        case let .databaseMissing(path):
            return "файл базы не найден: \(path)"
        case .notOpen:
            return "база не открыта"
        case .readOnly:
            return "запись запрещена: база открыта только для чтения"
        case let .notFound(id):
            return "не найдено: \(id)"
        case let .invalidArgument(message):
            return message
        case let .integrityCheckFailed(issues):
            return "нарушена целостность: \(issues.joined(separator: "; "))"
        case .staleWriterGeneration:
            return "задание относится к предыдущему поколению индекса"
        }
    }
}

/// Хранилище базы текстов документов (схема v2).
///
/// Actor сериализует доступ к одному соединению SQLite. Операции по областям
/// (каталог, тексты, эмбеддинги, очередь) живут в расширениях в соседних файлах;
/// здесь — открытие файла, PRAGMA-политика, идентичность схемы и общие помощники.
public actor DocumentIndexStore {
    public let databaseURL: URL
    public let mode: DocumentIndexOpenMode
    /// Идентификатор приложения-писателя: `owner_app`, `created_by_app`, manifest.
    public let writerAppId: String

    // Device-local bindings are never persisted in the shared database.
    var localWorkspacePaths: [String: String]
    var connection: SQLite.Connection?
    private var transactionDepth = 0
    var cachedReaderCapabilities: (dataVersion: Int64, value: DocumentIndexReaderCapabilities)?
    private(set) var capabilityReadCount = 0

    func noteCapabilityRead() { capabilityReadCount += 1 }
    private let connectionObserver: (@Sendable (URL, DocumentIndexOpenMode) -> Void)?
    /// Сколько раз вызывали `rebuildChunkFTS` за жизнь actor. Для тестов:
    /// `attachText` нового текста не должен переписывать FTS повторно.
    private(set) var chunkFTSRebuildCount = 0

    func noteChunkFTSRebuild() {
        chunkFTSRebuildCount += 1
    }

    public init(
        databaseURL: URL,
        mode: DocumentIndexOpenMode = .readWrite,
        writerAppId: String = "lawmatic-finder",
        workspacePaths: [String: String] = [:],
        connectionObserver: (@Sendable (URL, DocumentIndexOpenMode) -> Void)? = nil
    ) {
        self.connectionObserver = connectionObserver
        self.databaseURL = databaseURL
        self.mode = mode
        self.writerAppId = writerAppId
        self.localWorkspacePaths = workspacePaths.mapValues(Self.normalizeLocalPath)
    }

    public var isOpen: Bool { connection != nil }

    public func open() throws {
        if connection != nil { return }

        switch mode {
        case .readWrite:
            connection = try openWritable()
        case .readOnly:
            connection = try openReadOnly()
        }
        do { _ = try currentCapabilities() }
        catch { connection = nil; cachedReaderCapabilities = nil; throw error }
    }

    public func close() {
        connection = nil
        cachedReaderCapabilities = nil
    }

    // MARK: Открытие

    private func openWritable() throws -> SQLite.Connection {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let db = try SQLite.Connection(databaseURL.path)
        connectionObserver?(databaseURL, .readWrite)
        let isEmptyFile = try Self.pragmaInt64(db, "page_count") == 0
        if isEmptyFile {
            // Режим auto_vacuum фиксируется первой же записью в заголовок файла
            // (в том числе journal_mode=WAL), поэтому выставляется до всех остальных PRAGMA.
            try db.execute("PRAGMA auto_vacuum = INCREMENTAL;")
        }
        if !isEmptyFile {

            try Self.verifyIdentity(db)
            if let value = try db.scalar("SELECT value FROM index_metadata WHERE key = ?", DocumentIndexSchema.MetadataKey.finderExtensionVersion) as? String {
                guard let version = Int(value), version <= DocumentIndexSchema.finderExtensionVersion else {
                    throw DocumentIndexError.invalidArgument("Обновите Finder: версия расширений индекса новее поддерживаемой.")
                }
            }
            _ = try Self.readCapabilities(db)
        }
        try db.execute("PRAGMA journal_mode = WAL;")
        try Self.applySharedPragmas(db)
        if isEmptyFile {
            try db.execute("PRAGMA application_id = \(DocumentIndexSchema.applicationID);")
            try db.execute("PRAGMA user_version = \(DocumentIndexSchema.userVersion);")
        }

        // Внутри замыкания нет обращений к self: иначе оно становится изолированным
        // на actor, и компилятор запрещает передавать в него не-Sendable соединение.
        let writerAppId = self.writerAppId
        try db.transaction(.immediate) {
            try DocumentIndexSchema.create(in: db)
            try db.run("UPDATE workspace_roots SET local_path = '' WHERE local_path != ''")
            let now = Self.iso(Date())
            // Upgrade earlier v2 removal markers atomically. No legacy file is opened.
            if try db.scalar("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'import_exclusions'") != nil {
                try db.run("INSERT OR IGNORE INTO index_removals(root_id, path, removed_at_iso) SELECT root_id, path, ? FROM import_exclusions", now)
                try db.run("DROP TABLE import_exclusions")
            }

            if isEmptyFile {
                try Self.writeMetadata(db, DocumentIndexSchema.MetadataKey.schemaCreatedAt, now, now: now)
                try Self.writeMetadata(db, DocumentIndexSchema.MetadataKey.writerAppId, writerAppId, now: now)
                try Self.writeMetadata(
                    db, DocumentIndexSchema.MetadataKey.ftsNormalizerVersion,
                    String(DocumentIndexSchema.ftsNormalizerVersion), now: now
                )
                try Self.writeMetadata(
                    db, DocumentIndexSchema.MetadataKey.chunkingVersion,
                    String(DocumentIndexSchema.chunkingVersion), now: now
                )
                try Self.writeMetadata(
                    db, DocumentIndexSchema.MetadataKey.indexGeneration,
                    UUID().uuidString, now: now
                )
            }
            try Self.writeMetadata(
                db, DocumentIndexSchema.MetadataKey.finderExtensionVersion,
                String(DocumentIndexSchema.finderExtensionVersion), now: now
            )
            try Self.writeMetadata(db, DocumentIndexSchema.MetadataKey.readerRequiredFeatures,
                "[\"explicit_case_documents\"]", now: now)
        }
        return db
    }

    private func openReadOnly() throws -> SQLite.Connection {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw DocumentIndexError.databaseMissing(path: databaseURL.path)
        }
        let db = try SQLite.Connection(databaseURL.path, readonly: true)
        connectionObserver?(databaseURL, .readOnly)
        try Self.applySharedPragmas(db)
        try Self.verifyIdentity(db)
        guard try db.scalar("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'variant_pages'") != nil else {
            throw DocumentIndexError.invalidArgument("Индекс требует обновления в LawMatic Finder и нового снимка базы")
        }
        _ = try Self.readCapabilities(db)
        return db
    }

    /// PRAGMA, общие для писателя и читателей; `journal_mode` читатель не трогает.
    private static func applySharedPragmas(_ db: SQLite.Connection) throws {
        try db.execute("PRAGMA foreign_keys = ON;")
        try db.execute("PRAGMA synchronous = NORMAL;")
        db.busyTimeout = 5
    }

    /// Любой непустой файл с чужой идентичностью (включая базу v1 с нулевыми
    /// application_id/user_version) отвергается — «починка» недопустима по контракту.
    private static func verifyIdentity(_ db: SQLite.Connection) throws {
        let applicationID = Int32(truncatingIfNeeded: try pragmaInt64(db, "application_id"))
        let userVersion = Int32(truncatingIfNeeded: try pragmaInt64(db, "user_version"))
        if applicationID != DocumentIndexSchema.applicationID
            || userVersion != DocumentIndexSchema.userVersion {
            throw DocumentIndexError.incompatibleDatabase(
                applicationID: applicationID,
                userVersion: userVersion
            )
        }
    }

    // MARK: Служебные операции

    /// Счётчик изменений файла другими соединениями (`PRAGMA data_version`):
    /// читатель сравнивает значение между опросами и понимает, что база изменилась.
    public func dataVersion() throws -> Int64 {
        try Self.pragmaInt64(try db(), "data_version")
    }

    /// Поколение файла. При атомарной замене sqlite `data_version` не помогает.
    public func indexGeneration() throws -> String? {
        try metadata(DocumentIndexSchema.MetadataKey.indexGeneration)
    }

    public func metadata(_ key: String) throws -> String? {
        let db = try db()
        for row in try db.prepare("SELECT value FROM index_metadata WHERE key = ?", key) {
            return row[0] as? String
        }
        return nil
    }

    public func setMetadata(_ key: String, _ value: String) throws {
        try write { db in
            try Self.writeMetadata(db, key, value, now: Self.iso(Date()))
        }
        if key == DocumentIndexSchema.MetadataKey.finderExtensionVersion || key == DocumentIndexSchema.MetadataKey.readerRequiredFeatures {
            cachedReaderCapabilities = nil
        }
    }

    /// Пустой массив — база целостна; иначе строки отчёта `PRAGMA integrity_check`.
    public func integrityCheck() throws -> [String] {
        let db = try db()
        var issues: [String] = []
        for row in try db.prepare("PRAGMA integrity_check") {
            if let line = row[0] as? String, line != "ok" {
                issues.append(line)
            }
        }
        return issues
    }

    /// Возвращает освобождённые страницы файловой системе (после массовых удалений).
    public func incrementalVacuum(pages: Int? = nil) throws {
        try requireWritable()
        if let pages {
            try db().execute("PRAGMA incremental_vacuum(\(max(pages, 0)));")
        } else {
            try db().execute("PRAGMA incremental_vacuum;")
        }
    }

    /// Убирает тексты, на которые больше не ссылается ни один вариант:
    /// чанки, FTS-строки и эмбеддинги уходят каскадом и явным удалением из contentless FTS.
    @discardableResult
    public func collectOrphanTexts() throws -> Int {
        try write { db in
            let orphanSQL = """
                SELECT t.text_hash FROM texts t
                WHERE NOT EXISTS (SELECT 1 FROM text_variants v WHERE v.text_hash = t.text_hash)
                  AND NOT EXISTS (SELECT 1 FROM text_variant_history h WHERE h.text_hash = t.text_hash)
                """
            var orphans: [String] = []
            for row in try db.prepare(orphanSQL) {
                if let hash = row[0] as? String { orphans.append(hash) }
            }
            for hash in orphans {
                try db.run(
                    "DELETE FROM chunk_fts WHERE rowid IN (SELECT rowid FROM chunks WHERE text_hash = ?)",
                    hash
                )
                try db.run("DELETE FROM texts WHERE text_hash = ?", hash)
            }
            return orphans.count
        }
    }

    // MARK: Помощники для расширений

    func db() throws -> SQLite.Connection {
        guard let connection else { throw DocumentIndexError.notOpen }
        return connection
    }

    func requireWritable() throws {
        guard mode == .readWrite else { throw DocumentIndexError.readOnly }
    }

    func validateMutation(_ guardValue: DocumentIndexMutationGuard?, db: SQLite.Connection) throws {
        guard let guardValue else { return }
        try guardValue.validate(currentGeneration: try db.scalar("SELECT value FROM index_metadata WHERE key = ?", DocumentIndexSchema.MetadataKey.indexGeneration) as? String)
    }

    /// Пишущая транзакция `BEGIN IMMEDIATE`: блокировка берётся сразу, а не при
    /// первой записи, чтобы в WAL не получить `SQLITE_BUSY` в середине работы.
    /// Вложенный вызов становится `SAVEPOINT` внутри внешней транзакции, поэтому
    /// операции store можно свободно комбинировать друг с другом.
    @discardableResult
    func write<T>(_ body: (SQLite.Connection) throws -> T) throws -> T {
        try requireWritable()
        let db = try db()
        var result: T?
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        if transactionDepth > 1 {
            try db.savepoint {
                result = try body(db)
            }
        } else {
            try db.transaction(.immediate) {
                result = try body(db)
            }
        }
        guard let result else { throw DocumentIndexError.notOpen }
        return result
    }

    static func writeMetadata(_ db: SQLite.Connection, _ key: String, _ value: String, now: String) throws {
        try db.run(
            """
            INSERT INTO index_metadata(key, value, updated_at_iso) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at_iso = excluded.updated_at_iso
            """,
            key, value, now
        )
    }

    static func pragmaInt64(_ db: SQLite.Connection, _ name: String) throws -> Int64 {
        let value = try db.scalar("PRAGMA \(name)")
        if let int64 = value as? Int64 { return int64 }
        if let int = value as? Int { return Int64(int) }
        return 0
    }

    // MARK: Текст

    /// Вырезает фрагмент по UTF-16-смещениям чанка/страницы из канонического текста.
    /// Некорректные границы обрезаются до длины текста, а не приводят к падению.
    static func slice(_ content: String, utf16Start: Int, utf16End: Int) -> String {
        let nsContent = content as NSString
        let start = min(max(utf16Start, 0), nsContent.length)
        let end = min(max(utf16End, start), nsContent.length)
        return nsContent.substring(with: NSRange(location: start, length: end - start))
    }

    // MARK: Даты

    private static let isoWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle()

    static func iso(_ date: Date) -> String {
        isoWithFraction.format(date)
    }

    static func date(fromISO string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let date = try? isoWithFraction.parse(string) { return date }
        return try? isoPlain.parse(string)
    }
}

// MARK: - Чтение строк

/// Тонкая обёртка над `[Binding?]`, чтобы расширения store не повторяли приведения типов.
struct RowReader {
    let row: [Binding?]

    init(_ row: [Binding?]) { self.row = row }

    func string(_ index: Int) -> String? { row[index] as? String }

    func int64(_ index: Int) -> Int64? {
        if let value = row[index] as? Int64 { return value }
        if let value = row[index] as? Int { return Int64(value) }
        return nil
    }

    func int(_ index: Int) -> Int? { int64(index).map(Int.init) }

    func double(_ index: Int) -> Double? {
        if let value = row[index] as? Double { return value }
        return int64(index).map(Double.init)
    }

    func bool(_ index: Int) -> Bool { (int64(index) ?? 0) != 0 }

    func blob(_ index: Int) -> Data? {
        guard let blob = row[index] as? Blob else { return nil }
        return Data(blob.bytes)
    }

    func date(_ index: Int) -> Date? { DocumentIndexStore.date(fromISO: string(index)) }
}
