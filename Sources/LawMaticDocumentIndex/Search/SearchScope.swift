import Foundation
import SQLite

/// Область поиска и покрытия в терминах схемы v2.
///
/// Папочные области задаются либо идентификатором `folders.id`, либо парой
/// `(workspaceRootId, relativePath)` — так их формулирует Finder, знающий только пути.
/// Идентификатор рабочего корня обязателен: одинаковый относительный путь в двух корнях
/// смешал бы документы разных клиентов.
public indirect enum SearchScope: Sendable, Equatable {
    case everything
    case union([SearchScope])
    case workspaceRoot(id: String)
    case folder(id: Int64, recursive: Bool)
    case folderPath(workspaceRootId: String, relativePath: String, recursive: Bool)
    case wholeCase(id: String)
    case externalOnly
    /// Явный набор документов (для проверок и точечного чтения).
    case documents(ids: [String])

    /// Приводит путь папки к каноническому виду хранения: без ведущих и
    /// завершающих `/`, корень рабочей папки — пустая строка.
    public static func canonicalFolderPath(_ path: String) -> String {
        DocumentIndexPath.canonicalize(path)
    }

    /// Относительный путь папки или корня. Пустая строка допустима.
    public static func validatedRelativePath(_ path: String) throws -> String {
        try DocumentIndexPath.validateFolder(path)
    }

}

/// SQL-фрагменты области. Условие ссылается на алиас таблицы `documents`
/// (по умолчанию `d`); рекурсивные папки раскрываются CTE по `parent_id`,
/// поэтому в плане запроса нет ни `LIKE`, ни полного просмотра `documents`.
struct ScopeSQL {
    /// Тело CTE без `WITH RECURSIVE`; `nil`, если CTE не нужен.
    let cte: String?
    let predicate: String
    /// Плейсхолдеры внутри CTE (идут первыми в SQL, так как `WITH` предшествует `SELECT`).
    let cteBindings: [Binding]
    /// Плейсхолдеры внутри `predicate`.
    let predicateBindings: [Binding]

    /// Все плейсхолдеры в порядке появления: сначала CTE, затем предикат.
    /// Подходит, когда между `WITH` и предикатом нет других `?`.
    var bindings: [Binding] { cteBindings + predicateBindings }

    private init(cte: String?, predicate: String, cteBindings: [Binding], predicateBindings: [Binding]) {
        self.cte = cte; self.predicate = predicate
        self.cteBindings = cteBindings; self.predicateBindings = predicateBindings
    }

    static let folderCTEName = "scope_folders"

    init(scope: SearchScope, documentsAlias alias: String = "d", includeCaseLinks: Bool = false) {
        switch scope {
        case let .union(scopes):
            // Each subtree gets its own CTE namespace. SQL still applies scope before LIMIT.
            let parts = scopes.enumerated().map { index, scope -> ScopeSQL in
                let part = ScopeSQL(scope: scope, documentsAlias: alias, includeCaseLinks: includeCaseLinks)
                let suffix = "_u\(index)"
                return ScopeSQL(cte: part.cte?.replacingOccurrences(of: Self.folderCTEName, with: Self.folderCTEName + suffix),
                    predicate: part.predicate.replacingOccurrences(of: Self.folderCTEName, with: Self.folderCTEName + suffix),
                    cteBindings: part.cteBindings, predicateBindings: part.predicateBindings)
            }
            let clauses = parts.compactMap(\.cte)
            cte = clauses.isEmpty ? nil : clauses.joined(separator: ", ")
            predicate = parts.isEmpty ? "0 = 1" : "((" + parts.map(\.predicate).joined(separator: ") OR (") + "))"
            cteBindings = parts.flatMap(\.cteBindings)
            predicateBindings = parts.flatMap(\.predicateBindings)

        case .everything:
            cte = nil
            predicate = "1 = 1"
            cteBindings = []
            predicateBindings = []

        case let .workspaceRoot(id):
            cte = nil
            // Условие на location_kind открывает планировщику частичный индекс
            // idx_documents_workspace_path (префикс workspace_root_id) вместо полного просмотра.
            predicate = "(\(alias).location_kind = 'workspace' AND \(alias).workspace_root_id = ?)"
            cteBindings = []
            predicateBindings = [id]

        case let .folder(id, recursive):
            if recursive {
                cte = Self.recursiveFolderCTE(seed: "SELECT ?")
                predicate = "\(alias).folder_id IN (SELECT id FROM \(Self.folderCTEName))"
                cteBindings = [id]
                predicateBindings = []
            } else {
                cte = nil
                predicate = "\(alias).folder_id = ?"
                cteBindings = []
                predicateBindings = [id]
            }

        case let .folderPath(workspaceRootId, relativePath, recursive):
            let seed = "SELECT id FROM folders WHERE workspace_root_id = ? AND relative_path = ?"
            guard let path = try? SearchScope.validatedRelativePath(relativePath) else {
                cte = nil; predicate = "0 = 1"; cteBindings = []; predicateBindings = []
                return
            }
            if recursive {
                cte = Self.recursiveFolderCTE(seed: seed)
                predicate = "\(alias).folder_id IN (SELECT id FROM \(Self.folderCTEName))"
                cteBindings = [workspaceRootId, path]
                predicateBindings = []
            } else {
                cte = nil
                predicate = "\(alias).folder_id = (\(seed))"
                cteBindings = []
                predicateBindings = [workspaceRootId, path]
            }

        case let .wholeCase(id):
            cte = nil
            predicate = includeCaseLinks
                ? "(\(alias).case_id = ? OR EXISTS (SELECT 1 FROM case_document_links l WHERE l.case_id = ? AND l.document_id = \(alias).id))"
                : "\(alias).case_id = ?"
            cteBindings = []
            predicateBindings = includeCaseLinks ? [id, id] : [id]

        case .externalOnly:
            cte = nil
            predicate = "\(alias).location_kind = 'external'"
            cteBindings = []
            predicateBindings = []

        case let .documents(ids):
            cte = nil
            cteBindings = []
            if ids.isEmpty {
                predicate = "0 = 1"
                predicateBindings = []
            } else {
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
                predicate = "\(alias).id IN (\(placeholders))"
                predicateBindings = ids
            }
        }
    }

    /// Префикс `WITH RECURSIVE …` для запроса или пустая строка.
    var withClause: String {
        guard let cte else { return "" }
        return "WITH RECURSIVE \(cte) "
    }

    private static func recursiveFolderCTE(seed: String) -> String {
        """
        \(folderCTEName)(id) AS (
            \(seed)
            UNION ALL
            SELECT f.id FROM folders f JOIN \(folderCTEName) s ON f.parent_id = s.id
        )
        """
    }
}
