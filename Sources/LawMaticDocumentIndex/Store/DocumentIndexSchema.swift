import Foundation
import SQLite

/// Схема v2 базы текстов документов. Источник истины — контракт
/// `lawmatic-shared-database-v2.md`; DDL здесь и там должны совпадать.
public enum DocumentIndexSchema {
    public static let fileName = "LawMaticDocumentIndex.sqlite"
    public static let manifestFileName = "manifest.json"
    /// ASCII «LMDI».
    public static let applicationID: Int32 = 0x4C4D4449
    /// Major-версия контракта.
    public static let userVersion: Int32 = 2

    /// Токенизатор FTS5 общий для чанков и имён файлов; текст и имя в индекс
    /// попадают уже нормализованными (`RussianTextNormalizer.normalizeForIndex`).
    public static let ftsTokenizer = "unicode61 remove_diacritics 2"

    /// Ключи `index_metadata`. Версии производных индексов повышаются при смене
    /// алгоритма без смены DDL; клиент сравнивает их со своим пакетом.
    public enum MetadataKey {
        public static let ftsNormalizerVersion = "fts_normalizer_version"
        public static let chunkingVersion = "chunking_version"
        public static let defaultEmbeddingModelId = "default_embedding_model_id"
        public static let schemaCreatedAt = "schema_created_at_iso"
        public static let writerAppId = "writer_app_id"
        /// Версия таблиц-расширений Finder; не входит в `user_version` контракта.
        public static let finderExtensionVersion = "finder_extension_version"
        public static let readerRequiredFeatures = "reader_required_features"
        /// UUID поколения файла. Новый пустой индекс получает новое значение;
        /// `PRAGMA data_version` этого не заменяет при атомарной смене самого файла.
        public static let indexGeneration = "index_generation"
    }

    /// Версия нормализатора, под которую построен `chunk_fts`/`documents_fts`.
    public static let ftsNormalizerVersion = 3
    /// Версия чанкинга (размер окна, overlap, правила границ).
    public static let chunkingVersion = 1
    /// Версия DDL расширений Finder в том же файле (дела, факты, анонимизация).
    public static let finderExtensionVersion = 4
    public static let supportedReaderFeatures: Set<String> = ["explicit_case_documents"]

    /// Имена таблиц ядра контракта (без shadow-таблиц FTS).
    public static let coreTables: [String] = [
        "index_metadata", "workspace_roots", "folders", "cases", "documents",
        "extraction_state", "texts", "text_pages", "text_variants", "chunks",
        "chunk_fts", "documents_fts", "embedding_models", "chunk_embeddings", "index_jobs",
    ]

    /// Таблицы-расширения Finder. Внешние клиенты их игнорируют; контракт
    /// гарантирует только сосуществование в том же файле.
    public static let extensionTables: [String] = [
        "case_metadata", "case_facts", "case_evidences", "case_circumstances",
        "case_lawyer_tasks", "case_tags", "document_relations", "document_user_metadata",
        "anonymization_runs", "anonymization_entities", "anonymization_occurrences",
        "file_bookmarks", "extraction_fingerprints", "variant_pages", "text_variant_history", "index_removals",
        "extraction_page_results", "case_document_links",
    ]

