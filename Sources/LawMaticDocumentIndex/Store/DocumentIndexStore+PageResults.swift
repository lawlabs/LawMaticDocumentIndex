import Foundation
import SQLite

extension DocumentIndexStore {
    public func replaceExtractionPageResults(
        documentId: String,
        sourceFileHash: String,
        configId: String,
        pages: [ExtractionPageResult]
    ) throws {
        try write { db in
            guard try Self.document(db, id: documentId) != nil else {
                throw DocumentIndexError.notFound("документ \(documentId)")
            }
            try db.run(
                """
                DELETE FROM extraction_page_results
                WHERE document_id = ? AND source_file_hash = ? AND extraction_config_id = ?
                """,
                documentId, sourceFileHash, configId
            )
            let now = Self.iso(Date())
            for page in pages {
                try db.run(
                    """
                    INSERT INTO extraction_page_results(
                        document_id, source_file_hash, extraction_config_id, page_number,
                        text, status, method, error_code, error_message, updated_at_iso
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    documentId, sourceFileHash, configId, Int64(page.pageNumber),
                    page.text, page.status.rawValue, page.method, page.errorCode,
                    page.errorMessage, now
                )
            }
        }
    }

    public func upsertExtractionPageResult(
        documentId: String,
        sourceFileHash: String,
        configId: String,
        page: ExtractionPageResult
    ) throws {
        try write { db in
            guard try Self.document(db, id: documentId) != nil else {
                throw DocumentIndexError.notFound("документ \(documentId)")
            }
            let now = Self.iso(Date())
            try db.run(
                """
                INSERT INTO extraction_page_results(
                    document_id, source_file_hash, extraction_config_id, page_number,
                    text, status, method, error_code, error_message, updated_at_iso
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(document_id, source_file_hash, extraction_config_id, page_number)
                DO UPDATE SET
                    text = excluded.text,
                    status = excluded.status,
                    method = excluded.method,
                    error_code = excluded.error_code,
                    error_message = excluded.error_message,
                    updated_at_iso = excluded.updated_at_iso
                """,
                documentId, sourceFileHash, configId, Int64(page.pageNumber),
                page.text, page.status.rawValue, page.method, page.errorCode,
                page.errorMessage, now
            )
        }
    }

    public func extractionPageResults(
        documentId: String,
        sourceFileHash: String,
        configId: String
    ) throws -> [ExtractionPageResult] {
        try Self.allRows(
            try db(),
            """
            SELECT page_number, text, status, method, error_code, error_message
            FROM extraction_page_results
            WHERE document_id = ? AND source_file_hash = ? AND extraction_config_id = ?
            ORDER BY page_number
            """,
            [documentId, sourceFileHash, configId],
            parse: Self.parseExtractionPageResult
        )
    }

    static func parseExtractionPageResult(_ reader: RowReader) throws -> ExtractionPageResult {
        guard let number = reader.int(0),
              let statusRaw = reader.string(2),
              let status = ExtractionStatus(rawValue: statusRaw) else {
            throw DocumentIndexError.invalidArgument("неполный результат страницы")
        }
        return ExtractionPageResult(
            pageNumber: number,
            text: reader.string(1) ?? "",
            status: status,
            method: reader.string(3),
            errorCode: reader.string(4),
            errorMessage: reader.string(5)
        )
    }
}
