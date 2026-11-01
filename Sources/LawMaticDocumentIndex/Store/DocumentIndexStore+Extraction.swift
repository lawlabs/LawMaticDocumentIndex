import Foundation
import SQLite

extension DocumentIndexStore {

    public func setExtractionState(_ state: ExtractionState) throws {
        try write { db in
            if state.status != .complete && state.status != .partial {
                try Self.invalidateCurrentText(db, documentId: state.documentId)
            }
            try Self.setExtractionState(db, state)
        }
    }

    public func extractionState(documentId: String) throws -> ExtractionState? {
        try Self.extractionState(try db(), documentId: documentId)
    }

    public func extractionStates(
        in scope: SearchScope,
        statuses: [ExtractionStatus]? = nil
    ) throws -> [ExtractionState] {
        try Self.extractionStates(try db(), scope: scope, statuses: statuses, includeCaseLinks: try currentCapabilities().supportsExplicitCaseDocuments)
    }

    public func extractionStatusCounts(in scope: SearchScope) throws -> [ExtractionStatus: Int] {
        try Self.extractionStatusCounts(try db(), scope: scope, includeCaseLinks: try currentCapabilities().supportsExplicitCaseDocuments)
    }

    public func documentsNeedingExtraction(
        in scope: SearchScope,
        extractorVersions: [String: Int] = [:],
        limit: Int = 500
    ) throws -> [IndexedDocument] {
        try Self.documentsNeedingExtraction(
            try db(),
            scope: scope,
            extractorVersions: extractorVersions,
            limit: max(limit, 0), includeCaseLinks: try currentCapabilities().supportsExplicitCaseDocuments
        )
    }

    public func markExtractionPending(documentIds: [String]) throws {
        guard !documentIds.isEmpty else { return }
        try write { db in
            try Self.markExtractionPending(db, documentIds: documentIds)
        }
    }
}

extension DocumentIndexStore {

    static let extractionColumns = """
        e.document_id, e.status, e.extractor_id, e.extractor_version, e.method_label, \
        e.pages_total, e.pages_processed, e.error_code, e.error_message, \
        e.attempts, e.next_retry_after_iso, e.finished_at_iso
        """

    static func parseExtractionState(_ reader: RowReader) throws -> ExtractionState {
        guard let documentId = reader.string(0),
              let statusRaw = reader.string(1),
              let status = ExtractionStatus(rawValue: statusRaw),
              let attempts = reader.int(9) else {
            throw DocumentIndexError.invalidArgument("неполная строка состояния извлечения")
        }
        return ExtractionState(
            documentId: documentId,
            status: status,
            extractorId: reader.string(2),
            extractorVersion: reader.int(3),
            methodLabel: reader.string(4),
            pagesTotal: reader.int(5),
            pagesProcessed: reader.int(6),
            errorCode: reader.string(7),
            errorMessage: reader.string(8),
            attempts: attempts,
            nextRetryAfter: reader.date(10),
            finishedAt: reader.date(11)
        )
    }

    static func extractionState(_ db: SQLite.Connection, documentId: String) throws -> ExtractionState? {
        try firstRow(
            db,
            "SELECT \(extractionColumns) FROM extraction_state e WHERE e.document_id = ?",
            [documentId],
            parse: parseExtractionState
        )
    }

    static func setExtractionState(_ db: SQLite.Connection, _ state: ExtractionState) throws {
        guard try document(db, id: state.documentId) != nil else {
            throw DocumentIndexError.notFound("документ \(state.documentId)")
        }
        try db.run(
            """
            INSERT INTO extraction_state(
                document_id, status, extractor_id, extractor_version, method_label,
                pages_total, pages_processed, error_code, error_message,
                attempts, next_retry_after_iso, finished_at_iso
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(document_id) DO UPDATE SET
                status = excluded.status,
                extractor_id = excluded.extractor_id,
                extractor_version = excluded.extractor_version,
                method_label = excluded.method_label,
                pages_total = excluded.pages_total,
                pages_processed = excluded.pages_processed,
                error_code = excluded.error_code,
                error_message = excluded.error_message,
                attempts = excluded.attempts,
                next_retry_after_iso = excluded.next_retry_after_iso,
                finished_at_iso = excluded.finished_at_iso
            """,
            [
                state.documentId,
                state.status.rawValue,
                state.extractorId,
                state.extractorVersion.map { Int64($0) },
                state.methodLabel,
                state.pagesTotal.map { Int64($0) },
                state.pagesProcessed.map { Int64($0) },
                state.errorCode,
                state.errorMessage,
                Int64(state.attempts),
                state.nextRetryAfter.map(iso),
                state.finishedAt.map(iso),
            ]
        )
    }

