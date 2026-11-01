import Foundation

// Записи ядра контракта v2. Все типы — значения, `Sendable`, без логики хранения:
// они пересекают границу actor `DocumentIndexStore` и уходят в UI и в ИИ-инструменты.

public struct WorkspaceRootRecord: Equatable, Sendable {
    public let id: String
    public let name: String
    public let localPath: String
    public let ownerApp: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: String, name: String, localPath: String, ownerApp: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.name = name
        self.localPath = localPath
        self.ownerApp = ownerApp
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct FolderRecord: Equatable, Sendable {
    public let id: Int64
    public let workspaceRootId: String
    /// `nil` только у корневой папки рабочего корня (`relativePath == ""`).
    public let parentId: Int64?
    /// Путь от корня без ведущего и завершающего `/`; у корня — пустая строка.
    public let relativePath: String
    public let depth: Int

    public init(id: Int64, workspaceRootId: String, parentId: Int64?, relativePath: String, depth: Int) {
        self.id = id
        self.workspaceRootId = workspaceRootId
        self.parentId = parentId
        self.relativePath = relativePath
        self.depth = depth
    }
}

public struct CaseRecord: Equatable, Sendable {
    public let id: String
    public let workspaceRootId: String
    public let rootFolderId: Int64
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: String, workspaceRootId: String, rootFolderId: Int64, title: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.workspaceRootId = workspaceRootId
        self.rootFolderId = rootFolderId
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum DocumentLocationKind: String, Sendable, CaseIterable {
    case workspace
    case external
}

public struct IndexedDocument: Equatable, Sendable, Identifiable {
    /// Целочисленный ключ таблицы; на него ссылается `documents_fts`.
    public let rowid: Int64
    public let id: String
    public let locationKind: DocumentLocationKind
    public let workspaceRootId: String?
    public let folderId: Int64?
    public let caseId: String?
    public let relativePath: String?
    public let absolutePath: String?
    public let fileName: String
    public let fileExtension: String
    public let fileSize: Int64
    public let fileModifiedAt: Date
    public let fileHash: String?
    public let createdByApp: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        rowid: Int64,
        id: String,
        locationKind: DocumentLocationKind,
        workspaceRootId: String?,
        folderId: Int64?,
        caseId: String?,
        relativePath: String?,
        absolutePath: String?,
        fileName: String,
        fileExtension: String,
        fileSize: Int64,
        fileModifiedAt: Date,
        fileHash: String?,
        createdByApp: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.rowid = rowid
        self.id = id
        self.locationKind = locationKind
        self.workspaceRootId = workspaceRootId
        self.folderId = folderId
        self.caseId = caseId
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.fileSize = fileSize
        self.fileModifiedAt = fileModifiedAt
        self.fileHash = fileHash
        self.createdByApp = createdByApp
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ExtractionStatus: String, Sendable, CaseIterable, Codable {
    case pending
    case complete
    case partial
    case noText = "no_text"
    case failed
    case unsupported
    case skipped
}

/// Стабильные машинные коды ошибок извлечения (контракт v2, §7.2).
public enum ExtractionErrorCode: String, Sendable, CaseIterable {
    case ocrPageLimit = "ocr_page_limit"
    case fileTooLarge = "file_too_large"
    case unsupportedFormat = "unsupported_format"
    case readFailed = "read_failed"
    case extractorCrashed = "extractor_crashed"
    case cancelled
    case timeout
}

public struct ExtractionState: Equatable, Sendable {
    public let documentId: String
    public let status: ExtractionStatus
    public let extractorId: String?
    public let extractorVersion: Int?
    public let methodLabel: String?
    public let pagesTotal: Int?
    public let pagesProcessed: Int?
    public let errorCode: String?
    public let errorMessage: String?
    public let attempts: Int
    public let nextRetryAfter: Date?
    public let finishedAt: Date?

    public init(
        documentId: String,
        status: ExtractionStatus,
        extractorId: String? = nil,
        extractorVersion: Int? = nil,
        methodLabel: String? = nil,
        pagesTotal: Int? = nil,
        pagesProcessed: Int? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        attempts: Int = 0,
        nextRetryAfter: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.documentId = documentId
        self.status = status
        self.extractorId = extractorId
        self.extractorVersion = extractorVersion
        self.methodLabel = methodLabel
        self.pagesTotal = pagesTotal
        self.pagesProcessed = pagesProcessed
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.attempts = attempts
        self.nextRetryAfter = nextRetryAfter
        self.finishedAt = finishedAt
    }
}

/// Повтор извлечения: временные сбои с backoff, без цикла на unsupported / OCR off.
public enum ExtractionRetry: Sendable {
    public static func nextRetryAfter(
        status: ExtractionStatus,
        errorCode: String?,
        attempts: Int
    ) -> Date? {
        guard status == .failed || status == .partial else { return nil }
        if isTerminalFailure(errorCode) { return nil }
        let capped = min(max(attempts, 1), 8)
        return Date().addingTimeInterval(min(300, pow(2.0, Double(capped)) * 10))
    }

