import Accelerate
import Foundation
import NaturalLanguage

public struct LocalEmbeddingDescriptor: Equatable, Sendable {
    public let providerId: String
    public let modelId: String
    public let dimension: Int
    public let maximumInputTokens: Int

    public init(
        providerId: String,
        modelId: String,
        dimension: Int,
        maximumInputTokens: Int
    ) {
        self.providerId = providerId
        self.modelId = modelId
        self.dimension = dimension
        self.maximumInputTokens = maximumInputTokens
    }
}

public enum LocalEmbeddingPurpose: Sendable {
    case document
    case query
}

/// Результат эмбеддинга с явной отметкой обрезки входа.
public struct LocalEmbeddingReport: Sendable {
    public let vector: [Float]
    public let truncated: Bool
    public let inputTokenCount: Int?

    public init(vector: [Float], truncated: Bool = false, inputTokenCount: Int? = nil) {
        self.vector = vector
        self.truncated = truncated
        self.inputTokenCount = inputTokenCount
    }
}

public protocol LocalEmbeddingProvider: Sendable {
    var descriptor: LocalEmbeddingDescriptor { get }
    func prepare(
        allowDownload: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws
    func embedding(
        for text: String,
        purpose: LocalEmbeddingPurpose
    ) async throws -> [Float]
    func embeddings(
        for texts: [String],
        purpose: LocalEmbeddingPurpose
    ) async throws -> [[Float]]
    func embeddingReport(
        for text: String,
        purpose: LocalEmbeddingPurpose
    ) async throws -> LocalEmbeddingReport
}

extension LocalEmbeddingProvider {
    /// Поиск и индексатор не качают ассеты сами: загрузка — отдельное действие UI.
    public func prepare() async throws {
        try await prepare(allowDownload: false, progressHandler: { _ in })
    }

    public func embeddings(
        for texts: [String],
        purpose: LocalEmbeddingPurpose
    ) async throws -> [[Float]] {
        var result: [[Float]] = []
        result.reserveCapacity(texts.count)
        for text in texts {
            result.append(try await embedding(for: text, purpose: purpose))
        }
        return result
    }

    public func embeddingReport(
        for text: String,
        purpose: LocalEmbeddingPurpose
    ) async throws -> LocalEmbeddingReport {
        LocalEmbeddingReport(vector: try await embedding(for: text, purpose: purpose))
    }
}

public enum LocalEmbeddingProviderError: LocalizedError, Sendable {
    case modelUnavailable
    case assetsUnavailable
    case loadFailed
    case emptyText
    case emptyEmbedding
    case inconsistentDimension(expected: Int, actual: Int)
    case incompatibleModel(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "Системная модель эмбеддингов для русского языка недоступна."
        case .assetsUnavailable:
            return "Не удалось загрузить системные ресурсы модели эмбеддингов."
        case .loadFailed:
            return "Не удалось загрузить системную модель эмбеддингов в память."
        case .emptyText:
            return "Нельзя построить эмбеддинг пустого текста."
        case .emptyEmbedding:
            return "Системная модель не вернула ни одного токенного вектора."
        case .inconsistentDimension(let expected, let actual):
            return "Модель вернула вектор размерности \(actual) вместо \(expected)."
        case .incompatibleModel(let expected, let actual):
            return "Провайдер эмбеддингов «\(actual)» не совпадает с моделью индекса «\(expected)»."
        }
    }
}

/// Экспериментальный локальный провайдер на системной Cyrillic-модели Apple.
///
/// Это baseline, а не заранее выбранная production-модель. Apple описывает
/// contextual embedding прежде всего как feature extractor; пригодность
/// mean-pooling для retrieval должна быть доказана на gold set до массовой
/// индексации архива.
///
/// `@unchecked Sendable`: `NLContextualEmbedding` не объявлен `Sendable`, но
/// после инициализации провайдер не имеет изменяемого состояния, а сама модель
/// потокобезопасна для чтения.
public final class AppleContextualEmbeddingProvider: LocalEmbeddingProvider, @unchecked Sendable {
    private let model: NLContextualEmbedding

    public let descriptor: LocalEmbeddingDescriptor

    public init?() {
        guard let model = NLContextualEmbedding(language: .russian) else {
            return nil
        }
        self.model = model
        self.descriptor = LocalEmbeddingDescriptor(
            providerId: "apple",
            modelId: "apple.nlcontextual.\(model.modelIdentifier).r\(model.revision).windowed-mean.v1",
            dimension: model.dimension,
            maximumInputTokens: model.maximumSequenceLength
        )
    }

    public func prepare(
        allowDownload: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws {
        if !model.hasAvailableAssets {
            guard allowDownload else {
                throw LocalEmbeddingProviderError.assetsUnavailable
            }
            let result = try await model.requestAssets()
            guard result == .available else {
                throw LocalEmbeddingProviderError.assetsUnavailable
            }
        }

        do {
            try model.load()
        } catch {
            throw LocalEmbeddingProviderError.loadFailed
        }
    }

    public func embedding(
        for text: String,
        purpose: LocalEmbeddingPurpose
    ) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalEmbeddingProviderError.emptyText
        }

        var sum = [Float](repeating: 0, count: descriptor.dimension)
        var tokenCount = 0
        var consumedUTF16 = 0
        let totalUTF16 = trimmed.utf16.count

        // NLContextualEmbedding молча обрезает вход после maximumSequenceLength
        // subword-токенов. Русское слово часто занимает несколько токенов,
        // поэтому лимит нельзя надёжно пересчитать в число слов заранее.
        // Продолжаем с первого необработанного UTF-16 смещения и усредняем все
        // токенные вектора: хвост длинного чанка не теряется.
        while consumedUTF16 < totalUTF16 {
            try Task.checkCancellation()
            let start = String.Index(utf16Offset: consumedUTF16, in: trimmed)
            let window = String(trimmed[start...])
            let result = try model.embeddingResult(for: window, language: .russian)
            var processedInWindow = 0

            result.enumerateTokenVectors(
                in: result.string.startIndex..<result.string.endIndex
            ) { vector, tokenRange in
                guard vector.count == self.descriptor.dimension else {
                    return false
                }
                for index in vector.indices {
                    sum[index] += Float(vector[index])
                }
                tokenCount += 1
                processedInWindow = max(
                    processedInWindow,
                    tokenRange.upperBound.utf16Offset(in: result.string)
                )
                return true
            }

            guard processedInWindow > 0 else {
                throw LocalEmbeddingProviderError.emptyEmbedding
            }
            consumedUTF16 += processedInWindow
        }

        guard tokenCount > 0 else {
            throw LocalEmbeddingProviderError.emptyEmbedding
        }
        let divisor = Float(tokenCount)
        var pooled = sum.map { $0 / divisor }
        let norm = sqrt(vDSP.sumOfSquares(pooled))
        if norm > 0 {
            pooled = pooled.map { $0 / norm }
        }
        guard pooled.count == descriptor.dimension else {
            throw LocalEmbeddingProviderError.inconsistentDimension(
                expected: descriptor.dimension,
                actual: pooled.count
            )
        }
        return pooled
    }

    public func embeddingReport(
        for text: String,
        purpose: LocalEmbeddingPurpose
    ) async throws -> LocalEmbeddingReport {
        // Windowed-mean обрабатывает весь текст окнами; хвост не отбрасывается.
        LocalEmbeddingReport(
            vector: try await embedding(for: text, purpose: purpose),
            truncated: false
        )
    }
}
