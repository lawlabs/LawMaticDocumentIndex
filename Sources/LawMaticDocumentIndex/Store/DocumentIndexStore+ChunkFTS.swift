import Foundation
import SQLite

extension DocumentIndexStore {

    /// Нормализованные имена всех документов с текущим вариантом этого текста,
    /// в порядке `file_name`, через пробел. Как в v1: нормализуем `file_name`
    /// целиком, включая расширение.
    static func fileNamesNorm(_ db: SQLite.Connection, textHash: String) throws -> String {
        var names: [String] = []
        for row in try db.prepare(
            """
            SELECT DISTINCT d.file_name
            FROM text_variants tv
            JOIN documents d ON d.id = tv.document_id
            WHERE tv.text_hash = ? AND tv.is_current = 1
            ORDER BY d.file_name
            """,
            textHash
        ) {
            if let name = RowReader(row).string(0) {
                names.append(name)
            }
        }
        return joinedFileNamesNorm(names)
    }

    /// Склеивает уже выбранные имена так же, как `fileNamesNorm`
    /// (`DISTINCT` + `ORDER BY file_name`, затем нормализация).
    static func joinedFileNamesNorm(_ fileNames: [String]) -> String {
        Array(Set(fileNames)).sorted()
            .map { RussianTextNormalizer.normalizeForIndex($0) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Contentless FTS нельзя UPDATE: удаляем строки текста и пишем заново.
    /// `content_norm` читается из `texts.content` по смещениям чанка.
    static func rebuildChunkFTS(_ db: SQLite.Connection, textHash: String) throws {
        try db.run(
            "DELETE FROM chunk_fts WHERE rowid IN (SELECT rowid FROM chunks WHERE text_hash = ?)",
            textHash
        )
        guard let content = try textContent(db, hash: textHash) else { return }
        let fileNameNorm = try fileNamesNorm(db, textHash: textHash)
        for row in try db.prepare(
            """
            SELECT rowid, utf16_start, utf16_end
            FROM chunks WHERE text_hash = ? ORDER BY chunk_index
            """,
            textHash
        ) {
            let reader = RowReader(row)
            guard let rowid = reader.int64(0),
                  let utf16Start = reader.int(1),
                  let utf16End = reader.int(2) else { continue }
            try db.run(
                "INSERT INTO chunk_fts(rowid, file_name_norm, content_norm) VALUES (?, ?, ?)",
                rowid,
                fileNameNorm,
                RussianTextNormalizer.normalizeForIndex(slice(content, utf16Start: utf16Start, utf16End: utf16End))
            )
        }
    }

    func rebuildChunkFTS(_ db: SQLite.Connection, textHash: String) throws {
        noteChunkFTSRebuild()
        try Self.rebuildChunkFTS(db, textHash: textHash)
    }

    /// Пересобирает FTS текущих вариантов документа — после смены `file_name`.
    static func rebuildChunkFTSForDocument(_ db: SQLite.Connection, documentId: String) throws {
        for hash in try currentTextHashes(db, documentId: documentId) {
            try rebuildChunkFTS(db, textHash: hash)
        }
    }

    /// Хеши, которые ещё на кого-то ссылаются: осиротевшие не трогаем —
    /// их FTS снимет `collectOrphanTexts`.
    static func rebuildChunkFTSIfLinked(_ db: SQLite.Connection, textHashes: [String]) throws {
        var seen: Set<String> = []
        for hash in textHashes where seen.insert(hash).inserted {
            guard try db.scalar("SELECT 1 FROM texts WHERE text_hash = ?", hash) != nil else { continue }
            guard try db.scalar("SELECT 1 FROM text_variants WHERE text_hash = ?", hash) != nil else { continue }
            try rebuildChunkFTS(db, textHash: hash)
        }
    }

    static func currentTextHashes(_ db: SQLite.Connection, documentId: String) throws -> [String] {
        var hashes: [String] = []
        for row in try db.prepare(
            "SELECT text_hash FROM text_variants WHERE document_id = ? AND is_current = 1",
            documentId
        ) {
            if let hash = RowReader(row).string(0) { hashes.append(hash) }
        }
        return hashes
    }

    /// Все текущие тексты документов указанного рабочего корня (пакетно).
    static func currentTextHashes(
        _ db: SQLite.Connection,
        workspaceRootId: String
    ) throws -> [String] {
        var hashes: [String] = []
        for row in try db.prepare(
            """
            SELECT DISTINCT tv.text_hash
            FROM text_variants tv
            JOIN documents d ON d.id = tv.document_id
            WHERE d.workspace_root_id = ? AND tv.is_current = 1
            """,
            workspaceRootId
        ) {
            if let hash = RowReader(row).string(0) { hashes.append(hash) }
        }
        return hashes
    }

    static func textContent(_ db: SQLite.Connection, hash: String) throws -> String? {
        for row in try db.prepare("SELECT content FROM texts WHERE text_hash = ?", hash) {
            return RowReader(row).string(0)
        }
        return nil
    }
}
