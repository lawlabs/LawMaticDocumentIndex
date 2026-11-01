import Foundation
import SQLite

/// IDs, workspace-relative paths and case-relative paths can share a key.
/// A later alias must never weaken an earlier document's transmission policy.
public enum CaseContextDocumentPolicy {
    public static func merge(_ policy: String, for key: String, into policies: inout [String: String]) {
        guard let previous = policies[key] else { policies[key] = policy; return }
        let rank = ["public": 0, "restricted": 1, "confidential": 2, "secret": 3]
        let oldRank = rank[previous] ?? 4
        let newRank = rank[policy] ?? 4
        if newRank > oldRank || (newRank == oldRank && policy < previous) { policies[key] = policy }
    }
}

/// A lightweight, consistent read of a case: no document text, chunks, vectors or anonymization maps.
public struct CaseContextRecord: Equatable, Sendable {
    public let record: CaseRecord
    public let rootRelativePath: String
    public let card: CaseCardRecord?
    public let items: [CaseListItemRecord]
    /// IDs and paths used only to check provenance of structured case items.
    public let documentPrivacy: [String: String]
}

extension DocumentIndexStore {
    public func caseContext(workspaceRootId: String, folderRelativePath: String) throws -> CaseContextRecord? {
        let connection = try db()
        let path = try SearchScope.validatedRelativePath(folderRelativePath)
        var snapshot: CaseContextRecord?
        try connection.transaction(.deferred) {
            let match: (CaseRecord, String)? = try Self.firstRow(connection, """
                SELECT c.id, c.workspace_root_id, c.root_folder_id, c.title, c.created_at_iso, c.updated_at_iso,
                       f.relative_path
                FROM cases c JOIN folders f ON f.id = c.root_folder_id
                WHERE c.workspace_root_id = ? AND
                    (f.relative_path = '' OR f.relative_path = ? OR substr(?, 1, length(f.relative_path) + 1) = f.relative_path || '/')
                ORDER BY length(f.relative_path) DESC LIMIT 1
                """, [workspaceRootId, path, path]) { reader in
                    (try Self.parseCase(reader), reader.string(6) ?? "")
                }
            guard let (record, rootPath) = match else { return }
            let card = try Self.caseCard(connection, caseId: record.id)
            var items: [CaseListItemRecord] = []
            for kind in CaseListKind.allCases { items += try caseListItems(caseId: record.id, kind: kind) }
            var privacy: [String: String] = [:]
            for row in try connection.prepare("""
                SELECT d.id, d.relative_path, d.absolute_path, COALESCE(m.confidentiality, 'public')
                FROM documents d LEFT JOIN document_user_metadata m ON m.document_id = d.id
                WHERE d.case_id = ? OR EXISTS (
                    SELECT 1 FROM case_document_links l WHERE l.case_id = ? AND l.document_id = d.id
                )
                """, record.id, record.id) {
                let level = row[3] as? String ?? "unknown"
                if let id = row[0] as? String { CaseContextDocumentPolicy.merge(level, for: id.lowercased(), into: &privacy) }
                if let relative = row[1] as? String {
                    CaseContextDocumentPolicy.merge(level, for: relative, into: &privacy)
                    if !rootPath.isEmpty, relative.hasPrefix(rootPath + "/") {
                        CaseContextDocumentPolicy.merge(level, for: String(relative.dropFirst(rootPath.count + 1)), into: &privacy)
                    }
                }
                if let absolute = row[2] as? String { CaseContextDocumentPolicy.merge(level, for: absolute, into: &privacy) }
            }
            snapshot = CaseContextRecord(record: record, rootRelativePath: rootPath,
                card: card, items: items, documentPrivacy: privacy)
        }
        return snapshot
    }
}
