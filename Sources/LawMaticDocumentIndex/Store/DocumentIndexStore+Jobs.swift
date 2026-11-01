import Foundation
import SQLite

extension DocumentIndexStore {
    /// Существующая активная задача (queued|running) на ту же цель и модель, иначе новая.
    @discardableResult
    public func enqueueJob(
        kind: IndexJobKind,
        target: String,
        modelId: String? = nil,
        priority: Int = 0
    ) throws -> IndexJobRecord {
        try write { db in
            try Self.enqueueJob(db, kind: kind, target: target, modelId: modelId, priority: priority).record
        }
    }

    /// Ставит embed-задачи для `text_hash` области с чанками без эмбеддинга. Один SQL на поиск целей.
    public func enqueueEmbedJobs(
        in scope: SearchScope,
        modelId: String,
        priority: Int = 0
    ) throws -> Int {
        try write { db in
            guard try Self.fetchEmbeddingModel(db, id: modelId) != nil else {
                throw DocumentIndexError.notFound(modelId)
            }
            let query = EmbeddingScopeSQL.uncoveredTextHashes(
                scope: scope,
                modelId: modelId,
                variantFilter: .original
            )
            var hashes: [String] = []
            for row in try db.prepare(query.sql, query.bindings) {
                if let hash = RowReader(row).string(0) {
                    hashes.append(hash)
                }
            }
            var created = 0
            for hash in hashes {
                if try Self.enqueueJob(
                    db,
                    kind: .embed,
                    target: IndexJobRecord.textTarget(hash),
                    modelId: modelId,
                    priority: priority
                ).isNew {
                    created += 1
                }
            }
            return created
        }
    }

    /// queued → running, attempts += 1; порядок priority DESC, created_at_iso.
    /// `modelId` ограничивает выборку задачами этой модели (для embed-очереди).
    public func claimNextJobs(
        kind: IndexJobKind,
        limit: Int,
        modelId: String? = nil,
        scope: SearchScope? = nil
    ) throws -> [IndexJobRecord] {
        guard limit > 0 else { return [] }
        return try write { db in
            var ids: [String] = []
            let scoped = ScopeSQL(scope: scope ?? .everything, includeCaseLinks: try currentCapabilities().supportsExplicitCaseDocuments)
            var sql = (scoped.cte.map { "WITH RECURSIVE " + $0 + " " } ?? "") + """
                SELECT id FROM index_jobs
                WHERE kind = ? AND state = 'queued'
                """
            if scope != nil { sql += """
                AND (kind != 'embed' OR target IN (
                    SELECT 'text:' || tv.text_hash FROM documents d
                    JOIN text_variants tv ON tv.document_id = d.id AND tv.is_current = 1
                    WHERE \(scoped.predicate)))
                """ }
            var selectBindings: [Binding] = scoped.cteBindings + [kind.rawValue] + scoped.predicateBindings
            if let modelId {
                sql += " AND model_id = ?"
                selectBindings.append(modelId)
            }
            sql += """
                
                ORDER BY priority DESC, created_at_iso
                LIMIT \(limit)
                """
            for row in try db.prepare(sql, selectBindings) {
                if let id = RowReader(row).string(0) {
                    ids.append(id)
                }
            }
            guard !ids.isEmpty else { return [] }

            let now = Self.iso(Date())
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            let updateBindings: [Binding?] = [now] + ids
            try db.run(
                """
                UPDATE index_jobs
                SET state = 'running', attempts = attempts + 1, updated_at_iso = ?
                WHERE id IN (\(placeholders))
                """,
                updateBindings
            )
            return try Self.fetchJobs(
                db,
                sql: """
                    SELECT \(Self.jobColumns)
                    FROM index_jobs
                    WHERE id IN (\(placeholders))
                    ORDER BY priority DESC, created_at_iso
                    """,
                bindings: ids.map { $0 as Binding }
            )
        }
    }

