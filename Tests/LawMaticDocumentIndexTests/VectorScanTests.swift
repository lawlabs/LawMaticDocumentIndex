import Foundation
import Testing
@testable import LawMaticDocumentIndex

@Test("topK: пустой query или k <= 0 дают пустой результат, чужая размерность пропускается")
func topKПустойЗапросИЧужаяРазмерность() {
    let candidate = EmbeddingCandidate(
        chunkRowid: 1,
        scale: 1,
        vector: VectorQuantizer.quantize([1, 0, 0, 0]).bytes
    )
    #expect(VectorScan.topK(query: [], candidates: [candidate], dimension: 4, k: 3).isEmpty)
    #expect(VectorScan.topK(query: [1, 0, 0, 0], candidates: [candidate], dimension: 4, k: 0).isEmpty)
    #expect(VectorScan.topK(query: [1, 0], candidates: [candidate], dimension: 2, k: 1).isEmpty)

    let wrong = EmbeddingCandidate(chunkRowid: 2, scale: 1, vector: Data([1, 2]))
    let matches = VectorScan.topK(
        query: [1, 0, 0, 0],
        candidates: [wrong, candidate],
        dimension: 4,
        k: 3
    )
    #expect(matches.map(\.chunkRowid) == [1])
}

@Test("topK совпадает с эталоном cosineSimilarity + полная сортировка на 1000 векторах dim 64")
func topKСовпадаетСЭталономНаТысячеВекторов() {
    let dimension = 64
    let count = 1_000
    let k = 15
    var rng = LCG64(seed: 2_026_090_2)
    let query = случайныйВектор(dimension: dimension, rng: &rng)
    let candidates = случайныеКандидаты(count: count, dimension: dimension, rng: &rng)

    let actual = VectorScan.topK(query: query, candidates: candidates, dimension: dimension, k: k)
    let expected = эталонTopK(query: query, candidates: candidates, dimension: dimension, k: k)

    #expect(actual.count == expected.count)
    for (got, want) in zip(actual, expected) {
        #expect(got.chunkRowid == want.chunkRowid, "порядок rowid: \(got.chunkRowid) ≠ \(want.chunkRowid)")
        #expect(
            abs(got.score - want.score) < 1e-4,
            "score rowid=\(got.chunkRowid): \(got.score) ≠ \(want.score)"
        )
    }
}

@Test("Замер topK: 50 000 кандидатов dim 1024 укладываются в 2 с")
func замерTopKПятьдесятТысяч() {
    let dimension = 1_024
    let count = 50_000
    var rng = LCG64(seed: 7)
    let query = случайныйВектор(dimension: dimension, rng: &rng)
    let candidates = случайныеБайтовыеКандидаты(count: count, dimension: dimension, rng: &rng)

    let started = CFAbsoluteTimeGetCurrent()
    let matches = VectorScan.topK(query: query, candidates: candidates, dimension: dimension, k: 20)
    let elapsed = CFAbsoluteTimeGetCurrent() - started
    print(String(format: "VectorScan.topK 50 000×1024: %.3f с", elapsed))

    #expect(matches.count == 20)
    #expect(elapsed < 2.0, "скан 50 тыс. векторов dim 1024 должен укладываться в 2 с: \(elapsed)")
}

private struct LCG64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

private func случайныйВектор(dimension: Int, rng: inout LCG64) -> [Float] {
    (0..<dimension).map { _ in Float.random(in: -1...1, using: &rng) }
}

private func случайныеКандидаты(count: Int, dimension: Int, rng: inout LCG64) -> [EmbeddingCandidate] {
    var buffer = [Float](repeating: 0, count: dimension)
    var result: [EmbeddingCandidate] = []
    result.reserveCapacity(count)
    for index in 0..<count {
        for dim in 0..<dimension {
            buffer[dim] = Float.random(in: -1...1, using: &rng)
        }
        let quantized = VectorQuantizer.quantize(buffer)
        result.append(
            EmbeddingCandidate(chunkRowid: Int64(index), scale: quantized.scale, vector: quantized.bytes)
        )
    }
    return result
}

/// Быстрая генерация для замера: int8-байты берутся прямо из 64-битных слов генератора,
/// без квантования — иначе подготовка 50 000×1024 занимает дольше самого скана на порядок.
private func случайныеБайтовыеКандидаты(count: Int, dimension: Int, rng: inout LCG64) -> [EmbeddingCandidate] {
    var result: [EmbeddingCandidate] = []
    result.reserveCapacity(count)
    let words = (dimension + 7) / 8
    var bytes = [UInt8](repeating: 0, count: dimension)
    for index in 0..<count {
        var offset = 0
        for _ in 0..<words {
            var word = rng.next()
            let take = min(8, dimension - offset)
            for _ in 0..<take {
                bytes[offset] = UInt8(truncatingIfNeeded: word)
                word >>= 8
                offset += 1
            }
        }
        result.append(EmbeddingCandidate(chunkRowid: Int64(index), scale: 0.01, vector: Data(bytes)))
    }
    return result
}

private func эталонTopK(
    query: [Float],
    candidates: [EmbeddingCandidate],
    dimension: Int,
    k: Int
) -> [VectorMatch] {
    candidates.compactMap { candidate -> VectorMatch? in
        let encoded = QuantizedEmbedding(dimension: dimension, scale: candidate.scale, bytes: candidate.vector)
        guard let score = VectorQuantizer.cosineSimilarity(query: query, candidate: encoded) else {
            return nil
        }
        return VectorMatch(chunkRowid: candidate.chunkRowid, score: score)
    }
    .sorted { lhs, rhs in
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.chunkRowid < rhs.chunkRowid
    }
    .prefix(k)
    .map { $0 }
}
