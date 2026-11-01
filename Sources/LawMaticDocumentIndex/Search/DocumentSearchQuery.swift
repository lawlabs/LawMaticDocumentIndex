import Foundation

// MARK: - Параметры поиска

public enum DocumentTextSearchScope: String, CaseIterable, Identifiable, Sendable {
    case currentFolderOnly
    case currentFolderRecursive
    case allDatabase

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .currentFolderOnly: return "Текущая папка"
        case .currentFolderRecursive: return "Папка и вложенные"
        case .allDatabase: return "Вся база"
        }
    }
}

public enum DocumentTextVariantFilter: String, CaseIterable, Identifiable, Sendable {
    case original
    case anonymized
    case all

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .original: return "Исходный"
        case .anonymized: return "Обезличенный"
        case .all: return "Все"
        }
    }
}

/// Ступень каскада, на которой нашлись результаты.
///
/// Отдаётся наружу, чтобы пользователь и ИИ отличали точное совпадение всех слов
/// от ослабленного поиска: на ступени `anyWord` выдача шире и требует проверки.
public enum DocumentSearchMatchMode: String, Codable, Hashable, Sendable {
    /// Все слова запроса присутствуют в документе.
    case allWords
    /// Найдено хотя бы одно слово; ранжирование по bm25 поднимает документы с большим числом совпадений.
    case anyWord
    /// Подстрока в оригинальном тексте — последняя ступень, без ранжирования.
    case substring

    public static let ftsCascade: [DocumentSearchMatchMode] = [.allWords, .anyWord]

    public var displayName: String {
        switch self {
        case .allWords: return "Все слова"
        case .anyWord: return "Любое из слов"
        case .substring: return "Подстрока"
        }
    }
}

// MARK: - Построение запроса

/// Формирование SQL полнотекстового поиска по документам.
///
/// Вынесено из хранилища сознательно: ровно эта логика определяет, что поиск
/// считает совпадением, и её нужно одновременно исполнять в приложении и
/// прогонять на эталонном наборе запросов утилитой оценки. Две копии разошлись бы
/// на первой же правке, и метрики перестали бы описывать то, что видит
/// пользователь. Компонент не зависит ни от чего, кроме Foundation и
/// `RussianTextNormalizer`: сам он SQL не исполняет, а только собирает текст
/// запроса и параметры.
/// SQL-часть привязана к схеме v1 и заменяется в Э1.
public enum DocumentSearchQuery: Sendable {

    /// Сколько результатов возвращает одна ступень каскада.
    public static let ftsLimit = 200
    /// Подстрочный поиск идёт полным просмотром, поэтому ограничен жёстче.
    public static let substringLimit = 50

    /// Ниже этого числа результатов строгая ступень считается недостаточной,
    /// и каскад продолжается, дополняя выдачу снизу.
    ///
    /// Останавливаться на первой непустой ступени нельзя: запрос «Куда делись
    /// деньги по договору уступки к РН+?» давал на строгой ступени два
    /// посторонних документа, и нужный договор не рассматривался вовсе —
    /// ослабленная ступень просто не запускалась. Точность при этом не страдает:
    /// строгие совпадения остаются наверху, ослабленные дописываются под ними.
    public static let sufficientResultCount = 10

    public struct Statement: Sendable {
        public let sql: String
        public let bindings: [String]

        public init(sql: String, bindings: [String]) {
            self.sql = sql
            self.bindings = bindings
        }
    }

    /// Область поиска, приведённая к тому виду, в котором она попадает в SQL.
    ///
    /// Относительный путь папки вычисляет вызывающая сторона: она знает про
    /// рабочие корни, а этот компонент — нет.
    ///
    /// Идентификатор рабочего корня обязателен для папочных областей. Один
    /// относительный путь корень не определяет: одинаковый путь в двух рабочих
    /// папках смешал бы в выдаче документы разных клиентов, а для юридического
    /// архива это не вопрос релевантности, а недопустимое смешение дел.
    public enum ResolvedScope: Sendable {
        case folder(workspaceRootId: String, relativePath: String)
        case folderRecursive(workspaceRootId: String, relativePath: String)
        /// Всё дело целиком, независимо от вложенной папки.
        case wholeCase(caseId: String)
        case everything
    }

    // MARK: Выражение MATCH

    /// Собирает выражение MATCH из уже нормализованных основ.
    ///
    /// Префикс `*` оставлен намеренно: стеммер может недоусечь словоформу в тексте
    /// сильнее, чем в запросе, и префиксное совпадение подбирает такие случаи.
    public static func matchExpression(stems: [String], mode: DocumentSearchMatchMode) -> String {
        let terms = stems
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"*" }

        guard !terms.isEmpty else { return "" }