    /// Закрывает queued/running embed-задачи, чей text_hash больше не текущий.
    @discardableResult
    public func completeStaleEmbedJobs() throws -> Int {
        try write { db in
            try db.run(
                """
                UPDATE index_jobs
                SET state = 'done', last_error = NULL, updated_at_iso = ?
                WHERE kind = 'embed'
                  AND state IN ('queued', 'running')
                  AND (
                    target NOT LIKE 'text:%'
                    OR NOT EXISTS (
                      SELECT 1 FROM text_variants tv
                      WHERE tv.is_current = 1
                        AND tv.text_hash = substr(index_jobs.target, 6)
                    )
                  )
                """,
                Self.iso(Date())
            )
            return db.changes
        }
    }

    /// Yield between batches without charging a failed attempt.
    public func releaseJob(id: String) throws {
        try write { db in
            try db.run("UPDATE index_jobs SET state = 'queued', attempts = MAX(attempts - 1, 0), updated_at_iso = ? WHERE id = ? AND state = 'running'",
                Self.iso(Date()), id)
        }
    }

    public func completeJob(id: String) throws {
        try write { db in
            try db.run(
                """
                UPDATE index_jobs
                SET state = 'done', last_error = NULL, updated_at_iso = ?
                WHERE id = ?
                """,
                Self.iso(Date()),
                id
            )
            if db.changes == 0 {
                throw DocumentIndexError.notFound(id)
            }
        }
    }

    /// `requeue` = true → снова queued (с last_error); иначе failed.
    public func failJob(id: String, error: String, requeue: Bool) throws {
        try write { db in
            try db.run(
                """
                UPDATE index_jobs
                SET state = ?, last_error = ?, updated_at_iso = ?
                WHERE id = ?
                """,
                requeue ? IndexJobState.queued.rawValue : IndexJobState.failed.rawValue,
                error,
                Self.iso(Date()),
                id
            )
            if db.changes == 0 {
                throw DocumentIndexError.notFound(id)
            }
        }
    }

    /// Возвращает failed-задачи в очередь без смены attempts: ручной повтор.
    @discardableResult
    public func requeueFailedJobs(kind: IndexJobKind? = nil) throws -> Int {
        try write { db in
            if let kind {
                try db.run(
                    """
                    UPDATE index_jobs
                    SET state = 'queued', updated_at_iso = ?
                    WHERE state = 'failed' AND kind = ?
                    """,
                    Self.iso(Date()),
                    kind.rawValue
                )
            } else {
                try db.run(
                    """
                    UPDATE index_jobs
                    SET state = 'queued', updated_at_iso = ?
                    WHERE state = 'failed'
                    """,
                    Self.iso(Date())
                )
            }
            return db.changes
        }
    }

    /// При старте писателя: running → queued (процесс мог упасть).
    @discardableResult
    public func resetRunningJobs() throws -> Int {
        try write { db in
            try db.run(
                """
                UPDATE index_jobs
                SET state = 'queued', updated_at_iso = ?
                WHERE state = 'running'
                """,
                Self.iso(Date())
            )
            return db.changes
        }
    }

    public func jobs(
        kind: IndexJobKind? = nil,
        states: [IndexJobState]? = nil,
        limit: Int = 100
    ) throws -> [IndexJobRecord] {
        var sql = "SELECT \(Self.jobColumns) FROM index_jobs WHERE 1 = 1"
        var bindings: [Binding] = []
        if let kind {
            sql += " AND kind = ?"
            bindings.append(kind.rawValue)
        }
        if let states {
            if states.isEmpty {
                sql += " AND 0 = 1"
            } else {
                let placeholders = Array(repeating: "?", count: states.count).joined(separator: ", ")
                sql += " AND state IN (\(placeholders))"
                bindings.append(contentsOf: states.map { $0.rawValue as Binding })
            }
        }
        sql += " ORDER BY priority DESC, created_at_iso LIMIT \(max(limit, 0))"
        return try Self.fetchJobs(try db(), sql: sql, bindings: bindings)
    }

