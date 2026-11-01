import Foundation
import Testing
@testable import LawMaticDocumentIndex

@Test("Смена поколения писателя отвергает старый lease")
func сменаПоколенияОтвергаетСтарыйLease() throws {
    var generation = DocumentIndexWriteGeneration()
    let lease = generation.value
    try generation.validate(lease)
    generation.invalidate()
    #expect(throws: DocumentIndexError.staleWriterGeneration) {
        try generation.validate(lease)
    }
    try generation.validate(generation.value)
    try generation.validateIfPresent(nil)
}

@Test("Потокобезопасный lease и commit при ошибке берут поколение старта")
func потокобезопасныйLeaseИCommitПриОшибке() throws {
    let lease = DocumentIndexWriterLease()
    let started = lease.value
    #expect(DocumentIndexCommitLease.resolve(outcomeGeneration: 9, started: started) == 9)
    #expect(DocumentIndexCommitLease.resolve(outcomeGeneration: nil, started: started) == started)
    lease.invalidate()
    #expect(throws: DocumentIndexError.staleWriterGeneration) {
        try lease.validate(started)
    }
    #expect(lease.value != started)
}

@Test("Идентичность файла переживает перезапуск счётчика процесса")
func идентичностьФайлаПереживаетПерезапускСчётчика() throws {
    let beforeRestart = DocumentIndexWriterLease()
    beforeRestart.invalidate()
    let queuedProcess = beforeRestart.value
    let queuedFile = "gen-after-reset"
    let afterRestart = DocumentIndexWriterLease()
    #expect(afterRestart.value == 0)
    #expect(throws: DocumentIndexError.staleWriterGeneration) {
        try afterRestart.validate(queuedProcess)
    }
    try DocumentIndexFileIdentity.validate(stored: queuedFile, current: queuedFile)
    #expect(throws: DocumentIndexError.staleWriterGeneration) {
        try DocumentIndexFileIdentity.validate(stored: queuedFile, current: "other-file")
    }
    #expect(throws: (any Error).self) { try DocumentIndexFileIdentity.validate(stored: nil, current: queuedFile) }
    #expect(throws: (any Error).self) {
        try DocumentIndexFileIdentity.validate(stored: nil, current: nil)
    }
    #expect(DocumentIndexFileIdentity.shouldKeepAfterReset(stored: queuedFile, keeping: queuedFile))
    #expect(!DocumentIndexFileIdentity.shouldKeepAfterReset(stored: queuedFile, keeping: "new-file"))
    #expect(!DocumentIndexFileIdentity.shouldKeepAfterReset(stored: nil, keeping: queuedFile))
}
