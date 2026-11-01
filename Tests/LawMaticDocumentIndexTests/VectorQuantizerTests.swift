import Foundation
import Testing
@testable import LawMaticDocumentIndex

@Test("Квантование int8 сохраняет направление вектора")
func квантованиеInt8СохраняетНаправлениеВектора() {
    let source: [Float] = [0.1, -0.35, 0.8, 0.02, -0.5]
    let quantized = VectorQuantizer.quantize(source)
    #expect(quantized.dimension == source.count, "размерность записана")
    #expect(quantized.bytes.count == source.count, "один байт на компонент")

    let similarity = VectorQuantizer.cosineSimilarity(query: source, candidate: quantized) ?? 0
    #expect(similarity > 0.999, "косинус после квантования близок к единице: \(similarity)")
    #expect(
        VectorQuantizer.cosineSimilarity(query: [1, 2], candidate: quantized) == nil,
        "несовпадающая размерность отклоняется"
    )
}
