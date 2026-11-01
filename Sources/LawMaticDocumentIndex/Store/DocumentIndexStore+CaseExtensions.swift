import Foundation
import SQLite

extension DocumentIndexStore {

    // MARK: - Карточка дела

    @discardableResult
    public func upsertCaseCard(_ card: CaseCardRecord) throws -> CaseCardRecord {
        try write { db in
            try Self.requireCase(db, id: card.caseId)
            let now = Self.iso(Date())
            let createdISO = Self.iso(card.createdAt)
            try db.run(
                """
                INSERT INTO case_metadata(
                    case_id, case_number, case_description, goals, tasks, user_role,
                    strategy, key_points, risks, expected_outcome, client_instructions,
                    court, category, status, legalic_guid, lmpm_guid,
                    participants_json, extra_json, created_at_iso, updated_at_iso
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(case_id) DO UPDATE SET
                    case_number = excluded.case_number,
                    case_description = excluded.case_description,
                    goals = excluded.goals,
                    tasks = excluded.tasks,
                    user_role = excluded.user_role,
                    strategy = excluded.strategy,
                    key_points = excluded.key_points,
                    risks = excluded.risks,
                    expected_outcome = excluded.expected_outcome,
                    client_instructions = excluded.client_instructions,
                    court = excluded.court,
                    category = excluded.category,
                    status = excluded.status,
                    legalic_guid = excluded.legalic_guid,
                    lmpm_guid = excluded.lmpm_guid,
                    participants_json = excluded.participants_json,
                    extra_json = excluded.extra_json,
                    updated_at_iso = excluded.updated_at_iso
                """,
                card.caseId, card.caseNumber, card.caseDescription, card.goals, card.tasks,
                card.userRole, card.strategy, card.keyPoints, card.risks, card.expectedOutcome,
                card.clientInstructions, card.court, card.category, card.status,
                card.legalicGuid, card.lmpmGuid, card.participantsJSON, card.extraJSON,
                createdISO, now
            )
            guard let stored = try Self.caseCard(db, caseId: card.caseId) else {
                throw DocumentIndexError.notFound("карточка \(card.caseId)")
            }
            return stored
        }
    }

    public func caseCard(caseId: String) throws -> CaseCardRecord? {
        try Self.caseCard(try db(), caseId: caseId)
    }

    // MARK: - Списки дела