    static func extractionStates(
        _ db: SQLite.Connection,
        scope: SearchScope,
        statuses: [ExtractionStatus]?, includeCaseLinks: Bool
    ) throws -> [ExtractionState] {
        let fragment = ScopeSQL(scope: scope, includeCaseLinks: includeCaseLinks)
        var sql = fragment.withClause + """
            SELECT \(extractionColumns)
            FROM extraction_state e
            JOIN documents d ON d.id = e.document_id
            WHERE \(fragment.predicate)
            """
        var bindings = boxed(fragment.bindings)
        if let statuses {
            if statuses.isEmpty {
                sql += " AND 0 = 1"
            } else {
                let placeholders = Array(repeating: "?", count: statuses.count).joined(separator: ", ")
                sql += " AND e.status IN (\(placeholders))"
                bindings.append(contentsOf: statuses.map { $0.rawValue as Binding? })
            }
        }
        sql += " ORDER BY e.document_id"
        return try allRows(db, sql, bindings, parse: parseExtractionState)
    }

    static func extractionStatusCounts(
        _ db: SQLite.Connection,
        scope: SearchScope, includeCaseLinks: Bool
    ) throws -> [ExtractionStatus: Int] {
        var counts = Dictionary(uniqueKeysWithValues: ExtractionStatus.allCases.map { ($0, 0) })
        let fragment = ScopeSQL(scope: scope, includeCaseLinks: includeCaseLinks)
        let sql = fragment.withClause + """
            SELECT e.status, COUNT(*)
            FROM extraction_state e
            JOIN documents d ON d.id = e.document_id
            WHERE \(fragment.predicate)
            GROUP BY e.status
            """
        for row in try db.prepare(sql, boxed(fragment.bindings)) {
            let reader = RowReader(row)
            guard let raw = reader.string(0), let status = ExtractionStatus(rawValue: raw) else { continue }
            counts[status] = reader.int(1) ?? 0
        }
        return counts
    }

    static func documentsNeedingExtraction(
        _ db: SQLite.Connection,
        scope: SearchScope,
        extractorVersions: [String: Int],
        limit: Int, includeCaseLinks: Bool
    ) throws -> [IndexedDocument] {
        let fragment = ScopeSQL(scope: scope, includeCaseLinks: includeCaseLinks)
        let now = iso(Date())
        var versionClause = "0 = 1"
        var versionBindings: [Binding?] = []
        if !extractorVersions.isEmpty {
            let parts = extractorVersions.map { _ in
                "(e.extractor_id = ? AND (e.extractor_version IS NULL OR e.extractor_version < ?))"
            }
            versionClause = parts.joined(separator: " OR ")
            for (extractorId, version) in extractorVersions {
                versionBindings.append(extractorId)
                versionBindings.append(Int64(version))
            }
        }

        let sql = fragment.withClause + """
            SELECT \(documentColumns)
            FROM documents d
            LEFT JOIN extraction_state e ON e.document_id = d.id
            WHERE \(fragment.predicate)
              AND (
                    e.document_id IS NULL
                 OR e.status = 'pending'
                 OR (
                        e.status IN ('failed', 'partial')
                    AND (e.next_retry_after_iso IS NULL OR e.next_retry_after_iso <= ?)
                    AND (e.error_code IS NULL OR e.error_code NOT IN ('ocr_disabled', 'unsupported_format'))
                    )
                 OR (e.status = 'complete' AND (\(versionClause)))
              )
            ORDER BY COALESCE(d.relative_path, d.absolute_path)
            LIMIT \(limit)
            """
        var bindings = boxed(fragment.bindings)
        bindings.append(now)
        bindings.append(contentsOf: versionBindings)
        return try allDocuments(db, sql, bindings)
    }

    static func markExtractionPending(_ db: SQLite.Connection, documentIds: [String]) throws {
        for documentId in documentIds {
            guard try document(db, id: documentId) != nil else {
                throw DocumentIndexError.notFound("документ \(documentId)")
            }
            try db.run(
                """
                INSERT INTO extraction_state(document_id, status, attempts)
                VALUES (?, 'pending', 0)
                ON CONFLICT(document_id) DO UPDATE SET
                    status = 'pending',
                    next_retry_after_iso = NULL
                """,
                documentId
            )
        }
    }
}
