import Foundation

/// Поколение писателя: сброс или замена файла индекса инвалидирует in-flight commit.
public struct DocumentIndexWriteGeneration: Equatable, Sendable {
    public private(set) var value: UInt64

    public init(value: UInt64 = 0) {
        self.value = value
    }

    public mutating func invalidate() {
        value += 1
    }

    public func validate(_ lease: UInt64) throws {
        guard lease == value else {
            throw DocumentIndexError.staleWriterGeneration
        }
    }

    public func validateIfPresent(_ lease: UInt64?) throws {
        if let lease {
            try validate(lease)
        }
    }
}

/// Потокобезопасное поколение писателя: UI и очередь читают без await.
public final class DocumentIndexWriterLease: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = DocumentIndexWriteGeneration()

    public init() {}

    public var value: UInt64 {
        lock.withLock { generation.value }
    }

    public func invalidate() {
        lock.withLock { generation.invalidate() }
    }

    public func validate(_ lease: UInt64) throws {
        try lock.withLock { try generation.validate(lease) }
    }

    public func validateIfPresent(_ lease: UInt64?) throws {
        try lock.withLock { try generation.validateIfPresent(lease) }
    }
}

/// Lease задания: при ошибке извлечения берём поколение старта, не текущее.
public enum DocumentIndexCommitLease: Sendable {
    public static func resolve(outcomeGeneration: UInt64?, started: UInt64) -> UInt64 {
        outcomeGeneration ?? started
    }
}

/// Идентичность файла индекса (`index_generation`). Переживает перезапуск процесса.
public enum DocumentIndexFileIdentity: Sendable {
    /// Unbound persisted work must be explicitly bound before execution.
    public static func validate(stored: String?, current: String?) throws {
        guard let stored, !stored.isEmpty else {
            throw DocumentIndexError.invalidArgument("Операция ожидает привязки к базе. Повторите её явно или отмените.")
        }
        guard let current, stored == current else { throw DocumentIndexError.staleWriterGeneration }
    }

    public static func shouldKeepAfterReset(stored: String?, keeping: String?) -> Bool {
        guard let keeping, !keeping.isEmpty else { return false }
        return stored == keeping
    }
}

/// Кэш UUID открытого файла: очередь читает без await.
public final class DocumentIndexFileIdentityLease: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    public init() {}

    public var current: String? {
        lock.withLock { value }
    }

    public func set(_ value: String?) {
        lock.withLock { self.value = value }
    }
}

/// Checked inside the same SQLite transaction as a queued mutation.
public struct DocumentIndexMutationGuard: Sendable {
    public let indexGeneration: String
    public let epoch: UInt64
    public let lease: DocumentIndexWriterLease
    public init(indexGeneration: String, epoch: UInt64, lease: DocumentIndexWriterLease) {
        self.indexGeneration = indexGeneration; self.epoch = epoch; self.lease = lease
    }
    public func validate(currentGeneration: String?) throws {
        try lease.validate(epoch)
        try DocumentIndexFileIdentity.validate(stored: indexGeneration, current: currentGeneration)
    }
}