    public func jobCounts(kind: IndexJobKind? = nil) throws -> [IndexJobState: Int] {
        var sql = "SELECT state, COUNT(*) FROM index_jobs"
        var bindings: [Binding] = []
        if let kind {
            sql += " WHERE kind = ?"
            bindings.append(kind.rawValue)
        }
        sql += " GROUP BY state"
        var counts: [IndexJobState: Int] = [:]
        for row in try db().prepare(sql, bindings) {
            let reader = RowReader(row)
            guard let raw = reader.string(0), let state = IndexJobState(rawValue: raw) else { continue }
            counts[state] = reader.int(1) ?? 0
        }
        return counts
    }

    @discardableResult
    public func purgeFinishedJobs(olderThan date: Date) throws -> Int {
        try write { db in
            try db.run(
                """
                DELETE FROM index_jobs
                WHERE state IN ('done', 'failed') AND updated_at_iso < ?
                """,
                Self.iso(date)
            )
            return db.changes
        }
    }

    // MARK: Запись на соединении

    private static let jobColumns = """
        id, kind, target, model_id, priority, state, attempts, last_error, created_at_iso, updated_at_iso
        """

    fileprivate static func enqueueJob(
        _ db: SQLite.Connection,
        kind: IndexJobKind,
        target: String,
        modelId: String?,
        priority: Int
    ) throws -> (record: IndexJobRecord, isNew: Bool) {
        if let existing = try fetchActiveJob(db, kind: kind, target: target, modelId: modelId) {
            return (existing, false)
        }
        let now = iso(Date())
        let id = UUID().uuidString
        let modelBinding: Binding? = modelId
        try db.run(
            """
            INSERT INTO index_jobs(
                id, kind, target, model_id, priority, state, attempts, last_error, created_at_iso, updated_at_iso
            ) VALUES (?, ?, ?, ?, ?, 'queued', 0, NULL, ?, ?)
            """,
            id, kind.rawValue, target, modelBinding, Int64(priority), now, now
        )
        guard let record = try fetchJob(db, id: id) else {
            throw DocumentIndexError.notFound(id)
        }
        return (record, true)
    }

    private static func fetchActiveJob(
        _ db: SQLite.Connection,
        kind: IndexJobKind,
        target: String,
        modelId: String?
    ) throws -> IndexJobRecord? {
        for row in try db.prepare(
            """
            SELECT \(jobColumns)
            FROM index_jobs
            WHERE kind = ? AND target = ? AND COALESCE(model_id, '') = ?
              AND state IN ('queued', 'running')
            LIMIT 1
            """,
            kind.rawValue, target, modelId ?? ""
        ) {
            return job(from: RowReader(row))
        }
        return nil
    }

    private static func fetchJob(_ db: SQLite.Connection, id: String) throws -> IndexJobRecord? {
        for row in try db.prepare("SELECT \(jobColumns) FROM index_jobs WHERE id = ?", id) {
            return job(from: RowReader(row))
        }
        return nil
    }

    private static func fetchJobs(
        _ db: SQLite.Connection,
        sql: String,
        bindings: [Binding]
    ) throws -> [IndexJobRecord] {
        var records: [IndexJobRecord] = []
        for row in try db.prepare(sql, bindings) {
            if let record = job(from: RowReader(row)) {
                records.append(record)
            }
        }
        return records
    }

    private static func job(from reader: RowReader) -> IndexJobRecord? {
        guard let id = reader.string(0),
              let kindRaw = reader.string(1),
              let kind = IndexJobKind(rawValue: kindRaw),
              let target = reader.string(2),
              let priority = reader.int(4),
              let stateRaw = reader.string(5),
              let state = IndexJobState(rawValue: stateRaw),
              let attempts = reader.int(6),
              let createdAt = reader.date(8),
              let updatedAt = reader.date(9) else {
            return nil
        }
        return IndexJobRecord(
            id: id,
            kind: kind,
            target: target,
            modelId: reader.string(3),
            priority: priority,
            state: state,
            attempts: attempts,
            lastError: reader.string(7),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
