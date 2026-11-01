import Foundation

/// `manifest.json` рядом с базой: клиент читает его до открытия SQLite и понимает,
/// совместим ли файл и какой моделью построены эмбеддинги.
public struct DocumentIndexManifest: Codable, Equatable, Sendable {
    public var contractVersion: Int
    public var writerAppId: String
    public var writerAppVersion: String
    public var lastWriteISO: String
    public var defaultEmbeddingModelId: String?
    public var ftsNormalizerVersion: Int
    public var chunkingVersion: Int
    /// UUID поколения файла писателя. Совпадает с `index_metadata.index_generation`.
    public var indexGeneration: String?
    /// UUID конкретной публикации снимка. Меняется на каждый `VACUUM INTO`.
    public var snapshotId: String?

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case writerAppId = "writer_app_id"
        case writerAppVersion = "writer_app_version"
        case lastWriteISO = "last_write_iso"
        case defaultEmbeddingModelId = "default_embedding_model_id"
        case ftsNormalizerVersion = "fts_normalizer_version"
        case chunkingVersion = "chunking_version"
        case indexGeneration = "index_generation"
        case snapshotId = "snapshot_id"
    }

    public init(
        contractVersion: Int = Int(DocumentIndexSchema.userVersion),
        writerAppId: String,
        writerAppVersion: String,
        lastWriteISO: String,
        defaultEmbeddingModelId: String? = nil,
        ftsNormalizerVersion: Int = DocumentIndexSchema.ftsNormalizerVersion,
        chunkingVersion: Int = DocumentIndexSchema.chunkingVersion,
        indexGeneration: String? = nil,
        snapshotId: String? = nil
    ) {
        self.contractVersion = contractVersion
        self.writerAppId = writerAppId
        self.writerAppVersion = writerAppVersion
        self.lastWriteISO = lastWriteISO
        self.defaultEmbeddingModelId = defaultEmbeddingModelId
        self.ftsNormalizerVersion = ftsNormalizerVersion
        self.chunkingVersion = chunkingVersion
        self.indexGeneration = indexGeneration
        self.snapshotId = snapshotId
    }

    public var isCompatible: Bool {
        contractVersion == Int(DocumentIndexSchema.userVersion)
            && ftsNormalizerVersion == DocumentIndexSchema.ftsNormalizerVersion
    }

    public static func load(from url: URL) throws -> DocumentIndexManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(DocumentIndexManifest.self, from: data)
    }

    /// Атомарная запись: читатель никогда не увидит полузаписанный файл.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