        switch mode {
        case .allWords:
            return terms.joined(separator: " AND ")
        case .anyWord:
            // Ослабленная ступень имеет смысл только на нескольких словах:
            // для одного слова она совпала бы со строгой.
            guard terms.count > 1 else { return "" }
            return terms.joined(separator: " OR ")
        case .substring:
            return ""
        }
    }

    // MARK: Полнотекстовый поиск

    public static func ftsStatement(
        stems: [String],
        mode: DocumentSearchMatchMode,
        variantFilter: DocumentTextVariantFilter,
        scope: ResolvedScope,
        limit: Int = ftsLimit
    ) -> Statement? {
        let match = matchExpression(stems: stems, mode: mode)
        guard !match.isEmpty else { return nil }

        var sql = """
            SELECT
                document_text_variants_fts.variant_id,
                document_text_variants_fts.document_id,
                document_text_variants_fts.variant_type,
                documents_catalog.root_folder_path,
                documents_catalog.folder_path,
                documents_catalog.relative_path,
                documents_catalog.file_name,
                documents_catalog.document_type,
                documents_catalog.is_external,
                document_text_variants.text_content AS variant_content,
                bm25(document_text_variants_fts) AS rank_score,
                case_records.workspace_root_id
            FROM document_text_variants_fts
            JOIN documents_catalog ON documents_catalog.id = document_text_variants_fts.document_id
            JOIN document_text_variants ON document_text_variants.id = document_text_variants_fts.variant_id
            LEFT JOIN case_records ON case_records.id = document_text_variants_fts.case_id
            WHERE document_text_variants_fts MATCH ?
        """
        var bindings: [String] = [match]

        appendVariantFilter(variantFilter, column: "document_text_variants_fts.variant_type", to: &sql, bindings: &bindings)
        appendScope(scope, to: &sql, bindings: &bindings)

        sql += " ORDER BY rank_score LIMIT \(limit)"
        return Statement(sql: sql, bindings: bindings)
    }

    // MARK: Поиск подстроки

    /// Последняя ступень каскада: поиск подстроки по оригинальному тексту.
    ///
    /// Медленно и без ранжирования, поэтому вызывается, только когда обе ступени
    /// FTS дали пустую выдачу — например, для фрагмента внутри слова или для
    /// словоформы, которую стеммер свёл иначе, чем в документе.
    public static func substringStatement(
        query: String,
        variantFilter: DocumentTextVariantFilter,
        scope: ResolvedScope,
        limit: Int = substringLimit
    ) -> Statement? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }

        var sql = """
            SELECT
                document_text_variants.id,
                document_text_variants.document_id,
                document_text_variants.variant_type,
                documents_catalog.root_folder_path,
                documents_catalog.folder_path,
                documents_catalog.relative_path,
                documents_catalog.file_name,
                documents_catalog.document_type,
                documents_catalog.is_external,
                document_text_variants.text_content,
                case_records.workspace_root_id
            FROM document_text_variants
            JOIN documents_catalog ON documents_catalog.id = document_text_variants.document_id
            LEFT JOIN case_records ON case_records.id = document_text_variants.case_id
            WHERE document_text_variants.text_content LIKE ? ESCAPE '\\'
        """
        var bindings: [String] = ["%\(escapeForLike(trimmed))%"]

        appendVariantFilter(variantFilter, column: "document_text_variants.variant_type", to: &sql, bindings: &bindings)
        appendScope(scope, to: &sql, bindings: &bindings)

        sql += " LIMIT \(limit)"
        return Statement(sql: sql, bindings: bindings)
    }

    // MARK: Общие части

    private static func appendVariantFilter(
        _ filter: DocumentTextVariantFilter,
        column: String,
        to sql: inout String,
        bindings: inout [String]
    ) {
        switch filter {
        case .original:
            sql += " AND \(column) = ?"
            bindings.append("original")
        case .anonymized:
            sql += " AND \(column) = ?"
            bindings.append("anonymized")
        case .all:
            break
        }
    }

    private static func appendScope(
        _ scope: ResolvedScope,
        to sql: inout String,
        bindings: inout [String]
    ) {
        switch scope {
        case .folder(let workspaceRootId, let relativePath):
            sql += " AND case_records.workspace_root_id = ? AND documents_catalog.folder_path = ?"
            bindings.append(workspaceRootId)
            bindings.append(relativePath)

        case .folderRecursive(let workspaceRootId, let relativePath):
            // Для самого Workspace Root относительный путь пуст. Шаблон "/%"
            // не совпадает с обычными путями "Дело/Документ", поэтому здесь
            // достаточно ограничения по идентификатору корня: все документы
            // этого workspace по определению лежат внутри выбранной области.
            if relativePath.isEmpty {
                sql += " AND case_records.workspace_root_id = ?"
                bindings.append(workspaceRootId)
                return
            }

            // Шаблон экранируется: `_` и `%` в именах папок встречаются постоянно
            // («Дело_1», «2024_отчёт») и без экранирования работают как маска.
            sql += """
                 AND case_records.workspace_root_id = ?
                 AND (documents_catalog.folder_path = ?
                      OR documents_catalog.folder_path LIKE ? ESCAPE '\\')
                """
            bindings.append(workspaceRootId)
            bindings.append(relativePath)
            bindings.append(escapeForLike(relativePath) + "/%")

        case .wholeCase(let caseId):
            sql += " AND documents_catalog.case_id = ?"
            bindings.append(caseId)

        case .everything:
            break
        }
    }

    public static func escapeForLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
