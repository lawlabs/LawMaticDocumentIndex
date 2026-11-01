import Foundation

/// Компактный межходовой журнал инструментов.
///
/// Полный payload остаётся в WorkflowArtifact, а в prompt попадает достаточно
/// данных, чтобы модель могла либо сослаться на уже проверенный отрывок, либо
/// адресно перечитать тот же chunk без повторного поиска.
public enum WorkflowArtifactSummaryBuilder: Sendable {
    public static func summary(
        toolName: String,
        normalizedResult: String
    ) -> String {
        guard !normalizedResult.isEmpty else { return toolName }
        guard let data = normalizedResult.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else {
            return "\(toolName): \(String(normalizedResult.prefix(160)))"
        }

        let ok = json["ok"] as? Bool ?? true
        if !ok {
            let error = (json["error"] as? String) ?? "ошибка"
            return "\(toolName): ошибка — \(String(error.prefix(120)))"
        }

        switch toolName {
        case "search_case_documents":
            return searchSummary(json)
        case "read_document_chunk":
            return readSummary(json)
        default:
            return "\(toolName): \(String(normalizedResult.prefix(160)))"
        }
    }

    private static func searchSummary(_ json: [String: Any]) -> String {
        let query = (json["query"] as? String) ?? ""
        let count = json["returnedCount"] as? Int ?? 0
        var seenNames = Set<String>()
        let references = (json["results"] as? [[String: Any]] ?? [])
            .compactMap { result -> String? in
                guard let name = result["fileName"] as? String,
                      seenNames.insert(name).inserted else {
                    return nil
                }
                let chunkId = (result["chunkId"] as? String) ?? ""
                return chunkId.isEmpty ? name : "\(name) [chunkId=\(chunkId)]"
            }
            .prefix(3)
        let files = references.isEmpty
            ? ""
            : "; документы: \(references.joined(separator: "; "))"
        return "search_case_documents: «\(String(query.prefix(80)))», \(count) результатов\(files)"
    }

    private static func readSummary(_ json: [String: Any]) -> String {
        let anchorChunkId = (json["chunkId"] as? String) ?? ""
        let count = json["count"] as? Int ?? 0
        let results = json["results"] as? [[String: Any]] ?? []
        let anchor = results.first {
            ($0["chunkId"] as? String) == anchorChunkId
        } ?? results.first
        let fileName = (anchor?["fileName"] as? String) ?? ""
        let content = (anchor?["content"] as? String) ?? ""
        let excerpt = compactEvidence(content)

        var fields = ["read_document_chunk"]
        if !anchorChunkId.isEmpty {
            fields.append("chunkId=\(anchorChunkId)")
        }
        if !fileName.isEmpty {
            fields.append("файл=\(fileName)")
        }
        fields.append("прочитано=\(count)")
        if !excerpt.isEmpty {
            fields.append("проверенный отрывок: «\(excerpt)»")
        }
        return fields.joined(separator: "; ")
    }

    private static func compactEvidence(_ content: String) -> String {
        let normalized = content
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let limit = 700
        guard normalized.count > limit else { return normalized }

        let side = (limit - 3) / 2
        return String(normalized.prefix(side))
            + " … "
            + String(normalized.suffix(side))
    }
}

/// Безопасная для SwiftUI и transcript-персистентности проекция результата
/// инструмента. Полный payload продолжает жить в request-scoped истории и
/// WorkflowArtifact; ObservableObject получает только компактное представление.
public enum ToolResultUIPresentation: Sendable {
    private static let genericLimit = 2_000

    public static func compactResult(
        toolName: String,
        rawResult: String
    ) -> String {
        let normalized = rawResult.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return rawResult }

        switch toolName {
        case "search_case_documents", "read_document_chunk":
            return WorkflowArtifactSummaryBuilder.summary(
                toolName: toolName,
                normalizedResult: normalized
            )
        default:
            guard normalized.count > genericLimit else { return normalized }
            let side = (genericLimit - 3) / 2
            return String(normalized.prefix(side))
                + " … "
                + String(normalized.suffix(side))
        }
    }
}
