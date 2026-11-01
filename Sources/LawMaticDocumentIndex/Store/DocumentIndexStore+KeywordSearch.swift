import Foundation
import SQLite

public struct KeywordSearchResult: Sendable {
    public let hits: [ChunkSearchResult]
    /// Самая слабая ступень, из которой в выдачу попал хотя бы один новый хит.
    public let weakestMatchMode: DocumentSearchMatchMode?
    public let stems: [String]

    public init(hits: [ChunkSearchResult], weakestMatchMode: DocumentSearchMatchMode?, stems: [String]) {
        self.hits = hits
        self.weakestMatchMode = weakestMatchMode
        self.stems = stems
    }
}

extension DocumentIndexStore {

    public func searchChunksKeyword(
        query: String,
        scope: SearchScope,
        variantFilter: DocumentTextVariantFilter = .original,
        limit: Int = 20
    ) throws -> KeywordSearchResult {
        let stems = RussianTextNormalizer.queryStems(from: query)
        guard limit > 0 else {
            return KeywordSearchResult(hits: [], weakestMatchMode: nil, stems: stems)
        }

        let db = try db()
        let roots = try workspaceRootPaths(db)
        let includeCaseLinks = try currentCapabilities().supportsExplicitCaseDocuments
        var texts: [String: String] = [:]
        var collected: [HydratedHit] = []
        var seenPairs: Set<String> = []
        // Копии документа (один text_hash) дают несколько строк на один чанк; к цели
        // каскада и к `limit` идут различные чанки, иначе одно письмо в 13 экземплярах
        // вытесняет всё остальное и следующая ступень не запускается.
        var distinctChunks: Set<Int64> = []
        var weakest: DocumentSearchMatchMode?
        let target = max(limit, DocumentSearchQuery.sufficientResultCount)

        func append(_ rows: [HydratedHit], mode: DocumentSearchMatchMode) {
            var added = false
            for row in rows where seenPairs.insert("\(row.chunkRowid)|\(row.hit.documentId)").inserted {
                collected.append(row)
                distinctChunks.insert(row.chunkRowid)
                added = true
            }
            if added { weakest = mode }
        }

        for mode in DocumentSearchMatchMode.ftsCascade {
            if let names = DocumentIndexQuery.nameStatement(stems: stems, mode: mode,
                    variantFilter: variantFilter, scope: scope, limit: max(DocumentSearchQuery.ftsLimit, target), includeCaseLinks: includeCaseLinks) {
                append(try readHits(db, statement: names, roots: roots, texts: &texts), mode: mode)
            }
            guard let statement = DocumentIndexQuery.ftsStatement(
                stems: stems,
                mode: mode,
                variantFilter: variantFilter,
                scope: scope,
                limit: max(DocumentSearchQuery.ftsLimit, target), includeCaseLinks: includeCaseLinks
            ) else { continue }
            append(
                try readHits(db, statement: statement, roots: roots, texts: &texts),
                mode: mode
            )
            if distinctChunks.count >= target { break }
        }

        if distinctChunks.count < target,
           let statement = DocumentIndexQuery.substringStatement(
               query: query,
               variantFilter: variantFilter,
               scope: scope,
               limit: max(DocumentSearchQuery.substringLimit, target), includeCaseLinks: includeCaseLinks
           ) {
            append(
                try substringHits(db, statement: statement, query: query, roots: roots, texts: &texts),
                mode: .substring
            )
        }

        return KeywordSearchResult(
            hits: Self.firstChunks(Self.orderCopiesByFileName(collected, stems: stems), limit: limit),
            weakestMatchMode: weakest,
            stems: stems
        )
    }

    private func substringHits(_ db: SQLite.Connection, statement: DocumentIndexQuery.Statement,
                               query: String, roots: [String: String], texts: inout [String: String]) throws -> [HydratedHit] {
        let seeds = try readHits(db, statement: statement, roots: roots, texts: &texts)
        var result: [HydratedHit] = []
        for seed in seeds {
            guard let hash = seed.hit.documentTextHash, let content = texts[hash] else { continue }
            let match = (content as NSString).range(of: query.trimmingCharacters(in: .whitespacesAndNewlines), options: [.caseInsensitive])
            guard match.location != NSNotFound else { continue }
            let chunks = try self.chunks(textHash: hash)
            guard let chunk = chunks.first(where: { $0.utf16Start <= match.location && $0.utf16End >= match.location + match.length })
                    ?? chunks.first(where: { $0.utf16End > match.location }),
                  let hitSQL = DocumentIndexQuery.chunkRowidsStatement(rowids: [chunk.rowid], variantFilter: .all,
                        scope: .documents(ids: [seed.hit.documentId])) else { continue }
            result += try readHits(db, statement: hitSQL, roots: roots, texts: &texts)
        }
        return result
    }

    /// Среди копий одного чанка первой идёт документ, чьё имя лучше совпадает
    /// с запросом. `SearchToolPresentation.diversifiedResults` оставляет только
    /// первую копию `text_hash`; без этого порядка JOIN показывает случайный
    /// дубликат, и запрос «ОСС 31.10.2022» теряет эталонную «Копию протокола».
    static func orderCopiesByFileName(_ hits: [HydratedHit], stems: [String]) -> [HydratedHit] {
        guard !stems.isEmpty, hits.count > 1 else { return hits }
        let stemSet = Set(stems)
        func nameScore(_ fileName: String) -> Int {
            let tokens = RussianTextNormalizer.normalizeForIndex(fileName)
                .split(separator: " ")
                .map(String.init)
            return tokens.reduce(0) { $0 + (stemSet.contains($1) ? 1 : 0) }
        }
        var groups: [(chunkRowid: Int64, copies: [HydratedHit])] = []
        var index: [Int64: Int] = [:]
        for hit in hits {
            if let existing = index[hit.chunkRowid] {
                groups[existing].copies.append(hit)
            } else {
                index[hit.chunkRowid] = groups.count
                groups.append((hit.chunkRowid, [hit]))
            }
        }
        return groups.flatMap { _, copies in
            copies.sorted { lhs, rhs in
                let left = nameScore(lhs.hit.fileName)
                let right = nameScore(rhs.hit.fileName)
                if left != right { return left > right }
                return lhs.hit.fileName < rhs.hit.fileName
            }
        }
    }

    /// `limit` считается по различным чанкам; все копии документа для попавшего чанка
    /// остаются в выдаче, чтобы клиент сам решал, как показывать дубликаты.
    private static func firstChunks(_ hits: [HydratedHit], limit: Int) -> [ChunkSearchResult] {
        var allowed: Set<Int64> = []
        var result: [ChunkSearchResult] = []
        for hit in hits {
            if !allowed.contains(hit.chunkRowid) {
                guard allowed.count < limit else { continue }
                allowed.insert(hit.chunkRowid)
            }
            result.append(hit.hit)
        }
        return result
    }
}
