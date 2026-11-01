import Accelerate
import Foundation

public struct VectorMatch: Equatable, Sendable {
    public let chunkRowid: Int64
    public let score: Float

    public init(chunkRowid: Int64, score: Float) {
        self.chunkRowid = chunkRowid
        self.score = score
    }
}

public enum VectorScan {
    /// Косинусная близость query к каждому кандидату (int8 × scale), top-k через кучу.
    /// Кандидаты с другой размерностью пропускаются. Пустой query или k <= 0 → [].
    public static func topK(
        query: [Float],
        candidates: [EmbeddingCandidate],
        dimension: Int,
        k: Int
    ) -> [VectorMatch] {
        guard k > 0, dimension > 0, query.count == dimension else { return [] }

        let queryNorm = sqrt(vDSP.sumOfSquares(query))
        guard queryNorm > 0 else { return [] }

        var normalizedQuery = [Float](repeating: 0, count: dimension)
        vDSP.divide(query, queryNorm, result: &normalizedQuery)

        var decoded = [Float](repeating: 0, count: dimension)
        var heap = MinScoreHeap(capacity: k)

        for candidate in candidates {
            guard candidate.vector.count == dimension else { continue }

            let converted = candidate.vector.withUnsafeBytes { raw -> Bool in
                let source = raw.bindMemory(to: Int8.self)
                guard let sourceBase = source.baseAddress else { return false }
                vDSP_vflt8(sourceBase, 1, &decoded, 1, vDSP_Length(dimension))
                return true
            }
            guard converted else { continue }

            if candidate.scale != 1 {
                vDSP.multiply(candidate.scale, decoded, result: &decoded)
            }

            let candidateNorm = sqrt(vDSP.sumOfSquares(decoded))
            guard candidateNorm > 0 else { continue }

            let score = vDSP.dot(normalizedQuery, decoded) / candidateNorm
            heap.insert(VectorMatch(chunkRowid: candidate.chunkRowid, score: score))
        }

        return heap.sortedDescending()
    }
}

/// Мин-куча размера k: в корне худший из текущих лучших (меньший score, при равенстве — больший rowid).
private struct MinScoreHeap {
    private var items: [VectorMatch]
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        items = []
        items.reserveCapacity(capacity)
    }

    mutating func insert(_ match: VectorMatch) {
        if items.count < capacity {
            items.append(match)
            siftUp(items.count - 1)
            return
        }
        if Self.isBetter(match, than: items[0]) {
            items[0] = match
            siftDown(0)
        }
    }

    func sortedDescending() -> [VectorMatch] {
        items.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.chunkRowid < rhs.chunkRowid
        }
    }

    private static func isBetter(_ lhs: VectorMatch, than rhs: VectorMatch) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.chunkRowid < rhs.chunkRowid
    }

    private static func isWorse(_ lhs: VectorMatch, than rhs: VectorMatch) -> Bool {
        if lhs.score != rhs.score { return lhs.score < rhs.score }
        return lhs.chunkRowid > rhs.chunkRowid
    }

    private mutating func siftUp(_ index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard Self.isWorse(items[child], than: items[parent]) else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ index: Int) {
        var parent = index
        while true {
            let left = 2 * parent + 1
            let right = 2 * parent + 2
            var worst = parent
            if left < items.count, Self.isWorse(items[left], than: items[worst]) {
                worst = left
            }
            if right < items.count, Self.isWorse(items[right], than: items[worst]) {
                worst = right
            }
            guard worst != parent else { return }
            items.swapAt(parent, worst)
            parent = worst
        }
    }
}