    public static func shouldAutoRetry(
        status: ExtractionStatus,
        errorCode: String?,
        nextRetryAfter: Date?,
        now: Date = Date()
    ) -> Bool {
        switch status {
        case .complete, .noText, .unsupported, .skipped:
            return false
        case .pending:
            return true
        case .failed, .partial:
            if isTerminalFailure(errorCode) { return false }
            if let nextRetryAfter, nextRetryAfter > now { return false }
            return true
        }
    }

    public static func isTerminalFailure(_ errorCode: String?) -> Bool {
        errorCode == "ocr_disabled" || errorCode == ExtractionErrorCode.unsupportedFormat.rawValue
    }
}

public enum TextVariantType: String, Sendable, CaseIterable {
    case original
    case anonymized
}

/// Результат одной физической страницы. Не путать с `variant_pages`:
/// там диапазоны уже собранного текста, здесь — очередь возобновления OCR.
public struct ExtractionPageResult: Equatable, Sendable, Codable {
    public var pageNumber: Int
    public var text: String
    public var status: ExtractionStatus
    public var method: String?
    public var errorCode: String?
    public var errorMessage: String?

    public init(
        pageNumber: Int,
        text: String = "",
        status: ExtractionStatus,
        method: String? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) {
        self.pageNumber = pageNumber
        self.text = text
        self.status = status
        self.method = method
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }

    /// Успешно обработанная страница, в том числе пустая: повторять не нужно.
    public var isFinished: Bool {
        status == .complete || status == .noText || status == .skipped
    }
}

/// Resume страниц только при том же hash и том же configId (провайдер/модель входят в ID).
public enum ExtractionPageResumePolicy: Sendable {
    public static func isCompatible(
        resumeHash: String,
        resumeConfigId: String,
        currentHash: String,
        currentConfigId: String
    ) -> Bool {
        resumeHash == currentHash && resumeConfigId == currentConfigId
    }

    public static func usableFinishedPages(
        resumeHash: String,
        resumeConfigId: String,
        pages: [Int: ExtractionPageResult],
        currentHash: String,
        currentConfigId: String
    ) -> [Int: ExtractionPageResult] {
        guard isCompatible(
            resumeHash: resumeHash,
            resumeConfigId: resumeConfigId,
            currentHash: currentHash,
            currentConfigId: currentConfigId
        ) else { return [:] }
        return pages.filter { $0.value.isFinished }
    }
}

public enum ExtractionPageAssembler: Sendable {
    public static func configId(
        extractorId: String,
        extractorVersion: Int,
        extras: [String: String] = [:]
    ) -> String {
        let extra = extras.keys.sorted().map { "\($0)=\(extras[$0] ?? "")" }.joined(separator: ";")
        return "\(extractorId)|\(extractorVersion)|\(extra)"
    }

    /// Собирает канонический текст в физическом порядке страниц и пересчитывает UTF-16.
    public static func assemble(
        pages: [ExtractionPageResult],
        pagesTotal: Int
    ) -> (text: String, ranges: [TextPageRange], processed: Int, status: ExtractionStatus) {
        let byNumber = Dictionary(uniqueKeysWithValues: pages.map { ($0.pageNumber, $0) })
        var text = ""
        var ranges: [TextPageRange] = []
        var processed = 0
        var sawFailure = false
        var sawSkip = false
        for number in 1...max(pagesTotal, 0) {
            guard let page = byNumber[number] else {
                sawFailure = true
                continue
            }
            if page.status == .complete || page.status == .noText {
                processed += 1
                let start = text.utf16.count
                if !page.text.isEmpty {
                    text += page.text
                    if !text.hasSuffix("\n") { text += "\n\n" }
                }
                ranges.append(TextPageRange(pageNumber: number, utf16Start: start, utf16End: text.utf16.count))
            } else if page.status == .skipped {
                sawSkip = true
            } else {
                sawFailure = true
            }
        }
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let status: ExtractionStatus
        if processed == pagesTotal && pagesTotal > 0 {
            status = empty ? .noText : .complete
        } else if processed == 0 && sawSkip && !sawFailure {
            status = .skipped
        } else if processed == 0 && empty {
            status = .failed
        } else {
            status = .partial
        }
        return (text, ranges, processed, status)
    }
}

/// Диапазон страницы в каноническом тексте (UTF-16 смещения в `texts.content`).
public struct TextPageRange: Hashable, Sendable, Codable {
    public let pageNumber: Int
    public let utf16Start: Int
    public let utf16End: Int

