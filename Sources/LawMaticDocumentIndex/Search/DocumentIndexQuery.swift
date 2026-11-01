import Foundation
import SQLite

/// Построитель SQL keyword-поиска по схеме v2. SQL не исполняет.
public enum DocumentIndexQuery: Sendable {

    /// Значение плейсхолдера `?`. `Binding` из SQLite.swift не `Sendable`.
    public enum SQLValue: Sendable, Equatable {
        case text(String)
        case integer(Int64)
        case real(Double)
    }

    public struct Statement: Sendable {
        public let sql: String
        public let bindings: [SQLValue]

        public init(sql: String, bindings: [SQLValue]) {
            self.sql = sql
            self.bindings = bindings
        }
    }

    /// Индексы колонок `SELECT` у `ftsStatement`, `substringStatement`
    /// и `chunkRowidsStatement`.
    ///
    /// 0 `c.rowid`, 1 `c.id`, 2 `c.text_hash`, 3 `c.chunk_index`,
    /// 4 `c.utf16_start`, 5 `c.utf16_end`, 6 `c.page_number`,
    /// 7 `d.id`, 8 `d.location_kind`, 9 `d.workspace_root_id`,
    /// 10 `d.relative_path`, 11 `d.absolute_path`, 12 `d.file_name`,
    /// 13 `tv.variant_type`, 14 `rank` (`bm25(chunk_fts, 0.0, 1.0)` либо `NULL`).
    public enum Column {
        public static let chunkRowid = 0
        public static let chunkId = 1
        public static let textHash = 2
        public static let chunkIndex = 3
        public static let utf16Start = 4
        public static let utf16End = 5
        public static let pageNumber = 6
        public static let documentId = 7
        public static let locationKind = 8
        public static let workspaceRootId = 9
        public static let relativePath = 10
        public static let absolutePath = 11
        public static let fileName = 12
        public static let variantType = 13
        public static let rank = 14
    }

    /// FTS-ступень: `nil`, если выражение MATCH пустое.
    public static func ftsStatement(
        stems: [String],
        mode: DocumentSearchMatchMode,
        variantFilter: DocumentTextVariantFilter,
        scope: SearchScope,
        limit: Int, includeCaseLinks: Bool = false
    ) -> Statement? {
        let match = DocumentSearchQuery.matchExpression(stems: stems, mode: mode)
        guard !match.isEmpty else { return nil }

        let area = ScopeSQL(scope: scope, includeCaseLinks: includeCaseLinks)
        let variant = variantConstraint(variantFilter)
        let withPrefix = area.cte.map { "WITH RECURSIVE " + $0 + ", " } ?? "WITH "
        let sql = """
            \(withPrefix)matched_chunks AS MATERIALIZED (
                SELECT chunk_fts.rowid, bm25(chunk_fts, 0.0, 1.0) AS rank
                FROM chunk_fts
                WHERE chunk_fts MATCH ? AND EXISTS (
                    SELECT 1 FROM chunks c
                    JOIN text_variants tv ON tv.text_hash = c.text_hash AND tv.is_current = 1\(variant.sql)
                    JOIN documents d ON d.id = tv.document_id
                    WHERE c.rowid = chunk_fts.rowid AND \(area.predicate)
                ) ORDER BY rank LIMIT ?
            )
            SELECT \(selectList), m.rank
            FROM matched_chunks m JOIN chunks c ON c.rowid = m.rowid
            JOIN text_variants tv ON tv.text_hash = c.text_hash AND tv.is_current = 1\(variant.sql)
            JOIN documents d ON d.id = tv.document_id
            WHERE \(area.predicate) ORDER BY m.rank, c.rowid, d.id
            """
        let bindings = sqlValues(from: area.cteBindings)
            + [.text("content_norm : (" + match + ")")]
            + variant.bindings + sqlValues(from: area.predicateBindings)
            + [.integer(Int64(max(limit, 0)))]
            + variant.bindings + sqlValues(from: area.predicateBindings)
        return Statement(sql: sql, bindings: bindings)
    }

    /// Filename matches belong to a physical document, never to all copies of its text.
    public static func nameStatement(stems: [String], mode: DocumentSearchMatchMode,
                                     variantFilter: DocumentTextVariantFilter, scope: SearchScope,
                                     limit: Int, includeCaseLinks: Bool = false) -> Statement? {
        let match = DocumentSearchQuery.matchExpression(stems: stems, mode: mode)
        guard !match.isEmpty else { return nil }
        let area = ScopeSQL(scope: scope, includeCaseLinks: includeCaseLinks)
        let variant = variantConstraint(variantFilter)
        let sql = """
            \(area.withClause)SELECT \(selectList), bm25(documents_fts, 5.0, 0.0) AS rank
            FROM documents_fts JOIN documents d ON d.rowid = documents_fts.rowid
            JOIN text_variants tv ON tv.document_id = d.id AND tv.is_current = 1\(variant.sql)
            JOIN chunks c ON c.text_hash = tv.text_hash AND c.chunk_index = 0
            WHERE documents_fts MATCH ? AND \(area.predicate)
            ORDER BY rank, d.id LIMIT ?
            """
        return Statement(sql: sql, bindings: sqlValues(from: area.cteBindings) + variant.bindings
            + [.text("file_name_norm : (" + match + ")")]
            + sqlValues(from: area.predicateBindings) + [.integer(Int64(max(limit, 0)))])
    }