    @discardableResult
    public func upsertCaseListItem(_ item: CaseListItemRecord) throws -> CaseListItemRecord {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw DocumentIndexError.invalidArgument("пустой заголовок записи дела")
        }
        return try write { db in
            try Self.requireCase(db, id: item.caseId)
            let isNew = item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let id = isNew ? UUID().uuidString : item.id
            let now = Self.iso(Date())
            let createdISO = isNew ? now : Self.iso(item.createdAt)
            let table = item.kind.tableName
            try db.run(
                """
                INSERT INTO \(table)(id, case_id, sort_index, title, body, payload_json, created_at_iso, updated_at_iso)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    case_id = excluded.case_id,
                    sort_index = excluded.sort_index,
                    title = excluded.title,
                    body = excluded.body,
                    payload_json = excluded.payload_json,
                    updated_at_iso = excluded.updated_at_iso
                """,
                id, item.caseId, Int64(item.sortIndex), title, item.body, item.payloadJSON, createdISO, now
            )
            guard let stored = try Self.caseListItem(db, kind: item.kind, id: id) else {
                throw DocumentIndexError.notFound("запись \(id)")
            }
            return stored
        }
    }

    public func deleteCaseListItem(kind: CaseListKind, id: String) throws {
        try write { db in
            guard try Self.caseListItem(db, kind: kind, id: id) != nil else {
                throw DocumentIndexError.notFound("запись \(id)")
            }
            try db.run("DELETE FROM \(kind.tableName) WHERE id = ?", id)
        }
    }

    public func caseListItems(caseId: String, kind: CaseListKind) throws -> [CaseListItemRecord] {
        try Self.allRows(
            try db(),
            """
            SELECT id, case_id, sort_index, title, body, payload_json, created_at_iso, updated_at_iso
            FROM \(kind.tableName) WHERE case_id = ? ORDER BY sort_index, created_at_iso
            """,
            [caseId]
        ) { try Self.parseListItem($0, kind: kind) }
    }

    // MARK: - Теги дела

    @discardableResult
    public func upsertCaseTag(_ tag: CaseTagRecord) throws -> CaseTagRecord {
        let name = tag.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw DocumentIndexError.invalidArgument("пустое имя тега")
        }
        return try write { db in
            try Self.requireCase(db, id: tag.caseId)
            let isNew = tag.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let id = isNew ? UUID().uuidString : tag.id
            let createdISO = isNew ? Self.iso(Date()) : Self.iso(tag.createdAt)
            try db.run(
                """
                INSERT INTO case_tags(id, case_id, sort_index, name, color, payload_json, created_at_iso)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    case_id = excluded.case_id,
                    sort_index = excluded.sort_index,
                    name = excluded.name,
                    color = excluded.color,
                    payload_json = excluded.payload_json
                """,
                id, tag.caseId, Int64(tag.sortIndex), name, tag.color, tag.payloadJSON, createdISO
            )
            guard let stored = try Self.caseTag(db, id: id) else {
                throw DocumentIndexError.notFound("тег \(id)")
            }
            return stored
        }
    }

    public func deleteCaseTag(id: String) throws {
        try write { db in
            guard try Self.caseTag(db, id: id) != nil else {
                throw DocumentIndexError.notFound("тег \(id)")
            }
            try db.run("DELETE FROM case_tags WHERE id = ?", id)
        }
    }

    public func caseTags(caseId: String) throws -> [CaseTagRecord] {
        try Self.allRows(
            try db(),
            """
            SELECT id, case_id, sort_index, name, color, payload_json, created_at_iso
            FROM case_tags WHERE case_id = ? ORDER BY sort_index, created_at_iso
            """,
            [caseId],
            parse: Self.parseTag
        )
    }

    // MARK: - Метаданные документа

    @discardableResult
    public func upsertDocumentUserMetadata(_ record: DocumentUserMetadataRecord) throws -> DocumentUserMetadataRecord {
        try write { db in
            guard try Self.document(db, id: record.documentId) != nil else {
                throw DocumentIndexError.notFound("документ \(record.documentId)")
            }
            let now = Self.iso(Date())
            try db.run(
                """
                INSERT INTO document_user_metadata(
                    document_id, notes, importance, confidentiality, legal_relevance,
                    is_evidence, evidence_description, tags_json, payload_json, updated_at_iso
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(document_id) DO UPDATE SET
                    notes = excluded.notes,
                    importance = excluded.importance,
                    confidentiality = excluded.confidentiality,
                    legal_relevance = excluded.legal_relevance,
                    is_evidence = excluded.is_evidence,
                    evidence_description = excluded.evidence_description,
                    tags_json = excluded.tags_json,
                    payload_json = excluded.payload_json,
                    updated_at_iso = excluded.updated_at_iso
                """,
                record.documentId, record.notes, record.importance, record.confidentiality,
                record.legalRelevance, record.isEvidence ? 1 : 0, record.evidenceDescription,
                record.tagsJSON, record.payloadJSON, now
            )
            guard let stored = try Self.documentUserMetadata(db, documentId: record.documentId) else {
                throw DocumentIndexError.notFound("метаданные \(record.documentId)")
            }
            return stored
        }
    }

    public func documentUserMetadata(documentId: String) throws -> DocumentUserMetadataRecord? {
        try Self.documentUserMetadata(try db(), documentId: documentId)
    }

    /// Lightweight batch lookup for directory listings; never loads text variants or maps.
    public func documentConfidentialities(workspaceRootId: String?, relativePaths: [String], absolutePaths: [String]) throws
        -> (workspace: [String: String], external: [String: String]) {
        let connection = try db()
        func lookup(column: String, predicate: String, prefix: [String], paths: [String]) throws -> [String: String] {
            let paths = Array(Set(paths))
            var result: [String: String] = [:]
            // Stay below SQLite's variable limit even for very large directories.
            for start in stride(from: 0, to: paths.count, by: 400) {
                let batch = Array(paths[start..<min(start + 400, paths.count)])
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
                let rows = try Self.allRows(connection, """
                    SELECT d.\(column), COALESCE(m.confidentiality, 'public')
                    FROM documents d LEFT JOIN document_user_metadata m ON m.document_id = d.id
                    WHERE \(predicate) AND d.\(column) IN (\(placeholders))
                    """, (prefix + batch).map { $0 as Binding? }, parse: { reader -> (String, String) in
                        guard let path = reader.string(0), let level = reader.string(1) else {
                            throw DocumentIndexError.invalidArgument("incomplete document privacy metadata")
                        }
                        return (path, level)
                    })
                for (path, level) in rows { result[path] = level }
            }
            return result
        }
        let workspace: [String: String]
        if let workspaceRootId {
            workspace = try lookup(column: "relative_path", predicate: "d.location_kind = 'workspace' AND d.workspace_root_id = ?",
                prefix: [workspaceRootId], paths: relativePaths.map { try SearchScope.validatedRelativePath($0) })
        } else { workspace = [:] }
        let external = try lookup(column: "absolute_path", predicate: "d.location_kind = 'external'", prefix: [],
            paths: absolutePaths.map(Self.normalizeLocalPath))
        return (workspace, external)
    }

    // MARK: - Анонимизация

    @discardableResult
    public func upsertAnonymizationRun(
        _ run: AnonymizationRunRecord,
        entities: [AnonymizationEntityRecord],
        occurrences: [AnonymizationOccurrenceRecord] = []
    ) throws -> (AnonymizationRunRecord, [AnonymizationEntityRecord]) {
        try write { db in
            guard try Self.document(db, id: run.documentId) != nil else {
                throw DocumentIndexError.notFound("документ \(run.documentId)")
            }
            if let caseId = run.caseId {
                try Self.requireCase(db, id: caseId)
            }
            let isNew = run.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let id = isNew ? UUID().uuidString : run.id
            let now = Self.iso(Date())
            let createdISO = isNew ? now : Self.iso(run.createdAt)
            try db.run(
                """
                INSERT INTO anonymization_runs(
                    id, document_id, case_id, source_text_variant_id, result_text_variant_id,
                    status, anonymization_method, model_name, notes, rules_json,
                    created_at_iso, updated_at_iso
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    document_id = excluded.document_id,
                    case_id = excluded.case_id,
                    source_text_variant_id = excluded.source_text_variant_id,
                    result_text_variant_id = excluded.result_text_variant_id,
                    status = excluded.status,
                    anonymization_method = excluded.anonymization_method,
                    model_name = excluded.model_name,
                    notes = excluded.notes,
                    rules_json = excluded.rules_json,
                    updated_at_iso = excluded.updated_at_iso
                """,
                id, run.documentId, run.caseId, run.sourceTextVariantId, run.resultTextVariantId,
                run.status, run.method, run.modelName, run.notes, run.rulesJSON, createdISO, now
            )
            try db.run("DELETE FROM anonymization_entities WHERE anonymization_run_id = ?", id)
            var storedEntities: [AnonymizationEntityRecord] = []
            var entityIdByIncoming: [String: String] = [:]
            for entity in entities {
                let entityId = entity.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? UUID().uuidString
                    : entity.id
                if !entity.id.isEmpty {
                    entityIdByIncoming[entity.id] = entityId
                }
                entityIdByIncoming["\(entity.originalValue)\u{1e}\(entity.replacementValue)"] = entityId
                try db.run(
                    """
                    INSERT INTO anonymization_entities(
                        id, anonymization_run_id, case_id, entity_type, entity_subtype,
                        original_value, replacement_value, normalized_original, normalized_replacement,
                        legal_role, person_gender, person_kind, number_type, confidence, metadata_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    entityId, id, entity.caseId ?? run.caseId, entity.entityType, entity.entitySubtype,
                    entity.originalValue, entity.replacementValue, entity.normalizedOriginal,
                    entity.normalizedReplacement, entity.legalRole, entity.personGender,
                    entity.personKind, entity.numberType, entity.confidence, entity.metadataJSON
                )
                if let stored = try Self.anonymizationEntity(db, id: entityId) {
                    storedEntities.append(stored)
                }
            }
            for occurrence in occurrences {
                let resolvedEntityId = Self.resolveOccurrenceEntityId(
                    occurrence,
                    incoming: entityIdByIncoming,
                    stored: storedEntities
                )
                guard let resolvedEntityId,
                      storedEntities.contains(where: { $0.id == resolvedEntityId }) else {
                    continue
                }
                let occurrenceId = occurrence.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? UUID().uuidString
                    : occurrence.id
                try db.run(
                    """
                    INSERT INTO anonymization_occurrences(
                        id, entity_id, case_id, source_text_variant_id, result_text_variant_id,
                        original_fragment, replacement_fragment, source_start_offset, source_end_offset,
                        result_start_offset, result_end_offset, occurrence_index
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    occurrenceId,
                    resolvedEntityId,
                    occurrence.caseId ?? run.caseId,
                    occurrence.sourceTextVariantId ?? run.sourceTextVariantId,
                    occurrence.resultTextVariantId ?? run.resultTextVariantId,
                    occurrence.originalFragment,
                    occurrence.replacementFragment,
                    occurrence.sourceStartOffset.map { Int64($0) },
                    occurrence.sourceEndOffset.map { Int64($0) },
                    occurrence.resultStartOffset.map { Int64($0) },
                    occurrence.resultEndOffset.map { Int64($0) },
                    occurrence.occurrenceIndex.map { Int64($0) }
                )
            }
            guard let storedRun = try Self.anonymizationRun(db, id: id) else {
                throw DocumentIndexError.notFound("запуск анонимизации \(id)")
            }
            return (storedRun, storedEntities)
        }
    }

    public func latestAnonymizationRun(documentId: String) throws -> (AnonymizationRunRecord, [AnonymizationEntityRecord])? {
        let db = try db()
        guard let run = try Self.firstRow(
            db,
            """
            SELECT id, document_id, case_id, source_text_variant_id, result_text_variant_id,
                   status, anonymization_method, model_name, notes, rules_json,
                   created_at_iso, updated_at_iso
            FROM anonymization_runs WHERE document_id = ?
            ORDER BY updated_at_iso DESC LIMIT 1
            """,
            [documentId],
            parse: Self.parseAnonymizationRun
        ) else { return nil }
        let entities = try Self.allRows(
            db,
            """
            SELECT id, anonymization_run_id, case_id, entity_type, entity_subtype,
                   original_value, replacement_value, normalized_original, normalized_replacement,
                   legal_role, person_gender, person_kind, number_type, confidence, metadata_json
            FROM anonymization_entities WHERE anonymization_run_id = ?
            """,
            [run.id],
            parse: Self.parseAnonymizationEntity
        )
        return (run, entities)
    }

    public func anonymizationOccurrences(runId: String) throws -> [AnonymizationOccurrenceRecord] {
        try Self.allRows(
            try db(),
            """
            SELECT o.id, o.entity_id, o.case_id, o.source_text_variant_id, o.result_text_variant_id,
                   o.original_fragment, o.replacement_fragment, o.source_start_offset, o.source_end_offset,
                   o.result_start_offset, o.result_end_offset, o.occurrence_index
            FROM anonymization_occurrences o
            JOIN anonymization_entities e ON e.id = o.entity_id
            WHERE e.anonymization_run_id = ?
            ORDER BY o.occurrence_index, o.id
            """,
            [runId],
            parse: Self.parseAnonymizationOccurrence
        )
    }

    public func anonymizationOccurrences(entityId: String) throws -> [AnonymizationOccurrenceRecord] {
        try Self.allRows(
            try db(),
            """
            SELECT id, entity_id, case_id, source_text_variant_id, result_text_variant_id,
                   original_fragment, replacement_fragment, source_start_offset, source_end_offset,
                   result_start_offset, result_end_offset, occurrence_index
            FROM anonymization_occurrences WHERE entity_id = ?
            ORDER BY occurrence_index, id
            """,
            [entityId],
            parse: Self.parseAnonymizationOccurrence
        )
    }

    // MARK: - Связи документов

    @discardableResult
    public func upsertDocumentRelation(_ relation: DocumentRelationRecord) throws -> DocumentRelationRecord {
        let type = relation.relationType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !type.isEmpty else {
            throw DocumentIndexError.invalidArgument("пустой тип связи документов")
        }
        return try write { db in
            try Self.requireCase(db, id: relation.caseId)
            guard try Self.document(db, id: relation.sourceDocumentId) != nil else {
                throw DocumentIndexError.notFound("документ \(relation.sourceDocumentId)")
            }
            guard try Self.document(db, id: relation.targetDocumentId) != nil else {
                throw DocumentIndexError.notFound("документ \(relation.targetDocumentId)")
            }
            let isNew = relation.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let id = isNew ? UUID().uuidString : relation.id
            let createdISO = isNew ? Self.iso(Date()) : Self.iso(relation.createdAt)
            try db.run(
                """
                INSERT INTO document_relations(
                    id, case_id, source_document_id, target_document_id,
                    relation_type, sort_index, payload_json, created_at_iso
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    case_id = excluded.case_id,
                    source_document_id = excluded.source_document_id,
                    target_document_id = excluded.target_document_id,
                    relation_type = excluded.relation_type,
                    sort_index = excluded.sort_index,
                    payload_json = excluded.payload_json
                """,
                id, relation.caseId, relation.sourceDocumentId, relation.targetDocumentId,
                type, Int64(relation.sortIndex), relation.payloadJSON, createdISO
            )
            guard let stored = try Self.documentRelation(db, id: id) else {
                throw DocumentIndexError.notFound("связь \(id)")
            }
            return stored
        }
    }

    public func deleteDocumentRelation(id: String) throws {
        try write { db in
            guard try Self.documentRelation(db, id: id) != nil else {
                throw DocumentIndexError.notFound("связь \(id)")
            }
            try db.run("DELETE FROM document_relations WHERE id = ?", id)
        }
    }

    public func documentRelations(caseId: String) throws -> [DocumentRelationRecord] {
        try Self.allRows(
            try db(),
            """
            SELECT id, case_id, source_document_id, target_document_id,
                   relation_type, sort_index, payload_json, created_at_iso
            FROM document_relations WHERE case_id = ? ORDER BY sort_index, created_at_iso
            """,
            [caseId],
            parse: Self.parseDocumentRelation
        )
    }

    public func replaceDocumentRelations(caseId: String, relations: [DocumentRelationRecord]) throws {
        try write { db in
            try Self.requireCase(db, id: caseId)
            try db.run("DELETE FROM document_relations WHERE case_id = ?", caseId)
        }
        for (index, relation) in relations.enumerated() {
            var item = relation
            item.caseId = caseId
            if item.sortIndex == 0 { item.sortIndex = index }
            _ = try upsertDocumentRelation(item)
        }
    }

    public func replaceCaseTags(caseId: String, tags: [CaseTagRecord]) throws {
        let existing = try caseTags(caseId: caseId)
        let incomingIds = Set(tags.map(\.id).filter { !$0.isEmpty })
        for old in existing where !incomingIds.contains(old.id) {
            try deleteCaseTag(id: old.id)
        }
        for (index, tag) in tags.enumerated() {
            var item = tag
            item.caseId = caseId
            if item.sortIndex == 0 { item.sortIndex = index }
            _ = try upsertCaseTag(item)
        }
    }

    // MARK: - Разбор

    static func requireCase(_ db: SQLite.Connection, id: String) throws {
        guard try caseRecord(db, id: id) != nil else {
            throw DocumentIndexError.notFound("дело \(id)")
        }
    }

    static func caseCard(_ db: SQLite.Connection, caseId: String) throws -> CaseCardRecord? {
        try firstRow(
            db,
            """
            SELECT case_id, case_number, case_description, goals, tasks, user_role,
                   strategy, key_points, risks, expected_outcome, client_instructions,
                   court, category, status, legalic_guid, lmpm_guid,
                   participants_json, extra_json, created_at_iso, updated_at_iso
            FROM case_metadata WHERE case_id = ?
            """,
            [caseId],
            parse: parseCaseCard
        )
    }

    static func parseCaseCard(_ reader: RowReader) throws -> CaseCardRecord {
        guard let caseId = reader.string(0) else {
            throw DocumentIndexError.invalidArgument("неполная карточка дела")
        }
        return CaseCardRecord(
            caseId: caseId,
            caseNumber: reader.string(1) ?? "",
            caseDescription: reader.string(2) ?? "",
            goals: reader.string(3) ?? "",
            tasks: reader.string(4) ?? "",
            userRole: reader.string(5) ?? "",
            strategy: reader.string(6) ?? "",
            keyPoints: reader.string(7) ?? "",
            risks: reader.string(8) ?? "",
            expectedOutcome: reader.string(9) ?? "",
            clientInstructions: reader.string(10) ?? "",
            court: reader.string(11) ?? "",
            category: reader.string(12) ?? "",
            status: reader.string(13) ?? "",
            legalicGuid: reader.string(14) ?? "",
            lmpmGuid: reader.string(15) ?? "",
            participantsJSON: reader.string(16) ?? "[]",
            extraJSON: reader.string(17),
            createdAt: try requireDate(reader, 18, field: "created_at"),
            updatedAt: try requireDate(reader, 19, field: "updated_at")
        )
    }

    static func caseListItem(_ db: SQLite.Connection, kind: CaseListKind, id: String) throws -> CaseListItemRecord? {
        try firstRow(
            db,
            """
            SELECT id, case_id, sort_index, title, body, payload_json, created_at_iso, updated_at_iso
            FROM \(kind.tableName) WHERE id = ?
            """,
            [id]
        ) { try parseListItem($0, kind: kind) }
    }

    static func parseListItem(_ reader: RowReader, kind: CaseListKind) throws -> CaseListItemRecord {
        guard let id = reader.string(0), let caseId = reader.string(1), let title = reader.string(3) else {
            throw DocumentIndexError.invalidArgument("неполная запись списка дела")
        }
        return CaseListItemRecord(
            id: id,
            caseId: caseId,
            kind: kind,
            sortIndex: reader.int(2) ?? 0,
            title: title,
            body: reader.string(4) ?? "",
            payloadJSON: reader.string(5) ?? "{}",
            createdAt: try requireDate(reader, 6, field: "created_at"),
            updatedAt: try requireDate(reader, 7, field: "updated_at")
        )
    }

    static func caseTag(_ db: SQLite.Connection, id: String) throws -> CaseTagRecord? {
        try firstRow(
            db,
            """
            SELECT id, case_id, sort_index, name, color, payload_json, created_at_iso
            FROM case_tags WHERE id = ?
            """,
            [id],
            parse: parseTag
        )
    }

    static func parseTag(_ reader: RowReader) throws -> CaseTagRecord {
        guard let id = reader.string(0), let caseId = reader.string(1), let name = reader.string(3) else {
            throw DocumentIndexError.invalidArgument("неполный тег дела")
        }
        return CaseTagRecord(
            id: id,
            caseId: caseId,
            sortIndex: reader.int(2) ?? 0,
            name: name,
            color: reader.string(4),
            payloadJSON: reader.string(5),
            createdAt: try requireDate(reader, 6, field: "created_at")
        )
    }

    static func documentUserMetadata(_ db: SQLite.Connection, documentId: String) throws -> DocumentUserMetadataRecord? {
        try firstRow(
            db,
            """
            SELECT document_id, notes, importance, confidentiality, legal_relevance,
                   is_evidence, evidence_description, tags_json, payload_json, updated_at_iso
            FROM document_user_metadata WHERE document_id = ?
            """,
            [documentId],
            parse: parseDocumentUserMetadata
        )
    }

    static func parseDocumentUserMetadata(_ reader: RowReader) throws -> DocumentUserMetadataRecord {
        guard let documentId = reader.string(0) else {
            throw DocumentIndexError.invalidArgument("неполные метаданные документа")
        }
        return DocumentUserMetadataRecord(
            documentId: documentId,
            notes: reader.string(1),
            importance: reader.string(2) ?? "normal",
            confidentiality: reader.string(3) ?? "public",
            legalRelevance: reader.string(4) ?? "normal",
            isEvidence: reader.bool(5),
            evidenceDescription: reader.string(6),
            tagsJSON: reader.string(7) ?? "[]",
            payloadJSON: reader.string(8),
            updatedAt: try requireDate(reader, 9, field: "updated_at")
        )
    }

    static func anonymizationRun(_ db: SQLite.Connection, id: String) throws -> AnonymizationRunRecord? {
        try firstRow(
            db,
            """
            SELECT id, document_id, case_id, source_text_variant_id, result_text_variant_id,
                   status, anonymization_method, model_name, notes, rules_json,
                   created_at_iso, updated_at_iso
            FROM anonymization_runs WHERE id = ?
            """,
            [id],
            parse: parseAnonymizationRun
        )
    }

    static func parseAnonymizationRun(_ reader: RowReader) throws -> AnonymizationRunRecord {
        guard let id = reader.string(0), let documentId = reader.string(1), let status = reader.string(5) else {
            throw DocumentIndexError.invalidArgument("неполный запуск анонимизации")
        }
        return AnonymizationRunRecord(
            id: id,
            documentId: documentId,
            caseId: reader.string(2),
            sourceTextVariantId: reader.string(3),
            resultTextVariantId: reader.string(4),
            status: status,
            method: reader.string(6),
            modelName: reader.string(7),
            notes: reader.string(8),
            rulesJSON: reader.string(9),
            createdAt: try requireDate(reader, 10, field: "created_at"),
            updatedAt: try requireDate(reader, 11, field: "updated_at")
        )
    }

    static func anonymizationEntity(_ db: SQLite.Connection, id: String) throws -> AnonymizationEntityRecord? {
        try firstRow(
            db,
            """
            SELECT id, anonymization_run_id, case_id, entity_type, entity_subtype,
                   original_value, replacement_value, normalized_original, normalized_replacement,
                   legal_role, person_gender, person_kind, number_type, confidence, metadata_json
            FROM anonymization_entities WHERE id = ?
            """,
            [id],
            parse: parseAnonymizationEntity
        )
    }

    static func parseAnonymizationEntity(_ reader: RowReader) throws -> AnonymizationEntityRecord {
        guard let id = reader.string(0), let runId = reader.string(1),
              let entityType = reader.string(3),
              let original = reader.string(5), let replacement = reader.string(6) else {
            throw DocumentIndexError.invalidArgument("неполная сущность анонимизации")
        }
        return AnonymizationEntityRecord(
            id: id,
            runId: runId,
            caseId: reader.string(2),
            entityType: entityType,
            entitySubtype: reader.string(4),
            originalValue: original,
            replacementValue: replacement,
            normalizedOriginal: reader.string(7),
            normalizedReplacement: reader.string(8),
            legalRole: reader.string(9),
            personGender: reader.string(10),
            personKind: reader.string(11),
            numberType: reader.string(12),
            confidence: reader.double(13),
            metadataJSON: reader.string(14)
        )
    }

    static func documentRelation(_ db: SQLite.Connection, id: String) throws -> DocumentRelationRecord? {
        try firstRow(
            db,
            """
            SELECT id, case_id, source_document_id, target_document_id,
                   relation_type, sort_index, payload_json, created_at_iso
            FROM document_relations WHERE id = ?
            """,
            [id],
            parse: parseDocumentRelation
        )
    }

    static func parseDocumentRelation(_ reader: RowReader) throws -> DocumentRelationRecord {
        guard let id = reader.string(0), let caseId = reader.string(1),
              let source = reader.string(2), let target = reader.string(3),
              let type = reader.string(4) else {
            throw DocumentIndexError.invalidArgument("неполная связь документов")
        }
        return DocumentRelationRecord(
            id: id,
            caseId: caseId,
            sourceDocumentId: source,
            targetDocumentId: target,
            relationType: type,
            sortIndex: reader.int(5) ?? 0,
            payloadJSON: reader.string(6),
            createdAt: try requireDate(reader, 7, field: "created_at")
        )
    }

    static func parseAnonymizationOccurrence(_ reader: RowReader) throws -> AnonymizationOccurrenceRecord {
        guard let id = reader.string(0), let entityId = reader.string(1) else {
            throw DocumentIndexError.invalidArgument("неполное вхождение анонимизации")
        }
        return AnonymizationOccurrenceRecord(
            id: id,
            entityId: entityId,
            caseId: reader.string(2),
            sourceTextVariantId: reader.string(3),
            resultTextVariantId: reader.string(4),
            originalFragment: reader.string(5),
            replacementFragment: reader.string(6),
            sourceStartOffset: reader.int(7),
            sourceEndOffset: reader.int(8),
            resultStartOffset: reader.int(9),
            resultEndOffset: reader.int(10),
            occurrenceIndex: reader.int(11)
        )
    }

    static func resolveOccurrenceEntityId(
        _ occurrence: AnonymizationOccurrenceRecord,
        incoming: [String: String],
        stored: [AnonymizationEntityRecord]
    ) -> String? {
        let raw = occurrence.entityId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            if stored.contains(where: { $0.id == raw }) { return raw }
            if let mapped = incoming[raw] { return mapped }
        }
        if let original = occurrence.originalFragment, let replacement = occurrence.replacementFragment {
            let key = "\(original)\u{1e}\(replacement)"
            if let mapped = incoming[key] { return mapped }
            if let match = stored.first(where: { $0.originalValue == original && $0.replacementValue == replacement }) {
                return match.id
            }
        }
        return stored.count == 1 ? stored[0].id : nil
    }
}
