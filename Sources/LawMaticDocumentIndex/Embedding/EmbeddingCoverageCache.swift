import Foundation

/// In-memory кэш покрытия semantic-индекса по `(modelId, область)`.
///
/// Состояние защищено `NSLock`: вызывается из синхронного кода внутри `DispatchQueue.sync`.
public final class EmbeddingCoverageCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: LocalEmbeddingCoverage] = [:]

    public init() {}

    public static func key(
        modelId: String,
        workspaceRootId: String,
        relativePath: String
    ) -> String {
        modelId + "\u{1F}" + workspaceRootId + "\u{1F}" + relativePath
    }

    public func coverage(forKey key: String) -> LocalEmbeddingCoverage? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    public func store(_ coverage: LocalEmbeddingCoverage, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = coverage
    }

    public func invalidateAll() {
        lock.lock()
        defer { lock.unlock() }
        values.removeAll(keepingCapacity: false)
    }
}

/// SQL проверки покрытия: один проход вместо двух отдельных `COUNT`.
public enum EmbeddingCoverageSQL: Sendable {
    public static func combinedCountSQL(scopeSQL: String) -> String {
        """
        SELECT
            COUNT(*) AS total_chunks,
            COUNT(chunk_embeddings.chunk_id) AS embedded_chunks
        FROM chunk_records
        JOIN documents_catalog
          ON documents_catalog.id = chunk_records.document_id
        LEFT JOIN case_records
          ON case_records.id = chunk_records.case_id
        LEFT JOIN chunk_embeddings
          ON chunk_embeddings.chunk_id = chunk_records.id
         AND chunk_embeddings.model_id = ?
        WHERE chunk_records.variant_type = 'original'
        \(scopeSQL)
        """
    }
}