    /// Подстрочная ступень по `texts.content`.
    ///
    /// Возвращает `chunk_index = 0` каждого текста, где `LIKE` нашёл подстроку.
    /// `instr` даёт позицию в символах SQLite, а не в UTF-16, поэтому не ищем
    /// точный чанк в SQL: store находит UTF-16 позицию подстроки и возвращает
    /// соответствующий ей чанк перед выдачей результатов.
    public static func substringStatement(
        query: String,
        variantFilter: DocumentTextVariantFilter,
        scope: SearchScope,
        limit: Int, includeCaseLinks: Bool = false
    ) -> Statement? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }

        let pattern = "%" + DocumentSearchQuery.escapeForLike(trimmed) + "%"
        return scopedStatement(
            from: "texts t JOIN chunks c ON c.text_hash = t.text_hash",
            rankExpression: "NULL AS rank",
            extraWhere: "t.content LIKE ? ESCAPE '\\' AND c.chunk_index = 0",
            extraBindings: [.text(pattern)],
            orderByRank: false,
            variantFilter: variantFilter,
            scope: scope,
            limit: limit, includeCaseLinks: includeCaseLinks
        )
    }

    /// Гидратация чанков по `chunks.rowid`. `rank` — `NULL`.
    ///
    /// Один `text_hash` на нескольких документах даёт несколько строк
    /// (пара чанк+документ). Пустой `rowids` → `nil`.
    public static func chunkRowidsStatement(
        rowids: [Int64],
        variantFilter: DocumentTextVariantFilter,
        scope: SearchScope, includeCaseLinks: Bool = false
    ) -> Statement? {
        guard !rowids.isEmpty else { return nil }

        let scopeSQL = ScopeSQL(scope: scope, includeCaseLinks: includeCaseLinks)
        let variant = variantConstraint(variantFilter)
        let placeholders = Array(repeating: "?", count: rowids.count).joined(separator: ", ")
        let leading = sqlValues(from: scopeSQL.cteBindings)
        let trailing = sqlValues(from: scopeSQL.predicateBindings)

        // Плейсхолдеры как в `scopedStatement`, без LIMIT: CTE → вариант → rowids → предикат.
        let sql = """
            \(scopeSQL.withClause)SELECT \(selectList), NULL AS rank
            FROM chunks c
            JOIN text_variants tv ON tv.text_hash = c.text_hash AND tv.is_current = 1\(variant.sql)
            JOIN documents d ON d.id = tv.document_id
            WHERE c.rowid IN (\(placeholders)) AND \(scopeSQL.predicate)
            """

        let bindings = leading + variant.bindings + rowids.map { .integer($0) } + trailing
        return Statement(sql: sql, bindings: bindings)
    }

    // MARK: Сборка

    /// Общие колонки SELECT — порядок зафиксирован в `Column`.
    private static let selectList = """
        c.rowid, c.id, c.text_hash, c.chunk_index, c.utf16_start, c.utf16_end, COALESCE((SELECT vp.page_number FROM variant_pages vp WHERE vp.variant_id = tv.id AND c.utf16_start >= vp.utf16_start AND c.utf16_start < vp.utf16_end LIMIT 1), c.page_number), \
        d.id, d.location_kind, d.workspace_root_id, d.relative_path, d.absolute_path, d.file_name, \
        tv.variant_type
        """

    /// Порядок плейсхолдеров повторяет порядок их появления в SQL:
    /// CTE области (`WITH`), фильтр варианта и MATCH/LIKE (`JOIN`/`WHERE`),
    /// предикат области, `LIMIT`.
    private static func scopedStatement(
        from fromClause: String,
        rankExpression: String,
        extraWhere: String,
        extraBindings: [SQLValue],
        orderByRank: Bool,
        variantFilter: DocumentTextVariantFilter,
        scope: SearchScope,
        limit: Int, includeCaseLinks: Bool = false
    ) -> Statement {
        let scopeSQL = ScopeSQL(scope: scope, includeCaseLinks: includeCaseLinks)
        let variant = variantConstraint(variantFilter)
        let leading = sqlValues(from: scopeSQL.cteBindings)
        let trailing = sqlValues(from: scopeSQL.predicateBindings)
        let order = orderByRank ? " ORDER BY rank" : ""

        let sql = """
            \(scopeSQL.withClause)SELECT \(selectList), \(rankExpression)
            FROM \(fromClause)
            JOIN text_variants tv ON tv.text_hash = c.text_hash AND tv.is_current = 1\(variant.sql)
            JOIN documents d ON d.id = tv.document_id
            WHERE \(extraWhere) AND \(scopeSQL.predicate)\(order) LIMIT ?
            """

        let bindings = leading + variant.bindings + extraBindings + trailing + [.integer(Int64(max(limit, 0)))]
        return Statement(sql: sql, bindings: bindings)
    }

    private static func variantConstraint(
        _ filter: DocumentTextVariantFilter
    ) -> (sql: String, bindings: [SQLValue]) {
        switch filter {
        case .original:
            return (" AND tv.variant_type = ?", [.text(TextVariantType.original.rawValue)])
        case .anonymized:
            return (" AND tv.variant_type = ?", [.text(TextVariantType.anonymized.rawValue)])
        case .all:
            return ("", [])
        }
    }

    private static func sqlValues(from bindings: [Binding]) -> [SQLValue] {
        bindings.map { binding in
            if let value = binding as? String { return .text(value) }
            if let value = binding as? Int64 { return .integer(value) }
            if let value = binding as? Int { return .integer(Int64(value)) }
            if let value = binding as? Double { return .real(value) }
            preconditionFailure("ScopeSQL вернул биндинг, который нельзя представить как SQLValue")
        }
    }
}

extension DocumentIndexQuery.SQLValue {
    var binding: Binding {
        switch self {
        case .text(let value): return value
        case .integer(let value): return value
        case .real(let value): return value
        }
    }
}

extension DocumentIndexQuery.Statement {
    var sqliteBindings: [Binding?] {
        bindings.map(\.binding)
    }
}
