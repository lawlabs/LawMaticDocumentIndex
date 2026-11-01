//
//  SearchToolPresentation.swift
//  LawMaticFinder
//
//  Компактное представление результатов chunk-поиска для LLM tools.
//

import Foundation

public enum SearchToolPresentation: Sendable {
    public static func diversifiedResults(
        _ results: [ChunkSearchResult],
        limit: Int
    ) -> [ChunkSearchResult] {
        guard limit > 0 else { return [] }

        var selected: [ChunkSearchResult] = []
        var perDocumentCount: [String: Int] = [:]
        var selectedFingerprintOwners: [String: String] = [:]
        var selectedProfiles: [EvidenceProfile] = []

        // Tool-выдача отдаёт не больше одного сильного фрагмента каждого
        // документа. Остальной контекст модель получает адресно через
        // read_document_chunk, поэтому заполнение limit вторым фрагментом
        // только раздувает prompt и создаёт ложное впечатление нескольких
        // независимых источников.
        // Копии одного текста могут иметь разные documentId и пути, поэтому
        // дополнительно отсекаем почти одинаковое содержимое.
        for result in results {
            guard selected.count < limit else { break }
            guard perDocumentCount[result.documentId] == nil else { continue }
            if let fingerprint = result.documentTextHash,
               let owner = selectedFingerprintOwners[fingerprint],
               owner != result.documentId {
                continue
            }
            let profile = EvidenceProfile(content: result.content)
            guard !isNearDuplicate(profile, of: selectedProfiles) else { continue }
            selected.append(result)
            perDocumentCount[result.documentId] = 1
            if let fingerprint = result.documentTextHash {
                selectedFingerprintOwners[fingerprint] = result.documentId
            }
            selectedProfiles.append(profile)
        }

        return selected
    }

    public static func compactSnippet(
        content: String,
        query: String,
        maxCharacters: Int = 420
    ) -> String {
        guard content.count > maxCharacters else { return content }

        if let match = content.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) {
            let beforeBudget = maxCharacters / 3
            let matchedText = String(content[match])
            let afterBudget = max(maxCharacters - beforeBudget - matchedText.count, 0)
            let before = String(content[..<match.lowerBound].suffix(beforeBudget))
            let after = String(content[match.upperBound...].prefix(afterBudget))
            let hasLeadingText = match.lowerBound != content.startIndex
            let hasTrailingText = match.upperBound != content.endIndex
            return (hasLeadingText ? "…" : "")
                + before
                + matchedText
                + after
                + (hasTrailingText ? "…" : "")
        }

        return String(content.prefix(maxCharacters)) + "…"
    }

    /// Пути остальных физических копий того же полного текста.
    public static func additionalCopyPaths(
        of selected: ChunkSearchResult,
        in all: [ChunkSearchResult]
    ) -> [String] {
        guard let hash = selected.documentTextHash else { return [] }
        return all.compactMap { candidate in
            guard candidate.documentTextHash == hash, candidate.documentId != selected.documentId else {
                return nil
            }
            return candidate.relativePath.isEmpty ? candidate.fileName : candidate.relativePath
        }
    }

    private struct EvidenceProfile {
        let tokens: Set<String>
        let trigrams: Set<String>
        let amounts: Set<String>

        init(content: String) {
            let values = RussianTextNormalizer.normalizeForIndex(content)
                .split(separator: " ")
                .map(String.init)
                .filter { $0.count > 1 }
            tokens = Set(values)
            amounts = Self.amounts(in: content)
            if values.count >= 3 {
                var valuesTrigrams = Set<String>()
                for index in 0...(values.count - 3) {
                    let first = values[index]
                    let second = values[index + 1]
                    let third = values[index + 2]
                    valuesTrigrams.insert(
                        [first, second, third].joined(separator: "\u{1F}")
                    )
                }
                trigrams = valuesTrigrams
            } else {
                trigrams = []
            }
        }

        static func amounts(in content: String) -> Set<String> {
            let pattern = try? NSRegularExpression(pattern: #"\d{3,}(?:[ \u00A0]?\d{3})*(?:[.,]\d{1,2})?"#)
            guard let pattern else { return [] }
            let range = NSRange(content.startIndex..., in: content)
            let matches = pattern.matches(in: content, range: range)
            return Set(matches.compactMap { match in
                guard let slice = Range(match.range, in: content) else { return nil }
                return content[slice]
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: "\u{00A0}", with: "")
                    .replacingOccurrences(of: ",", with: ".")
            })
        }
    }

    private static func isNearDuplicate(
        _ candidate: EvidenceProfile,
        of selected: [EvidenceProfile]
    ) -> Bool {
        guard !candidate.tokens.isEmpty else { return false }
        return selected.contains { existing in
            if !candidate.amounts.isEmpty,
               !existing.amounts.isEmpty,
               candidate.amounts.isDisjoint(with: existing.amounts) {
                return false
            }
            guard !existing.tokens.isEmpty else { return false }
            let tokenIntersection = candidate.tokens.intersection(existing.tokens).count
            let tokenUnion = candidate.tokens.union(existing.tokens).count
            let tokenJaccard = tokenUnion == 0
                ? 0
                : Double(tokenIntersection) / Double(tokenUnion)
            let tokenContainment = Double(tokenIntersection)
                / Double(min(candidate.tokens.count, existing.tokens.count))

            // Устойчива к небольшим OCR-ошибкам и добавленной пометке «копия».
            if tokenIntersection >= 12,
               tokenJaccard >= 0.72 || tokenContainment >= 0.86 {
                return true
            }

            // Последовательности слов ловят один документ внутри большого
            // сборника даже при несовпадающих границах чанков. Высокий порог
            // не даёт склеить разные документы с общим юридическим шаблоном.
            guard candidate.trigrams.count >= 20, existing.trigrams.count >= 20 else {
                return false
            }
            let shared = candidate.trigrams.intersection(existing.trigrams).count
            let containment = Double(shared)
                / Double(min(candidate.trigrams.count, existing.trigrams.count))
            return shared >= 20 && containment >= 0.62
        }
    }
}
