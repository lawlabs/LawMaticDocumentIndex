import Accelerate
import Foundation

public struct QuantizedEmbedding: Equatable, Sendable {
    public let dimension: Int
    public let scale: Float
    public let bytes: Data

    public init(dimension: Int, scale: Float, bytes: Data) {
        self.dimension = dimension
        self.scale = scale
        self.bytes = bytes
    }
}

public enum VectorQuantizer: Sendable {
    /// Симметричное int8-квантование. Нулевой вектор сохраняется без NaN/∞.
    public static func quantize(_ vector: [Float]) -> QuantizedEmbedding {
        guard !vector.isEmpty else {
            return QuantizedEmbedding(dimension: 0, scale: 1, bytes: Data())
        }

        let maximum = vector.reduce(Float.zero) { max($0, abs($1)) }
        let scale = maximum > 0 ? maximum / 127 : 1
        let values = vector.map { value -> UInt8 in
            let rounded = Int((value / scale).rounded())
            let clamped = max(-127, min(127, rounded))
            return UInt8(bitPattern: Int8(clamped))
        }
        return QuantizedEmbedding(
            dimension: vector.count,
            scale: scale,
            bytes: Data(values)
        )
    }

    public static func dequantize(_ vector: QuantizedEmbedding) -> [Float]? {
        guard vector.dimension == vector.bytes.count else { return nil }
        return vector.bytes.map { byte in
            Float(Int8(bitPattern: byte)) * vector.scale
        }
    }

    public static func cosineSimilarity(
        query: [Float],
        candidate: QuantizedEmbedding
    ) -> Float? {
        guard query.count == candidate.dimension,
              let decoded = dequantize(candidate),
              !query.isEmpty else {
            return nil
        }

        let queryNorm = sqrt(vDSP.sumOfSquares(query))
        let candidateNorm = sqrt(vDSP.sumOfSquares(decoded))
        guard queryNorm > 0, candidateNorm > 0 else { return nil }
        return vDSP.dot(query, decoded) / (queryNorm * candidateNorm)
    }
}