    public init(pageNumber: Int, utf16Start: Int, utf16End: Int) {
        self.pageNumber = pageNumber
        self.utf16Start = utf16Start
        self.utf16End = utf16End
    }
}

public struct TextRecord: Equatable, Sendable {
    public let textHash: String
    public let utf16Length: Int
    public let languageCode: String?
    public let createdAt: Date

    public init(textHash: String, utf16Length: Int, languageCode: String?, createdAt: Date) {
        self.textHash = textHash
        self.utf16Length = utf16Length
        self.languageCode = languageCode
        self.createdAt = createdAt
    }
}

public struct TextVariantRecord: Equatable, Sendable {
    public let id: String
    public let documentId: String
    public let variantType: TextVariantType
    public let textHash: String
    public let sourceVariantId: String?
    public let isCurrent: Bool
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        documentId: String,
        variantType: TextVariantType,
        textHash: String,
        sourceVariantId: String?,
        isCurrent: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.documentId = documentId
        self.variantType = variantType
        self.textHash = textHash
        self.sourceVariantId = sourceVariantId
        self.isCurrent = isCurrent
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ChunkRecord: Equatable, Sendable {
    public let rowid: Int64
    /// Детерминированный идентификатор `"<text_hash>:<chunk_index>"`.
    public let id: String
    public let textHash: String
    public let chunkIndex: Int
    public let utf16Start: Int
    public let utf16End: Int
    public let pageNumber: Int?
    public let sectionPath: String?

    public init(
        rowid: Int64,
        id: String,
        textHash: String,
        chunkIndex: Int,
        utf16Start: Int,
        utf16End: Int,
        pageNumber: Int?,
        sectionPath: String?
    ) {
        self.rowid = rowid
        self.id = id
        self.textHash = textHash
        self.chunkIndex = chunkIndex
        self.utf16Start = utf16Start
        self.utf16End = utf16End
        self.pageNumber = pageNumber
        self.sectionPath = sectionPath
    }

    public static func makeId(textHash: String, chunkIndex: Int) -> String {
        "\(textHash):\(chunkIndex)"
    }
}

public struct EmbeddingModelRecord: Equatable, Sendable {
    public let modelId: String
    public let provider: String
    public let dimension: Int
    public let quantization: String
    public let createdAt: Date

    public init(modelId: String, provider: String, dimension: Int, quantization: String, createdAt: Date) {
        self.modelId = modelId
        self.provider = provider
        self.dimension = dimension
        self.quantization = quantization
        self.createdAt = createdAt
    }
}

public enum IndexJobKind: String, Sendable, CaseIterable {
    case extract
    case embed
}

public enum IndexJobState: String, Sendable, CaseIterable {
    case queued
    case running
    case done
    case failed
}

public struct IndexJobRecord: Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: IndexJobKind
    /// Цель задачи: `doc:<document_id>` для `extract`, `text:<text_hash>` для `embed`.
    public let target: String
    public let modelId: String?
    public let priority: Int
    public let state: IndexJobState
    public let attempts: Int
    public let lastError: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        kind: IndexJobKind,
        target: String,
        modelId: String?,
        priority: Int,
        state: IndexJobState,
        attempts: Int,
        lastError: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.target = target
        self.modelId = modelId
        self.priority = priority
        self.state = state
        self.attempts = attempts
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func documentTarget(_ documentId: String) -> String { "doc:" + documentId }
    public static func textTarget(_ textHash: String) -> String { "text:" + textHash }

    /// Разбирает `text:<hash>`; `nil`, если префикс другой или хеш пуст.
    public static func textHash(fromTarget target: String) -> String? {
        let prefix = "text:"
        guard target.hasPrefix(prefix) else { return nil }
        let hash = String(target.dropFirst(prefix.count))
        return hash.isEmpty ? nil : hash
    }
}