    /// DDL ядра. Порядок важен: внешние ключи ссылаются на уже созданные таблицы.
    static let statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS index_metadata (
            key             TEXT NOT NULL PRIMARY KEY,
            value           TEXT NOT NULL,
            updated_at_iso  TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS workspace_roots (
            id              TEXT NOT NULL PRIMARY KEY,
            name            TEXT NOT NULL,
            local_path      TEXT NOT NULL,
            owner_app       TEXT NOT NULL,
            created_at_iso  TEXT NOT NULL,
            updated_at_iso  TEXT NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_workspace_roots_owner_app ON workspace_roots(owner_app)",
        """
        CREATE TABLE IF NOT EXISTS folders (
            id                  INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
            workspace_root_id   TEXT NOT NULL,
            parent_id           INTEGER,
            relative_path       TEXT NOT NULL,
            depth               INTEGER NOT NULL,
            FOREIGN KEY (workspace_root_id) REFERENCES workspace_roots(id) ON DELETE CASCADE,
            FOREIGN KEY (parent_id) REFERENCES folders(id) ON DELETE CASCADE,
            UNIQUE (workspace_root_id, relative_path)
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_folders_parent ON folders(parent_id)",
        "CREATE INDEX IF NOT EXISTS idx_folders_workspace_depth ON folders(workspace_root_id, depth)",
        """
        CREATE TABLE IF NOT EXISTS cases (
            id                  TEXT NOT NULL PRIMARY KEY,
            workspace_root_id   TEXT NOT NULL,
            root_folder_id      INTEGER NOT NULL,
            title               TEXT NOT NULL,
            created_at_iso      TEXT NOT NULL,
            updated_at_iso      TEXT NOT NULL,
            FOREIGN KEY (workspace_root_id) REFERENCES workspace_roots(id) ON DELETE CASCADE,
            FOREIGN KEY (root_folder_id) REFERENCES folders(id) ON DELETE CASCADE,
            UNIQUE (workspace_root_id, root_folder_id)
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_cases_workspace_root ON cases(workspace_root_id)",
        "CREATE INDEX IF NOT EXISTS idx_cases_root_folder ON cases(root_folder_id)",
        """
        CREATE TABLE IF NOT EXISTS documents (
            rowid               INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
            id                  TEXT NOT NULL UNIQUE,
            location_kind       TEXT NOT NULL CHECK (location_kind IN ('workspace', 'external')),
            workspace_root_id   TEXT,
            folder_id           INTEGER,
            case_id             TEXT,
            relative_path       TEXT,
            absolute_path       TEXT,
            file_name           TEXT NOT NULL,
            file_name_lower     TEXT NOT NULL,
            file_extension      TEXT NOT NULL,
            file_size           INTEGER NOT NULL,
            file_modified_iso   TEXT NOT NULL,
            file_hash           TEXT,
            created_by_app      TEXT NOT NULL,
            created_at_iso      TEXT NOT NULL,
            updated_at_iso      TEXT NOT NULL,
            FOREIGN KEY (workspace_root_id) REFERENCES workspace_roots(id) ON DELETE CASCADE,
            FOREIGN KEY (folder_id) REFERENCES folders(id) ON DELETE CASCADE,
            FOREIGN KEY (case_id) REFERENCES cases(id) ON DELETE SET NULL,
            CHECK (
                (location_kind = 'workspace' AND workspace_root_id IS NOT NULL
                    AND folder_id IS NOT NULL AND relative_path IS NOT NULL AND absolute_path IS NULL)
                OR
                (location_kind = 'external' AND absolute_path IS NOT NULL
                    AND workspace_root_id IS NULL AND folder_id IS NULL AND case_id IS NULL
                    AND relative_path IS NULL)
            )
        )
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_documents_workspace_path
            ON documents(workspace_root_id, relative_path) WHERE location_kind = 'workspace'
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_documents_absolute_path
            ON documents(absolute_path) WHERE location_kind = 'external'
        """,
        "CREATE INDEX IF NOT EXISTS idx_documents_case ON documents(case_id)",
        "CREATE INDEX IF NOT EXISTS idx_documents_folder ON documents(folder_id)",
        "CREATE INDEX IF NOT EXISTS idx_documents_location_kind ON documents(location_kind)",
        "CREATE INDEX IF NOT EXISTS idx_documents_file_hash ON documents(file_hash)",
        "CREATE INDEX IF NOT EXISTS idx_documents_file_name_lower ON documents(file_name_lower)",
        """
        CREATE TABLE IF NOT EXISTS extraction_state (
            document_id          TEXT NOT NULL PRIMARY KEY,
            status               TEXT NOT NULL CHECK (status IN (
                                    'pending', 'complete', 'partial', 'no_text',
                                    'failed', 'unsupported', 'skipped')),
            extractor_id         TEXT,
            extractor_version    INTEGER,
            method_label         TEXT,
            pages_total          INTEGER,
            pages_processed      INTEGER,
            error_code           TEXT,
            error_message        TEXT,
            attempts             INTEGER NOT NULL DEFAULT 0,
            next_retry_after_iso TEXT,
            finished_at_iso      TEXT,
            FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE CASCADE
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_extraction_state_status ON extraction_state(status)",
        "CREATE INDEX IF NOT EXISTS idx_extraction_state_error_code ON extraction_state(error_code)",
        """
        CREATE TABLE IF NOT EXISTS texts (
            text_hash       TEXT NOT NULL PRIMARY KEY,
            content         TEXT NOT NULL,
            utf16_length    INTEGER NOT NULL,
            language_code   TEXT,
            created_at_iso  TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS text_pages (
            text_hash       TEXT NOT NULL,
            page_number     INTEGER NOT NULL,
            utf16_start     INTEGER NOT NULL,
            utf16_end       INTEGER NOT NULL,
            PRIMARY KEY (text_hash, page_number),
            FOREIGN KEY (text_hash) REFERENCES texts(text_hash) ON DELETE CASCADE
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS text_variants (
            id                  TEXT NOT NULL PRIMARY KEY,
            document_id         TEXT NOT NULL,
            variant_type        TEXT NOT NULL CHECK (variant_type IN ('original', 'anonymized')),
            text_hash           TEXT NOT NULL,
            source_variant_id   TEXT,
            is_current          INTEGER NOT NULL DEFAULT 1 CHECK (is_current IN (0, 1)),
            created_at_iso      TEXT NOT NULL,
            updated_at_iso      TEXT NOT NULL,
            FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE CASCADE,
            FOREIGN KEY (text_hash) REFERENCES texts(text_hash) ON DELETE RESTRICT,
            FOREIGN KEY (source_variant_id) REFERENCES text_variants(id) ON DELETE SET NULL,
            UNIQUE (document_id, variant_type)
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_text_variants_text_hash ON text_variants(text_hash)",
        "CREATE INDEX IF NOT EXISTS idx_text_variants_document_current ON text_variants(document_id, is_current)",
        """
        CREATE TABLE IF NOT EXISTS chunks (
            rowid           INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
            id              TEXT NOT NULL UNIQUE,
            text_hash       TEXT NOT NULL,
            chunk_index     INTEGER NOT NULL,
            utf16_start     INTEGER NOT NULL,
            utf16_end       INTEGER NOT NULL,
            page_number     INTEGER,
            section_path    TEXT,
            FOREIGN KEY (text_hash) REFERENCES texts(text_hash) ON DELETE CASCADE,
            UNIQUE (text_hash, chunk_index)
        )
        """,
        // file_name_norm первым: bm25(chunk_fts, 5.0, 1.0) даёт имени вес 5, как в v1.
        // Имя — склейка нормализованных имён всех документов с текущим вариантом этого текста.
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS chunk_fts USING fts5(
            file_name_norm,
            content_norm,
            content='',
            contentless_delete=1,
            tokenize='\(ftsTokenizer)'
        )
        """,
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(
            file_name_norm,
            relative_path_norm,
            content='',
            contentless_delete=1,
            tokenize='\(ftsTokenizer)'
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS embedding_models (
            model_id        TEXT NOT NULL PRIMARY KEY,
            provider        TEXT NOT NULL,
            dim             INTEGER NOT NULL,
            quantization    TEXT NOT NULL,
            created_at_iso  TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS chunk_embeddings (
            chunk_rowid     INTEGER NOT NULL,
            model_id        TEXT NOT NULL,
            scale           REAL NOT NULL,
            vector          BLOB NOT NULL,
            created_at_iso  TEXT NOT NULL,
            PRIMARY KEY (chunk_rowid, model_id),
            FOREIGN KEY (chunk_rowid) REFERENCES chunks(rowid) ON DELETE CASCADE,
            FOREIGN KEY (model_id) REFERENCES embedding_models(model_id) ON DELETE CASCADE
        ) WITHOUT ROWID
        """,
        "CREATE INDEX IF NOT EXISTS idx_chunk_embeddings_model ON chunk_embeddings(model_id, chunk_rowid)",
        """
        CREATE TABLE IF NOT EXISTS index_jobs (
            id              TEXT NOT NULL PRIMARY KEY,
            kind            TEXT NOT NULL CHECK (kind IN ('extract', 'embed')),
            target          TEXT NOT NULL,
            model_id        TEXT,
            priority        INTEGER NOT NULL DEFAULT 0,
            state           TEXT NOT NULL CHECK (state IN ('queued', 'running', 'done', 'failed')),
            attempts        INTEGER NOT NULL DEFAULT 0,
            last_error      TEXT,
            created_at_iso  TEXT NOT NULL,
            updated_at_iso  TEXT NOT NULL,
            FOREIGN KEY (model_id) REFERENCES embedding_models(model_id) ON DELETE CASCADE
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_index_jobs_state_priority ON index_jobs(state, priority DESC, created_at_iso)",
        "CREATE INDEX IF NOT EXISTS idx_index_jobs_kind_state ON index_jobs(kind, state)",
        // Одна активная задача на цель и модель; NULL у model_id схлопывается в пустую строку.
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_index_jobs_active_target
            ON index_jobs(kind, target, COALESCE(model_id, '')) WHERE state IN ('queued', 'running')
        """,
    ]

    /// DDL расширений Finder. `CREATE IF NOT EXISTS` — существующие базы v2
    /// получают таблицы при следующем открытии писателем, без смены `user_version`.
    static let extensionStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS case_document_links (
            case_id TEXT NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
            document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            attached_at_iso TEXT NOT NULL,
            sort_index INTEGER NOT NULL DEFAULT 0 CHECK (sort_index >= 0),
            PRIMARY KEY(case_id, document_id)
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_case_document_links_document ON case_document_links(document_id, case_id)",
        "CREATE INDEX IF NOT EXISTS idx_case_document_links_order ON case_document_links(case_id, sort_index, document_id)",
        "CREATE TABLE IF NOT EXISTS index_removals (root_id TEXT NOT NULL, path TEXT NOT NULL, removed_at_iso TEXT NOT NULL, PRIMARY KEY(root_id, path))",
        "CREATE TABLE IF NOT EXISTS text_variant_history (id TEXT PRIMARY KEY, document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE, variant_type TEXT NOT NULL, text_hash TEXT NOT NULL REFERENCES texts(text_hash), source_file_hash TEXT, archived_at_iso TEXT NOT NULL, pages_json TEXT NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_text_variant_history_hash ON text_variant_history(text_hash)",
        "CREATE TABLE IF NOT EXISTS extraction_fingerprints (document_id TEXT PRIMARY KEY REFERENCES documents(id) ON DELETE CASCADE, source_file_hash TEXT)",
        "CREATE TABLE IF NOT EXISTS variant_pages (variant_id TEXT NOT NULL REFERENCES text_variants(id) ON DELETE CASCADE, page_number INTEGER NOT NULL, utf16_start INTEGER NOT NULL, utf16_end INTEGER NOT NULL, PRIMARY KEY(variant_id, page_number))",
        """
        CREATE TABLE IF NOT EXISTS case_metadata (
            case_id                 TEXT NOT NULL PRIMARY KEY,
            case_number             TEXT NOT NULL DEFAULT '',
            case_description        TEXT NOT NULL DEFAULT '',
            goals                   TEXT NOT NULL DEFAULT '',
            tasks                   TEXT NOT NULL DEFAULT '',
            user_role               TEXT NOT NULL DEFAULT '',
            strategy                TEXT NOT NULL DEFAULT '',
            key_points              TEXT NOT NULL DEFAULT '',
            risks                   TEXT NOT NULL DEFAULT '',
            expected_outcome        TEXT NOT NULL DEFAULT '',
            client_instructions     TEXT NOT NULL DEFAULT '',
            court                   TEXT NOT NULL DEFAULT '',
            category                TEXT NOT NULL DEFAULT '',
            status                  TEXT NOT NULL DEFAULT '',
            legalic_guid            TEXT NOT NULL DEFAULT '',
            lmpm_guid               TEXT NOT NULL DEFAULT '',
            participants_json       TEXT NOT NULL DEFAULT '[]',
            extra_json              TEXT,
            created_at_iso          TEXT NOT NULL,
            updated_at_iso          TEXT NOT NULL,
            FOREIGN KEY (case_id) REFERENCES cases(id) ON DELETE CASCADE
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS case_facts (
            id              TEXT NOT NULL PRIMARY KEY,
            case_id         TEXT NOT NULL,
            sort_index      INTEGER NOT NULL,
            title           TEXT NOT NULL,
            body            TEXT NOT NULL DEFAULT '',
            payload_json    TEXT NOT NULL DEFAULT '{}',
            created_at_iso  TEXT NOT NULL,
            updated_at_iso  TEXT NOT NULL,
            FOREIGN KEY (case_id) REFERENCES cases(id) ON DELETE CASCADE
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_case_facts_case ON case_facts(case_id, sort_index)",
        """
        CREATE TABLE IF NOT EXISTS case_evidences (
            id              TEXT NOT NULL PRIMARY KEY,
            case_id         TEXT NOT NULL,
            sort_index      INTEGER NOT NULL,
            title           TEXT NOT NULL,
            body            TEXT NOT NULL DEFAULT '',
            payload_json    TEXT NOT NULL DEFAULT '{}',
            created_at_iso  TEXT NOT NULL,
            updated_at_iso  TEXT NOT NULL,
            FOREIGN KEY (case_id) REFERENCES cases(id) ON DELETE CASCADE
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_case_evidences_case ON case_evidences(case_id, sort_index)",
        """
        CREATE TABLE IF NOT EXISTS case_circumstances (
            id              TEXT NOT NULL PRIMARY KEY,
            case_id         TEXT NOT NULL,
            sort_index      INTEGER NOT NULL,
            title           TEXT NOT NULL,
            body            TEXT NOT NULL DEFAULT '',
            payload_json    TEXT NOT NULL DEFAULT '{}',
            created_at_iso  TEXT NOT NULL,
            updated_at_iso  TEXT NOT NULL,
            FOREIGN KEY (case_id) REFERENCES cases(id) ON DELETE CASCADE
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_case_circumstances_case ON case_circumstances(case_id, sort_index)",
        """
        CREATE TABLE IF NOT EXISTS case_lawyer_tasks (
            id              TEXT NOT NULL PRIMARY KEY,
            case_id         TEXT NOT NULL,
            sort_index      INTEGER NOT NULL,
            title           TEXT NOT NULL,
            body            TEXT NOT NULL DEFAULT '',
            payload_json    TEXT NOT NULL DEFAULT '{}',
            created_at_iso  TEXT NOT NULL,
            updated_at_iso  TEXT NOT NULL,
            FOREIGN KEY (case_id) REFERENCES cases(id) ON DELETE CASCADE
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_case_lawyer_tasks_case ON case_lawyer_tasks(case_id, sort_index)",
        """
        CREATE TABLE IF NOT EXISTS case_tags (
            id              TEXT NOT NULL PRIMARY KEY,
            case_id         TEXT NOT NULL,
            sort_index      INTEGER NOT NULL,
            name            TEXT NOT NULL,
            color           TEXT,
            payload_json    TEXT,
            created_at_iso  TEXT NOT NULL,
            FOREIGN KEY (case_id) REFERENCES cases(id) ON DELETE CASCADE
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_case_tags_case ON case_tags(case_id, sort_index)",
        """
        CREATE TABLE IF NOT EXISTS document_relations (
            id                  TEXT NOT NULL PRIMARY KEY,
            case_id             TEXT NOT NULL,
            source_document_id  TEXT NOT NULL,
            target_document_id  TEXT NOT NULL,
            relation_type       TEXT NOT NULL,
            sort_index          INTEGER NOT NULL DEFAULT 0,
            payload_json        TEXT,
            created_at_iso      TEXT NOT NULL,
            FOREIGN KEY (case_id) REFERENCES cases(id) ON DELETE CASCADE,
            FOREIGN KEY (source_document_id) REFERENCES documents(id) ON DELETE CASCADE,
            FOREIGN KEY (target_document_id) REFERENCES documents(id) ON DELETE CASCADE
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_document_relations_case ON document_relations(case_id)",
        """
        CREATE TABLE IF NOT EXISTS document_user_metadata (
            document_id             TEXT NOT NULL PRIMARY KEY,
            notes                   TEXT,
            importance              TEXT NOT NULL DEFAULT 'normal',
            confidentiality         TEXT NOT NULL DEFAULT 'public',
            legal_relevance         TEXT NOT NULL DEFAULT 'normal',
            is_evidence             INTEGER NOT NULL DEFAULT 0 CHECK (is_evidence IN (0, 1)),
            evidence_description    TEXT,
            tags_json               TEXT NOT NULL DEFAULT '[]',
            payload_json            TEXT,
            updated_at_iso          TEXT NOT NULL,
            FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE CASCADE
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS anonymization_runs (
            id                      TEXT NOT NULL PRIMARY KEY,
            document_id             TEXT NOT NULL,
            case_id                 TEXT,
            source_text_variant_id  TEXT,
            result_text_variant_id  TEXT,
            status                  TEXT NOT NULL,
            anonymization_method    TEXT,
            model_name              TEXT,
            notes                   TEXT,
            rules_json              TEXT,
            created_at_iso          TEXT NOT NULL,
            updated_at_iso          TEXT NOT NULL,
            FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE CASCADE,
            FOREIGN KEY (case_id) REFERENCES cases(id) ON DELETE SET NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_anonymization_runs_document ON anonymization_runs(document_id)",
        """
        CREATE TABLE IF NOT EXISTS anonymization_entities (
            id                      TEXT NOT NULL PRIMARY KEY,
            anonymization_run_id    TEXT NOT NULL,
            case_id                 TEXT,
            entity_type             TEXT NOT NULL,
            entity_subtype          TEXT,
            original_value          TEXT NOT NULL,
            replacement_value       TEXT NOT NULL,
            normalized_original     TEXT,
            normalized_replacement  TEXT,
            legal_role              TEXT,
            person_gender           TEXT,
            person_kind             TEXT,
            number_type             TEXT,
            confidence              REAL,
            metadata_json           TEXT,
            FOREIGN KEY (anonymization_run_id) REFERENCES anonymization_runs(id) ON DELETE CASCADE,
            FOREIGN KEY (case_id) REFERENCES cases(id) ON DELETE SET NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_anonymization_entities_run ON anonymization_entities(anonymization_run_id)",
        """
        CREATE TABLE IF NOT EXISTS anonymization_occurrences (
            id                      TEXT NOT NULL PRIMARY KEY,
            entity_id               TEXT NOT NULL,
            case_id                 TEXT,
            source_text_variant_id  TEXT,
            result_text_variant_id  TEXT,
            original_fragment       TEXT,
            replacement_fragment    TEXT,
            source_start_offset     INTEGER,
            source_end_offset       INTEGER,
            result_start_offset     INTEGER,
            result_end_offset       INTEGER,
            occurrence_index        INTEGER,
            FOREIGN KEY (entity_id) REFERENCES anonymization_entities(id) ON DELETE CASCADE,
            FOREIGN KEY (case_id) REFERENCES cases(id) ON DELETE SET NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_anonymization_occurrences_entity ON anonymization_occurrences(entity_id)",
        """
        CREATE TABLE IF NOT EXISTS file_bookmarks (
            id              TEXT NOT NULL PRIMARY KEY,
            target_path     TEXT NOT NULL UNIQUE,
            bookmark_blob   BLOB NOT NULL,
            created_at_iso  TEXT NOT NULL,
            updated_at_iso  TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS extraction_page_results (
            document_id             TEXT NOT NULL,
            source_file_hash        TEXT NOT NULL,
            extraction_config_id    TEXT NOT NULL,
            page_number             INTEGER NOT NULL,
            text                    TEXT NOT NULL DEFAULT '',
            status                  TEXT NOT NULL,
            method                  TEXT,
            error_code              TEXT,
            error_message           TEXT,
            updated_at_iso          TEXT NOT NULL,
            PRIMARY KEY (document_id, source_file_hash, extraction_config_id, page_number),
            FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE CASCADE
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_extraction_page_results_document ON extraction_page_results(document_id)",
    ]

    static func create(in db: SQLite.Connection) throws {
        for statement in statements + extensionStatements {
            try db.execute(statement)
        }
    }
}
