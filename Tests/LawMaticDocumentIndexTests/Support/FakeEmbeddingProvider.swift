import Foundation
@testable import LawMaticDocumentIndex

/// Детерминированный провайдер без ML: вектор из хешей основ запроса.
/// Тексты с общими словами ближе друг к другу. Счётчики защищены `NSLock`.
final class FakeEmbeddingProvider: LocalEmbeddingProvider, @unchecked Sendable {
    let descriptor: LocalEmbeddingDescriptor

    private let lock = NSLock()
    private var prepareCount = 0
    private var embeddingCount = 0
    private var batchCount = 0
    private var failNextBatchFlag = false
    private var failNextEmbeddingFlag = false

    var prepareCalls: Int { locked { prepareCount } }
    var embeddingCalls: Int { locked { embeddingCount } }
    var batchCalls: Int { locked { batchCount } }

    var failNextBatch: Bool {
        get { locked { failNextBatchFlag } }
        set { locked { failNextBatchFlag = newValue } }
    }

    var failNextEmbedding: Bool {
        get { locked { failNextEmbeddingFlag } }
        set { locked { failNextEmbeddingFlag = newValue } }
    }

    init(
        providerId: String = "fake",
        modelId: String = "fake-hash-32",
        dimension: Int = 32
    ) {
        self.descriptor = LocalEmbeddingDescriptor(
            providerId: providerId,
            modelId: modelId,
            dimension: dimension,
            maximumInputTokens: 256
        )
    }

    func prepare(
        allowDownload: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws {
        locked { prepareCount += 1 }
    }

    func embedding(for text: String, purpose: LocalEmbeddingPurpose) async throws -> [Float] {
        let shouldFail: Bool = locked {
            embeddingCount += 1
            let fail = failNextEmbeddingFlag
            failNextEmbeddingFlag = false
            return fail
        }
        if shouldFail {
            throw LocalEmbeddingProviderError.loadFailed
        }
        return Self.vector(for: text, dimension: descriptor.dimension)
    }

    func embeddings(
        for texts: [String],
        purpose: LocalEmbeddingPurpose
    ) async throws -> [[Float]] {
        let shouldFail: Bool = locked {
            batchCount += 1
            let fail = failNextBatchFlag
            failNextBatchFlag = false
            return fail
        }
        if shouldFail {
            throw LocalEmbeddingProviderError.loadFailed
        }
        return texts.map { Self.vector(for: $0, dimension: descriptor.dimension) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Мешок хешей основ, нормированный. Общие слова дают ненулевое скалярное произведение.
    static func vector(for text: String, dimension: Int) -> [Float] {
        var values = [Float](repeating: 0, count: max(dimension, 1))
        let stems = RussianTextNormalizer.queryStems(from: text)
        let tokens = stems.isEmpty
            ? text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            : stems
        for token in tokens {
            let bucket = abs(Self.stableHash(token)) % values.count
            values[bucket] += 1
        }
        let norm = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 })
        if norm > 0 {
            values = values.map { $0 / norm }
        }
        return values
    }

    private static func stableHash(_ string: String) -> Int {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return Int(truncatingIfNeeded: hash)
    }
}
