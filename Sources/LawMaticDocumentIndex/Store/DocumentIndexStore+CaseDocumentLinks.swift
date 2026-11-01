import Foundation
import SQLite

public struct CaseDocumentLink: Equatable, Sendable {
    public let caseId: String
    public let documentId: String
    public let attachedAt: Date
    public let sortIndex: Int
}

extension DocumentIndexStore {
    @discardableResult
    public func attachDocument(documentId: String, toCase caseId: String) throws -> CaseDocumentLink {
        try write { db in
            try Self.requireCase(db, id: caseId)
            guard try Self.document(db, id: documentId) != nil else { throw DocumentIndexError.notFound("документ \(documentId)") }
            if let existing = try Self.caseDocumentLinks(db, caseId: caseId, documentId: documentId).first { return existing }
            let index = (try db.scalar("SELECT MAX(sort_index) FROM case_document_links WHERE case_id = ?", caseId) as? Int64).map { $0 + 1 } ?? 0
            try db.run("INSERT INTO case_document_links(case_id, document_id, attached_at_iso, sort_index) VALUES (?, ?, ?, ?)",
                       caseId, documentId, Self.iso(Date()), index)
            return try Self.caseDocumentLinks(db, caseId: caseId, documentId: documentId)[0]
        }
    }

    public func detachDocument(documentId: String, fromCase caseId: String) throws {
        try write { db in
            try db.run("DELETE FROM case_document_links WHERE case_id = ? AND document_id = ?", caseId, documentId)
        }
    }

    public func caseDocumentLinks(caseId: String) throws -> [CaseDocumentLink] {
        let db = try db()
        guard try currentCapabilities().supportsExplicitCaseDocuments else { return [] }
        return try Self.caseDocumentLinks(db, caseId: caseId, documentId: nil)
    }

    public func documentCaseLinks(documentId: String) throws -> [CaseDocumentLink] {
        let db = try db()
        guard try currentCapabilities().supportsExplicitCaseDocuments else { return [] }
        return try Self.caseDocumentLinks(db, caseId: nil, documentId: documentId)
    }

    private static func caseDocumentLinks(_ db: SQLite.Connection, caseId: String?, documentId: String?) throws -> [CaseDocumentLink] {
        var conditions: [String] = [], values: [Binding?] = []
        if let caseId { conditions.append("case_id = ?"); values.append(caseId) }
        if let documentId { conditions.append("document_id = ?"); values.append(documentId) }
        let sql = "SELECT case_id, document_id, attached_at_iso, sort_index FROM case_document_links WHERE "
            + conditions.joined(separator: " AND ") + " ORDER BY sort_index, document_id, case_id"
        return try allRows(db, sql, values) { row in
            CaseDocumentLink(caseId: row.string(0) ?? "", documentId: row.string(1) ?? "",
                             attachedAt: try requireDate(row, 2, field: "attached_at_iso"), sortIndex: row.int(3) ?? 0)
        }
    }
}
